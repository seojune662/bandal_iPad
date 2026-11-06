// ipad-store: the app reports verified purchases.
//   POST {action:"sync", transactions:[jws…]}   subscriptions from Transaction.currentEntitlements
//   POST {action:"redeem", transaction: jws}    one credit pack (finish() only after this succeeds)
// ipad-store-notifications: App Store Server Notifications V2 ({signedPayload}).
import { type AppleVerifier, BUNDLE_ID, type Environment, type Json, StoreError } from './apple.ts'

export const PLANS: Record<string, 'plus' | 'pro'> = {
  'app.bandal.ipad.plus.monthly': 'plus', 'app.bandal.ipad.plus.yearly': 'plus',
  'app.bandal.ipad.pro.monthly': 'pro', 'app.bandal.ipad.pro.yearly': 'pro',
}
export const PACK_PRODUCT = 'app.bandal.ipad.credit.pack1'
const MAX_TRANSACTIONS = 20
const MAX_BODY = 256 * 1024
const SAFE_CODES = new Set(['purchase_owned_by_another_account', 'purchase_revoked'])

export type GraceMode = 'keep' | 'set' | 'clear'
export interface Entitlement {
  actor: string; environment: Environment; originalTransactionId: string; transactionId: string; productId: string; plan: 'plus' | 'pro'
  trial: boolean; expiresAt: string; revokedAt: string | null; signedAt: string; grace: GraceMode; graceExpiresAt: string | null
}
export interface StoreDB {
  apply(entitlement: Entitlement): Promise<void>
  owner(environment: Environment, originalTransactionId: string): Promise<string | null>
  claim(environment: Environment, eventId: string, type: string): Promise<boolean>
  redeem(actor: string, environment: Environment, transactionId: string): Promise<Json>
  revokePack(environment: Environment, transactionId: string): Promise<void>
  status(actor: string): Promise<Json>
}
export interface StoreDeps {
  db: StoreDB; verifier: AppleVerifier
  authenticate(token: string): Promise<string | null>
  /** Sandbox purchases are free, so only these accounts (TestFlight testers) may use them. */
  sandboxAllowed(actor: string): boolean
  log?(message: string, detail: unknown): void
}

const HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: HEADERS })

export function createStore(deps: StoreDeps) {
  async function body(request: Request): Promise<Json> {
    const text = await request.text()
    if (text.length > MAX_BODY) throw new StoreError('body_too_large', 413)
    try {
      const value = JSON.parse(text)
      if (value && typeof value === 'object' && !Array.isArray(value)) return value as Json
    } catch { /* fall through */ }
    throw new StoreError('invalid_request')
  }

  async function guard(run: () => Promise<Response>): Promise<Response> {
    try { return await run() } catch (error) {
      if (error instanceof StoreError) return json({ code: error.code }, error.status)
      const message = error instanceof Error ? error.message : String(error)
      if (SAFE_CODES.has(message)) return json({ code: message }, 409)
      deps.log?.('ipad-store failed', { error: message })
      return json({ code: 'store_unavailable' }, 503)
    }
  }

  /** The app endpoint. */
  function sandboxGate(environment: Environment, actor: string) {
    if (environment === 'sandbox' && !deps.sandboxAllowed(actor)) throw new StoreError('sandbox_tester_required', 403)
  }

  const app = (request: Request) => guard(async () => {
    if (request.method !== 'POST') throw new StoreError('method_not_allowed', 405)
    const header = request.headers.get('authorization') ?? ''
    const actor = header.startsWith('Bearer ') ? await deps.authenticate(header.slice(7)) : null
    if (!actor) throw new StoreError('sign_in_required', 401)
    const input = await body(request)
    if (input.action === 'sync') {
      const list = input.transactions
      if (!Array.isArray(list) || list.length > MAX_TRANSACTIONS || list.some(item => typeof item !== 'string')) throw new StoreError('invalid_request')
      // Each transaction stands alone: one that belongs to someone else does not stop the rest.
      const rejected: string[] = []
      for (const jws of list as string[]) {
        try {
          const { environment, value } = await deps.verifier.transaction(jws)
          sandboxGate(environment, actor)
          const entitlement = subscription(value, environment, actor, 'keep', null)
          if (entitlement) await deps.db.apply(entitlement)
        } catch (error) {
          const code = error instanceof StoreError ? error.code : error instanceof Error && SAFE_CODES.has(error.message) ? error.message : null
          if (!code || code === 'apple_unavailable') throw error
          rejected.push(code)
        }
      }
      return json({ ...await deps.db.status(actor), rejected })
    }
    if (input.action === 'redeem') {
      if (typeof input.transaction !== 'string') throw new StoreError('invalid_request')
      const { environment, value: t } = await deps.verifier.transaction(input.transaction)
      sandboxGate(environment, actor)
      if (t.bundleId !== BUNDLE_ID || t.productId !== PACK_PRODUCT || t.type !== 'Consumable') throw new StoreError('apple_product_mismatch', 409)
      if (t.revocationDate != null) throw new StoreError('purchase_revoked', 409)
      ownedBy(t, actor)
      return json(await deps.db.redeem(actor, environment, id(t.transactionId)))
    }
    throw new StoreError('invalid_request')
  })

  /** The App Store Server Notifications V2 endpoint. */
  const notifications = (request: Request) => guard(async () => {
    if (request.method !== 'POST') throw new StoreError('method_not_allowed', 405)
    const input = await body(request)
    if (typeof input.signedPayload !== 'string' || Object.keys(input).length !== 1) throw new StoreError('invalid_request')
    const { environment, value } = await deps.verifier.notification(input.signedPayload)
    const { notification, transaction: t, renewal } = value
    const type = String(notification.notificationType ?? ''), subtype = String(notification.subtype ?? '')
    const eventId = String(notification.notificationUUID ?? '')
    if (type === 'TEST' || !t) return json({ received: true })
    if (t.bundleId !== BUNDLE_ID) throw new StoreError('apple_product_mismatch', 409)

    if (t.productId === PACK_PRODUCT) {
      // ponytail: REFUND_REVERSED on a pack is not re-granted; Apple rarely reverses and the ledger shows it.
      // A refund that arrives before the app redeemed the pack is recorded so the redeem fails.
      if (type === 'REFUND' || type === 'REVOKE') await deps.db.revokePack(environment, id(t.transactionId))
      await deps.db.claim(environment, eventId, type)
      return json({ received: true })
    }
    if (!PLANS[String(t.productId)]) return json({ received: true })
    const otid = id(t.originalTransactionId)
    // Family members' copies are not entitlements here (Family Sharing is off).
    if (t.inAppOwnershipType !== 'PURCHASED') return json({ received: true })
    const actor = token(t.appAccountToken) ?? await deps.db.owner(environment, otid)
    if (!actor) {
      // Not synced yet: Apple retries for days, by which time the app has claimed it.
      deps.log?.('ipad-store notification without owner', { type, environment })
      throw new StoreError('owner_unknown', 503)
    }
    if (environment === 'sandbox' && !deps.sandboxAllowed(actor)) return json({ received: true })
    let grace: GraceMode = 'keep', graceExpiresAt: string | null = null
    if (type === 'DID_FAIL_TO_RENEW' && subtype === 'GRACE_PERIOD' && renewal?.gracePeriodExpiresDate != null) {
      grace = 'set'; graceExpiresAt = date(renewal.gracePeriodExpiresDate)
    } else if (type === 'DID_RENEW' || type === 'EXPIRED' || type === 'GRACE_PERIOD_EXPIRED' || type === 'REFUND' || type === 'REVOKE') {
      grace = 'clear'
    }
    const entitlement = subscription(t, environment, actor, grace, graceExpiresAt)
    if (entitlement) await deps.db.apply(entitlement)
    // Applying is idempotent, so Apple's retries are harmless; the event row is a record, written last
    // so a failure above makes Apple retry.
    await deps.db.claim(environment, eventId, type)
    return json({ received: true })
  })

  return { app, notifications }
}

/** A verified auto-renewable transaction as an entitlement row, or null when it is superseded or not ours. */
export function subscription(t: Json, environment: Environment, actor: string, grace: GraceMode, graceExpiresAt: string | null): Entitlement | null {
  const plan = PLANS[String(t.productId)]
  if (t.bundleId !== BUNDLE_ID || t.type !== 'Auto-Renewable Subscription' || !plan) throw new StoreError('apple_product_mismatch', 409)
  ownedBy(t, actor)
  // An upgraded transaction is replaced by the one for the new product under the same original id;
  // a family member's copy is not the buyer's entitlement.
  if (t.isUpgraded === true || t.inAppOwnershipType !== 'PURCHASED') return null
  // Free periods from the introductory offer, offer codes or promotional offers all count as a trial.
  const freePeriod = t.offerDiscountType === 'FREE_TRIAL' || (t.offerType === 1 && t.offerDiscountType == null)
  return {
    actor, environment, originalTransactionId: id(t.originalTransactionId), transactionId: id(t.transactionId), productId: String(t.productId), plan,
    trial: freePeriod, expiresAt: date(t.expiresDate), revokedAt: t.revocationDate == null ? null : date(t.revocationDate),
    signedAt: date(t.signedDate), grace, graceExpiresAt,
  }
}

/** Purchases made while signed in carry the account id as appAccountToken; one made signed out has none. */
function ownedBy(t: Json, actor: string) {
  const owner = token(t.appAccountToken)
  if (owner && owner !== actor.toLowerCase()) throw new StoreError('purchase_owned_by_another_account', 409)
}
function token(value: unknown): string | null {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value) ? value.toLowerCase() : null
}
function id(value: unknown): string {
  if (typeof value !== 'string' || !/^[0-9]{1,32}$/.test(value)) throw new StoreError('invalid_apple_data', 502)
  return value
}
function date(value: unknown): string {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) throw new StoreError('invalid_apple_data', 502)
  return new Date(value).toISOString()
}
