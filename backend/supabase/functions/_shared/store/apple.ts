// Verifies App Store JWS (transactions, renewal info, notifications) against Apple's roots, with WebCrypto.
//
// Apple's own library (@apple/app-store-server-library) cannot do it in the Edge runtime: there node:crypto has no
// X509Certificate.verify or .raw (ERR_NOT_IMPLEMENTED) and jsonwebtoken cannot verify ES256, so it refused every
// purchase and every notification as a bad signature (found 2026-11-15 on supabase-edge-runtime-1.79.1). The checks
// here are that library's, in its order. One is left out: OCSP revocation of Apple's signing certificates, which it
// does with the same missing API.
import jsrsasign from 'npm:jsrsasign@11.1.5'
import { APPLE_ROOT_CERTIFICATES } from './certificates.ts'

export type Environment = 'production' | 'sandbox'
export type Json = Record<string, unknown>
export class StoreError extends Error {
  constructor(readonly code: string, readonly status = 400) { super(code) }
}
export interface Verified<T> { environment: Environment; value: T }
export interface Notification { notification: Json; transaction: Json | null; renewal: Json | null }
export interface AppleVerifier {
  transaction(jws: string): Promise<Verified<Json>>
  notification(signedPayload: string): Promise<Verified<Notification>>
}

export const BUNDLE_ID = 'app.bandal.ipad'

/** Marks the App Store's receipt signing certificate (the leaf). */
const LEAF_OID = '1.2.840.113635.100.6.11.1'
/** Marks Apple's Worldwide Developer Relations intermediate. */
const INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1'
const EC_PUBLIC_KEY = '06072a8648ce3d0201'
const CURVES: Record<string, { name: 'P-256' | 'P-384'; size: number }> = {
  '06082a8648ce3d030107': { name: 'P-256', size: 32 },
  '06052b81040022': { name: 'P-384', size: 48 },
}
const HASHES: Record<string, string> = { SHA256withECDSA: 'SHA-256', SHA384withECDSA: 'SHA-384', SHA512withECDSA: 'SHA-512' }

export interface VerifierOptions {
  /** Trusted roots as base64 DER; Apple's by default. */
  roots?: readonly string[]
  now?: () => Date
  /** Why a payload was refused (never the payload itself). */
  log?(message: string, detail: unknown): void
}

/** Refused, with the reason for the log. The caller only ever learns `invalid_apple_signature`. */
class Refusal extends Error {}

interface Certificate {
  /** The signed part (TBSCertificate), its signature (DER) and the signature's hash. */
  tbs: Uint8Array; signature: string; hash: string | undefined
  issuer: string; subject: string
  /** subjectPublicKeyInfo, and its curve when it is an EC key WebCrypto can use. */
  spki: Uint8Array; curve: { name: 'P-256' | 'P-384'; size: number } | undefined
  notBefore: Date; notAfter: Date
  ca: boolean
  has(oid: string): boolean
}

function bytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2)
  for (let index = 0; index < out.length; index++) out[index] = parseInt(hex.slice(index * 2, index * 2 + 2), 16)
  return out
}
function hexOf(data: Uint8Array): string {
  return Array.from(data, byte => byte.toString(16).padStart(2, '0')).join('')
}
function base64(value: string): Uint8Array {
  const binary = atob(value)
  return Uint8Array.from(binary, char => char.charCodeAt(0))
}
function base64url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Refusal('not base64url')
  return base64(value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4))
}

function certificate(der: Uint8Array): Certificate {
  const { ASN1HEX, X509, zulutodate } = jsrsasign
  const x = new X509()
  x.readCertHex(hexOf(der))
  const spki: string = x.getSPKI()
  const tbs = ASN1HEX.getTLVbyList(x.hex, 0, [0])
  if (!tbs) throw new Refusal('certificate')
  const parameters = ASN1HEX.getTLVbyList(spki, 0, [0, 1])
  const curve = ASN1HEX.getTLVbyList(spki, 0, [0, 0]) === EC_PUBLIC_KEY && parameters ? CURVES[parameters] : undefined
  return {
    tbs: bytes(tbs), signature: x.getSignatureValueHex(), hash: HASHES[x.getSignatureAlgorithmField()],
    issuer: x.getIssuerHex(), subject: x.getSubjectHex(), spki: bytes(spki), curve,
    notBefore: zulutodate(x.getNotBefore()), notAfter: zulutodate(x.getNotAfter()),
    ca: x.getExtBasicConstraints()?.cA === true,
    has: oid => x.getExtInfo(oid) !== undefined,
  }
}

/** A DER ECDSA signature (SEQUENCE of r and s, as hex) as r‖s of the curve's size, which is what WebCrypto takes. */
export function rawSignature(der: string, size: number): Uint8Array | null {
  const { ASN1HEX } = jsrsasign
  try {
    if (ASN1HEX.getChildIdx(der, 0).length !== 2) return null
    const out = new Uint8Array(size * 2)
    for (const [index, position] of [0, 1].entries()) {
      const integer = ASN1HEX.getVbyList(der, 0, [position], '02')
      if (!integer) return null
      // Without the zeros in front: one is there whenever the number's high bit is set.
      const value = bytes(integer).filter((byte, at, all) => byte !== 0 || all.slice(0, at).some(earlier => earlier !== 0))
      if (value.length > size) return null
      out.set(value, size * index + size - value.length)
    }
    return out
  } catch { return null }
}

/** Whether `issuer`'s key signed `subject`. Anything WebCrypto cannot check here (an RSA root) is not a signature. */
async function signed(subject: Certificate, issuer: Certificate): Promise<boolean> {
  if (!issuer.curve || !subject.hash || subject.issuer !== issuer.subject) return false
  const signature = rawSignature(subject.signature, issuer.curve.size)
  if (!signature) return false
  try {
    const key = await crypto.subtle.importKey('spki', issuer.spki as BufferSource, { name: 'ECDSA', namedCurve: issuer.curve.name }, false, ['verify'])
    return await crypto.subtle.verify({ name: 'ECDSA', hash: subject.hash }, key, signature as BufferSource, subject.tbs as BufferSource)
  } catch { return false }
}

export function createAppleVerifier(appAppleId: number, options: VerifierOptions = {}): AppleVerifier {
  const now = options.now ?? (() => new Date())
  const roots = (options.roots ?? APPLE_ROOT_CERTIFICATES).map(value => certificate(base64(value)))

  /** The payload of a JWS that Apple signed: an ES256 signature by a leaf that chains to a trusted root. */
  async function payload(jws: string): Promise<Json> {
    const parts = jws.split('.')
    if (parts.length !== 3) throw new Refusal('not a JWS')
    const [head, body, tail] = parts as [string, string, string]
    const header = object(JSON.parse(new TextDecoder().decode(base64url(head))))
    if (header.alg !== 'ES256') throw new Refusal('algorithm')
    const chain = header.x5c
    if (!Array.isArray(chain) || chain.length !== 3 || chain.some(item => typeof item !== 'string')) throw new Refusal('chain length')
    const leaf = certificate(base64(chain[0])), intermediate = certificate(base64(chain[1]))

    let root: Certificate | undefined
    for (const candidate of roots) if (await signed(intermediate, candidate)) { root = candidate; break }
    if (!root) throw new Refusal('intermediate not signed by a trusted root')
    if (!await signed(leaf, intermediate)) throw new Refusal('leaf not signed by the intermediate')
    if (!intermediate.ca) throw new Refusal('intermediate is not a CA')
    if (!leaf.has(LEAF_OID) || !intermediate.has(INTERMEDIATE_OID)) throw new Refusal('not App Store certificates')
    const at = now().getTime()
    for (const item of [leaf, intermediate, root]) {
      if (at < item.notBefore.getTime() || at > item.notAfter.getTime()) throw new Refusal('certificate not valid now')
    }

    if (leaf.curve?.name !== 'P-256') throw new Refusal('leaf key')
    const signature = base64url(tail)
    if (signature.length !== 64) throw new Refusal('signature length')
    const key = await crypto.subtle.importKey('spki', leaf.spki as BufferSource, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'])
    const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, signature as BufferSource, new TextEncoder().encode(head + '.' + body) as BufferSource)
    if (!valid) throw new Refusal('signature')
    return object(JSON.parse(new TextDecoder().decode(base64url(body))))
  }

  function environment(value: unknown): Environment {
    if (value === 'Production') return 'production'
    if (value === 'Sandbox') return 'sandbox'
    // Xcode and LocalTesting payloads are not Apple's.
    throw new Refusal('environment ' + String(value).slice(0, 20))
  }

  async function transaction(jws: string): Promise<Verified<Json>> {
    const value = await payload(jws)
    if (value.bundleId !== BUNDLE_ID) throw new Refusal('bundle')
    return { environment: environment(value.environment), value }
  }

  async function notification(signedPayload: string): Promise<Verified<Notification>> {
    const value = await payload(signedPayload)
    // Where a notification says whose it is depends on its kind.
    const about = [value.data, value.summary, value.appData].find(item => item != null)
    let target: Environment
    if (about != null) {
      const details = object(about)
      if (details.bundleId !== BUNDLE_ID) throw new Refusal('bundle')
      target = environment(details.environment)
      if (target === 'production' && details.appAppleId !== appAppleId) throw new Refusal('app id')
    } else if (value.externalPurchaseToken != null) {
      const token = object(value.externalPurchaseToken)
      if (token.bundleId !== BUNDLE_ID) throw new Refusal('bundle')
      target = String(token.externalPurchaseId ?? '').startsWith('SANDBOX') ? 'sandbox' : 'production'
      if (target === 'production' && token.appAppleId !== appAppleId) throw new Refusal('app id')
    } else throw new Refusal('notification without an app')

    const data = value.data != null ? object(value.data) : {}
    // Every nested signed object is verified too; nothing merely base64-decoded is trusted.
    let inner: Json | null = null, renewal: Json | null = null
    if (typeof data.signedTransactionInfo === 'string') {
      const verified = await transaction(data.signedTransactionInfo)
      if (verified.environment !== target) throw new Refusal('transaction of another environment')
      inner = verified.value
    }
    if (typeof data.signedRenewalInfo === 'string') {
      renewal = await payload(data.signedRenewalInfo)
      if (environment(renewal.environment) !== target) throw new Refusal('renewal of another environment')
    }
    return { environment: target, value: { notification: value, transaction: inner, renewal } }
  }

  /** Whatever is wrong with a payload, the caller learns only that it is not Apple's. */
  async function guarded<T>(kind: string, run: () => Promise<T>): Promise<T> {
    try { return await run() } catch (error) {
      if (error instanceof StoreError && error.code !== 'invalid_apple_data') throw error
      options.log?.('apple verification refused', { kind, reason: error instanceof Error ? error.message.slice(0, 120) : 'unknown' })
      throw new StoreError('invalid_apple_signature', 401)
    }
  }

  return {
    transaction: jws => guarded('transaction', () => transaction(jws)),
    notification: signedPayload => guarded('notification', () => notification(signedPayload)),
  }
}

export function object(value: unknown): Json {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new StoreError('invalid_apple_data', 502)
  return value as Json
}
