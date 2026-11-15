import { assertEquals, assertRejects } from '@std/assert'
import jsrsasign from 'npm:jsrsasign@11.1.5'
import { BUNDLE_ID, createAppleVerifier, type Json, rawSignature, StoreError } from './apple.ts'
import { APPLE_ROOT_CERTIFICATES } from './certificates.ts'

// The verifier against certificate chains made here (a P-384 root and intermediate, a P-256 leaf, as Apple's are),
// and against Apple's real intermediate under the pinned roots.

const { KEYUTIL, KJUR } = jsrsasign
const LEAF_OID = '1.2.840.113635.100.6.11.1', INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1'
const APP_ID = 6824053530
const NOW = new Date('2026-11-15T00:00:00Z')
/** Apple Worldwide Developer Relations CA G6: https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer SHA-256 bdd4ed6e74691f0c2bfd01be0296197af1379e0418e2d300efa9c3bef642ca30 */
const APPLE_WWDR_G6 = 'MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMjEwMzE3MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWmZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/sq6PF/cGcKXWsL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYIKwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0cDovL2NybC5hcHBsZS5jb20vYXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR01DJmig97bB85c+lkGKZMA4GA1UdDwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIFADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXufQB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxarZXvNrkxU3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg='
/** "Prod ECC Mac App Store and iTunes Store Receipt Signing", valid 2025-09-19 to 2027-10-13, as the tests of Apple's
 *  app-store-server-library-node 3.1.0 carry it (REAL_APPLE_SIGNING_CERTIFICATE_BASE64_ENCODED). SHA-256 4c381556c16121e605d1fc2eef6d0de4e072ed65964fe72f575f19711e84c417 */
const APPLE_RECEIPT_SIGNING = 'MIIEMTCCA7agAwIBAgIQR8KHzdn554Z/UoradNx9tzAKBggqhkjOPQQDAzB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMB4XDTI1MDkxOTE5NDQ1MVoXDTI3MTAxMzE3NDcyM1owgZIxQDA+BgNVBAMMN1Byb2QgRUNDIE1hYyBBcHAgU3RvcmUgYW5kIGlUdW5lcyBTdG9yZSBSZWNlaXB0IFNpZ25pbmcxLDAqBgNVBAsMI0FwcGxlIFdvcmxkd2lkZSBEZXZlbG9wZXIgUmVsYXRpb25zMRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABNnVvhcv7iT+7Ex5tBMBgrQspHzIsXRi0Yxfek7lv8wEmj/bHiWtNwJqc2BoHzsQiEjP7KFIIKg4Y8y0/nynuAmjggIIMIICBDAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFD8vlCNR01DJmig97bB85c+lkGKZMHAGCCsGAQUFBwEBBGQwYjAtBggrBgEFBQcwAoYhaHR0cDovL2NlcnRzLmFwcGxlLmNvbS93d2RyZzYuZGVyMDEGCCsGAQUFBzABhiVodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLXd3ZHJnNjAyMIIBHgYDVR0gBIIBFTCCAREwggENBgoqhkiG92NkBQYBMIH+MIHDBggrBgEFBQcCAjCBtgyBs1JlbGlhbmNlIG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBjb25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZpY2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMDYGCCsGAQUFBwIBFipodHRwOi8vd3d3LmFwcGxlLmNvbS9jZXJ0aWZpY2F0ZWF1dGhvcml0eS8wHQYDVR0OBBYEFIFioG4wMMVA1ku9zJmGNPAVn3eqMA4GA1UdDwEB/wQEAwIHgDAQBgoqhkiG92NkBgsBBAIFADAKBggqhkjOPQQDAwNpADBmAjEA+qXnREC7hXIWVLsLxznjRpIzPf7VHz9V/CTm8+LJlrQepnmcPvGLNcX6XPnlcgLAAjEA5IjNZKgg5pQ79knF4IbTXdKv8vutIDMXDmjPVT3dGvFtsGRwXOywR2kZCdSrfeot'

const base64 = (hex: string) => btoa(String.fromCharCode(...hex.match(/../g)!.map(pair => parseInt(pair, 16))))
const base64url = (data: Uint8Array) => btoa(String.fromCharCode(...data)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const text = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)))

interface Parts {
  /** Left out to make a chain that is not the App Store's. */
  leafOid?: boolean; intermediateOid?: boolean; intermediateCA?: boolean
  leafValid?: [string, string]
  /** The issuer the leaf names, when it is not the certificate whose key signed it. */
  leafIssuer?: string
}
interface Chain {
  /** The root as base64 DER, to trust. */
  root: string
  x5c: string[]
  /** A JWS of `payload` signed by the leaf, with this chain (or `x5c`) and `alg` in its header. */
  sign(payload: unknown, header?: { alg?: string; x5c?: unknown }): Promise<string>
}

// deno-lint-ignore no-explicit-any
function issue(subject: string, issuer: string, key: any, signer: any, serial: number, ext: any[], valid: [string, string] = ['250101000000Z', '450101000000Z']): string {
  return base64(new KJUR.asn1.x509.Certificate({
    version: 3, serial: { int: serial }, issuer: { str: issuer }, notbefore: valid[0], notafter: valid[1], subject: { str: subject },
    sbjpubkey: key, ext, sigalg: 'SHA384withECDSA', cakey: signer,
  }).getEncodedHex())
}

async function chain(parts: Parts = {}): Promise<Chain> {
  const rootKey = KEYUTIL.generateKeypair('EC', 'secp384r1'), middleKey = KEYUTIL.generateKeypair('EC', 'secp384r1')
  const leafKey = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const spki = new Uint8Array(await crypto.subtle.exportKey('spki', leafKey.publicKey))
  const leafPublic = KEYUTIL.getKey('-----BEGIN PUBLIC KEY-----\n' + btoa(String.fromCharCode(...spki)) + '\n-----END PUBLIC KEY-----')
  const root = issue('/CN=Test Root', '/CN=Test Root', rootKey.pubKeyObj, rootKey.prvKeyObj, 1, [{ extname: 'basicConstraints', cA: true, critical: true }])
  const middle = issue('/CN=Test WWDR', '/CN=Test Root', middleKey.pubKeyObj, rootKey.prvKeyObj, 2, [
    ...(parts.intermediateCA === false ? [] : [{ extname: 'basicConstraints', cA: true, critical: true }]),
    ...(parts.intermediateOid === false ? [] : [{ extname: INTERMEDIATE_OID, extn: '0500' }]),
  ])
  const leaf = issue('/CN=Test Receipt Signing', parts.leafIssuer ?? '/CN=Test WWDR', leafPublic, middleKey.prvKeyObj, 3,
    parts.leafOid === false ? [] : [{ extname: LEAF_OID, extn: '0500' }], parts.leafValid)
  const x5c = [leaf, middle, root]
  return {
    root, x5c,
    async sign(payload, header = {}) {
      const head = text({ alg: header.alg ?? 'ES256', x5c: header.x5c ?? x5c }), body = text(payload)
      const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, leafKey.privateKey, new TextEncoder().encode(head + '.' + body))
      return head + '.' + body + '.' + base64url(new Uint8Array(signature))
    },
  }
}

const transaction = (extra: Json = {}): Json => ({
  bundleId: BUNDLE_ID, environment: 'Sandbox', type: 'Consumable', productId: 'app.bandal.ipad.credit.pack1', transactionId: '2000001', ...extra,
})

/** A verifier that trusts `roots`, and the reasons it logged. */
function verifier(roots: readonly string[], now = NOW) {
  const reasons: string[] = []
  const apple = createAppleVerifier(APP_ID, { roots, now: () => now, log: (_message, detail) => reasons.push(String((detail as Json).reason)) })
  return { apple, reasons }
}
async function refused(run: Promise<unknown>) {
  const error = await assertRejects(() => run, StoreError)
  assertEquals([error.code, error.status], ['invalid_apple_signature', 401])
}

Deno.test('a transaction signed under a trusted root is its payload and its environment', async () => {
  const made = await chain()
  const { apple, reasons } = verifier([made.root])
  assertEquals(await apple.transaction(await made.sign(transaction())), { environment: 'sandbox', value: transaction() })
  const live = transaction({ environment: 'Production', type: 'Auto-Renewable Subscription', productId: 'app.bandal.ipad.pro.monthly' })
  assertEquals(await apple.transaction(await made.sign(live)), { environment: 'production', value: live })
  assertEquals(reasons, [])
})

Deno.test('a changed payload, another signer or an untrusted root is refused', async () => {
  const made = await chain(), other = await chain()
  const { apple, reasons } = verifier([made.root])
  const [head, , tail] = (await made.sign(transaction())).split('.')
  await refused(apple.transaction([head, text(transaction({ transactionId: '999' })), tail].join('.')))
  // Signed by a key that is not the leaf's, with the trusted chain pasted into the header.
  await refused(apple.transaction(await other.sign(transaction(), { x5c: made.x5c })))
  // A whole chain of someone else's making.
  await refused(apple.transaction(await other.sign(transaction())))
  // The trusted intermediate with someone else's leaf.
  await refused(apple.transaction(await other.sign(transaction(), { x5c: [other.x5c[0], made.x5c[1], made.x5c[2]] })))
  assertEquals(reasons, ['signature', 'signature', 'intermediate not signed by a trusted root', 'leaf not signed by the intermediate'])
})

Deno.test('only App Store certificates sign: the two Apple extensions, a CA in the middle, valid today', async () => {
  for (const [parts, reason] of [
    [{ leafOid: false }, 'not App Store certificates'], [{ intermediateOid: false }, 'not App Store certificates'],
    [{ intermediateCA: false }, 'intermediate is not a CA'],
    [{ leafValid: ['250101000000Z', '260101000000Z'] }, 'certificate not valid now'], [{ leafValid: ['270101000000Z', '450101000000Z'] }, 'certificate not valid now'],
    // Signed by the intermediate's key, but naming another issuer.
    [{ leafIssuer: '/CN=Someone Else' }, 'leaf not signed by the intermediate'],
  ] as [Parts, string][]) {
    const made = await chain(parts)
    const { apple, reasons } = verifier([made.root])
    await refused(apple.transaction(await made.sign(transaction())))
    assertEquals(reasons, [reason], JSON.stringify(parts))
  }
  // The same chain is good on a day inside every certificate's dates and refused after them.
  const made = await chain()
  const jws = await made.sign(transaction())
  assertEquals((await verifier([made.root]).apple.transaction(jws)).environment, 'sandbox')
  await refused(verifier([made.root], new Date('2046-01-01T00:00:00Z')).apple.transaction(jws))
  // The root in the intermediate's place does not vouch for a leaf it did not sign.
  const short = await chain()
  const { apple, reasons } = verifier([short.root])
  await refused(apple.transaction(await short.sign(transaction(), { x5c: [short.x5c[0], short.x5c[2], short.x5c[2]] })))
  assertEquals(reasons, ['leaf not signed by the intermediate'])
})

Deno.test('what is not an ES256 JWS with a chain of three is refused', async () => {
  const made = await chain()
  const { apple, reasons } = verifier([made.root])
  const jws = await made.sign(transaction())
  await refused(apple.transaction('not a jws'))
  await refused(apple.transaction(jws.split('.').slice(0, 2).join('.')))
  await refused(apple.transaction(await made.sign(transaction(), { alg: 'none' })))
  await refused(apple.transaction(await made.sign(transaction(), { alg: 'HS256' })))
  await refused(apple.transaction(await made.sign(transaction(), { x5c: made.x5c.slice(0, 2) })))
  await refused(apple.transaction(await made.sign(transaction(), { x5c: 'x' })))
  await refused(apple.transaction(await made.sign(transaction(), { x5c: ['AAAA', made.x5c[1], made.x5c[2]] })))
  await refused(apple.transaction(await made.sign(['not', 'an', 'object'])))
  await refused(apple.transaction(jws + 'AA'))
  assertEquals(reasons.slice(0, 6), ['not a JWS', 'not a JWS', 'algorithm', 'algorithm', 'chain length', 'chain length'])
  assertEquals(reasons.length, 9)
})

Deno.test('another app, or a payload that is not the App Store\'s (Xcode), is refused', async () => {
  const made = await chain()
  const { apple, reasons } = verifier([made.root])
  await refused(apple.transaction(await made.sign(transaction({ bundleId: 'com.example.other' }))))
  await refused(apple.transaction(await made.sign(transaction({ environment: 'Xcode' }))))
  await refused(apple.transaction(await made.sign(transaction({ environment: undefined }))))
  assertEquals(reasons, ['bundle', 'environment Xcode', 'environment undefined'])
})

Deno.test('a notification is verified with everything signed inside it', async () => {
  const made = await chain(), other = await chain()
  const { apple, reasons } = verifier([made.root])
  const inner = transaction({ environment: 'Production', type: 'Auto-Renewable Subscription', productId: 'app.bandal.ipad.pro.monthly' })
  const renewal = { environment: 'Production', autoRenewStatus: 1 }
  const data = async (extra: Json = {}) => ({
    appAppleId: APP_ID, bundleId: BUNDLE_ID, environment: 'Production',
    signedTransactionInfo: await made.sign(inner), signedRenewalInfo: await made.sign(renewal), ...extra,
  })
  const event = { notificationType: 'DID_RENEW', notificationUUID: '11111111-1111-4111-8111-111111111111' }
  const verified = await apple.notification(await made.sign({ ...event, data: await data() }))
  assertEquals(verified.environment, 'production')
  assertEquals(verified.value.transaction, inner)
  assertEquals(verified.value.renewal, renewal)
  assertEquals(verified.value.notification.notificationType, 'DID_RENEW')

  // A sandbox notification carries no app id; a test notification carries no transaction.
  const sandbox = await apple.notification(await made.sign({ notificationType: 'TEST', data: { bundleId: BUNDLE_ID, environment: 'Sandbox' } }))
  assertEquals([sandbox.environment, sandbox.value.transaction, sandbox.value.renewal], ['sandbox', null, null])
  const summary = await apple.notification(await made.sign({ notificationType: 'RENEWAL_EXTENSION', summary: { appAppleId: APP_ID, bundleId: BUNDLE_ID, environment: 'Production' } }))
  assertEquals(summary.environment, 'production')
  assertEquals(reasons, [])

  await refused(apple.notification(await made.sign({ ...event, data: await data({ appAppleId: 1 }) })))
  await refused(apple.notification(await made.sign({ ...event, data: await data({ bundleId: 'com.example.other' }) })))
  await refused(apple.notification(await made.sign({ ...event, data: await data({ signedTransactionInfo: await other.sign(inner) }) })))
  await refused(apple.notification(await made.sign({ ...event, data: await data({ signedTransactionInfo: await made.sign(transaction()) }) })))
  await refused(apple.notification(await made.sign({ ...event, data: await data({ signedRenewalInfo: await made.sign({ environment: 'Sandbox' }) }) })))
  await refused(apple.notification(await made.sign(event)))
  await refused(apple.notification(await other.sign({ ...event, data: await data() })))
  assertEquals(reasons, ['app id', 'bundle', 'intermediate not signed by a trusted root', 'transaction of another environment',
    'renewal of another environment', 'notification without an app', 'intermediate not signed by a trusted root'])
})

Deno.test('Apple\'s real certificates pass every check under the pinned roots, and only under their own root', async () => {
  const made = await chain()
  // The App Store's signing certificate and Apple's intermediate, with a signature that is ours: refused at the
  // signature, so the root, both certificate signatures, the CA flag, both extensions and the dates all passed.
  const jws = await made.sign(transaction(), { x5c: [APPLE_RECEIPT_SIGNING, APPLE_WWDR_G6, APPLE_ROOT_CERTIFICATES[2]] })
  const pinned = verifier(APPLE_ROOT_CERTIFICATES)
  await refused(pinned.apple.transaction(jws))
  assertEquals(pinned.reasons, ['signature'])
  // After the signing certificate's last day (2027-10-13) it signs nothing.
  const later = verifier(APPLE_ROOT_CERTIFICATES, new Date('2027-11-01T00:00:00Z'))
  await refused(later.apple.transaction(jws))
  assertEquals(later.reasons, ['certificate not valid now'])
  // A leaf of our own under Apple's intermediate.
  const ours = verifier(APPLE_ROOT_CERTIFICATES)
  await refused(ours.apple.transaction(await made.sign(transaction(), { x5c: [made.x5c[0], APPLE_WWDR_G6, APPLE_ROOT_CERTIFICATES[2]] })))
  assertEquals(ours.reasons, ['leaf not signed by the intermediate'])
  // Without Apple Root CA - G3 (the two RSA roots are left) nothing vouches for the intermediate.
  const others = verifier(APPLE_ROOT_CERTIFICATES.slice(0, 2))
  await refused(others.apple.transaction(jws))
  assertEquals(others.reasons, ['intermediate not signed by a trusted root'])
})

Deno.test('a DER signature becomes r and s of the curve\'s size', () => {
  const hex = (data: Uint8Array | null) => data && Array.from(data, byte => byte.toString(16).padStart(2, '0')).join('')
  const integer = (value: string) => '02' + (value.length / 2).toString(16).padStart(2, '0') + value
  const sequence = (...items: string[]) => '30' + (items.join('').length / 2).toString(16).padStart(2, '0') + items.join('')
  // A leading zero (the high bit is set) goes; a short value is padded on the left.
  assertEquals(hex(rawSignature(sequence(integer('00' + 'ff'.repeat(4)), integer('0102')), 4)), 'ffffffff' + '00000102')
  assertEquals(hex(rawSignature(sequence(integer('01'), integer('00')), 2)), '0001' + '0000')
  assertEquals(rawSignature(sequence(integer('01' + 'ff'.repeat(4)), integer('01')), 4), null, 'r longer than the curve')
  assertEquals(rawSignature(sequence(integer('01'), integer('02'), integer('03')), 4), null, 'three numbers')
  assertEquals(rawSignature(sequence(integer('01')), 4), null, 'one number')
  assertEquals(rawSignature(sequence('0401ff', integer('01')), 4), null, 'not an integer')
  assertEquals(rawSignature('zz', 4), null)
})
