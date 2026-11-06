// Verifies App Store JWS (transactions, renewal info, notifications) against Apple's roots.
// Production first, sandbox (TestFlight / Xcode builds) when Apple says the environment differs.
import { Buffer } from 'node:buffer'
import { Environment as AppleEnvironment, SignedDataVerifier, VerificationException, VerificationStatus } from 'npm:@apple/app-store-server-library@3.1.0'
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

export function createAppleVerifier(appAppleId: number): AppleVerifier {
  const roots = APPLE_ROOT_CERTIFICATES.map(value => Buffer.from(value, 'base64'))
  const verifiers: Record<Environment, SignedDataVerifier> = {
    production: new SignedDataVerifier(roots, true, AppleEnvironment.PRODUCTION, BUNDLE_ID, appAppleId),
    sandbox: new SignedDataVerifier(roots, true, AppleEnvironment.SANDBOX, BUNDLE_ID),
  }
  async function either<T>(operation: (v: SignedDataVerifier) => Promise<T>): Promise<Verified<T>> {
    for (const environment of ['production', 'sandbox'] as const) {
      try { return { environment, value: await operation(verifiers[environment]) } } catch (error) {
        // Sandbox payloads carry no appAppleId, which the production verifier reports as a bad app id.
        const elsewhere = error instanceof VerificationException
          && (error.status === VerificationStatus.INVALID_ENVIRONMENT || error.status === VerificationStatus.INVALID_APP_IDENTIFIER)
        if (elsewhere && environment === 'production') continue
        if (error instanceof VerificationException && error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) throw new StoreError('apple_unavailable', 503)
        throw new StoreError('invalid_apple_signature', 401)
      }
    }
    throw new StoreError('invalid_apple_signature', 401)
  }
  return {
    transaction: jws => either(async v => object(await v.verifyAndDecodeTransaction(jws))),
    notification: payload => either(async v => {
      const notification = object(await v.verifyAndDecodeNotification(payload))
      const data = notification.data ? object(notification.data) : {}
      // Every nested signed object is verified too; nothing merely base64-decoded is trusted.
      const transaction = typeof data.signedTransactionInfo === 'string' ? object(await v.verifyAndDecodeTransaction(data.signedTransactionInfo)) : null
      const renewal = typeof data.signedRenewalInfo === 'string' ? object(await v.verifyAndDecodeRenewalInfo(data.signedRenewalInfo)) : null
      return { notification, transaction, renewal }
    }),
  }
}

export function object(value: unknown): Json {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new StoreError('invalid_apple_data', 502)
  return value as Json
}
