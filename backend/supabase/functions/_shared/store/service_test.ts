import { assertEquals } from '@std/assert'
import { type AppleVerifier, type Json, StoreError } from './apple.ts'
import { createStore, type Entitlement, type StoreDB } from './service.ts'

const A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const NOW = Date.UTC(2026, 10, 6)
const sub = (extra: Json = {}): Json => ({
  bundleId: 'app.bandal.ipad', type: 'Auto-Renewable Subscription', productId: 'app.bandal.ipad.pro.monthly',
  transactionId: '2', originalTransactionId: '1', appAccountToken: A, inAppOwnershipType: 'PURCHASED', expiresDate: NOW + 864e5, signedDate: NOW, ...extra,
})
const pack = (extra: Json = {}): Json => ({ bundleId: 'app.bandal.ipad', type: 'Consumable', productId: 'app.bandal.ipad.credit.pack1', transactionId: '55', appAccountToken: A, ...extra })

function harness(decoded: Record<string, Json | { notification: Json; transaction: Json | null; renewal: Json | null }>, options: { owner?: string | null; sandboxAllowed?: boolean } = {}) {
  const applied: Entitlement[] = [], redeemed: string[] = [], revoked: string[] = [], claimed: string[] = []
  const db: StoreDB = {
    apply: e => { applied.push(e); return Promise.resolve() },
    owner: () => Promise.resolve(options.owner === undefined ? B : options.owner),
    claim: (_env, id) => { claimed.push(id); return Promise.resolve(true) },
    redeem: (actor, env, tx) => { redeemed.push(`${actor}:${env}:${tx}`); return Promise.resolve({ plan: 'pro' }) },
    revokePack: (env, tx) => { revoked.push(`${env}:${tx}`); return Promise.resolve() },
    status: () => Promise.resolve({ plan: 'pro' }),
  }
  const verifier: AppleVerifier = {
    transaction: jws => decoded[jws] ? Promise.resolve({ environment: 'sandbox', value: decoded[jws] as Json }) : Promise.reject(new StoreError('invalid_apple_signature', 401)),
    notification: jws => decoded[jws] ? Promise.resolve({ environment: 'production', value: decoded[jws] as never }) : Promise.reject(new StoreError('invalid_apple_signature', 401)),
  }
  const store = createStore({ db, verifier, authenticate: t => Promise.resolve(t === 'good' ? A : null), sandboxAllowed: () => options.sandboxAllowed ?? true })
  return { store, applied, redeemed, revoked, claimed }
}
const post = (body: unknown, auth = 'Bearer good') => new Request('https://x/functions/v1/ipad-store', { method: 'POST', headers: { authorization: auth }, body: JSON.stringify(body) })

Deno.test('sync applies verified subscriptions for the caller and returns AI status', async () => {
  const { store, applied } = harness({ s1: sub({ offerType: 1, offerDiscountType: 'FREE_TRIAL' }), s2: sub({ productId: 'app.bandal.ipad.plus.yearly', originalTransactionId: '9', isUpgraded: true }) })
  const response = await store.app(post({ action: 'sync', transactions: ['s1', 's2'] }))
  assertEquals(response.status, 200)
  assertEquals(await response.json(), { plan: 'pro', rejected: [] })
  assertEquals(applied.length, 1) // the upgraded Plus transaction is superseded
  assertEquals(applied[0]!.plan, 'pro')
  assertEquals(applied[0]!.trial, true)
  assertEquals(applied[0]!.environment, 'sandbox')
  assertEquals(applied[0]!.grace, 'keep')
})

Deno.test('sync refuses another account\'s purchase, bad signatures, non-subscriptions and missing sign-in', async () => {
  const { store, applied } = harness({ other: sub({ appAccountToken: B }), packAsSub: pack(), signedOut: sub({ appAccountToken: undefined }) })
  assertEquals((await (await store.app(post({ action: 'sync', transactions: ['other', 'forged', 'packAsSub'] }))).json()).rejected,
    ['purchase_owned_by_another_account', 'invalid_apple_signature', 'apple_product_mismatch'])
  assertEquals((await store.app(post({ action: 'sync', transactions: [] }, 'Bearer bad'))).status, 401)
  assertEquals(applied.length, 0)
  // A purchase made while signed out has no token and is claimed by the first account that syncs it.
  await store.app(post({ action: 'sync', transactions: ['signedOut'] }))
  assertEquals(applied.length, 1)
})

Deno.test('redeem pays a verified pack for its owner only', async () => {
  const { store, redeemed } = harness({ p: pack(), other: pack({ appAccountToken: B }), refunded: pack({ revocationDate: NOW }), sub: sub() })
  assertEquals((await store.app(post({ action: 'redeem', transaction: 'p' }))).status, 200)
  assertEquals(redeemed, [`${A}:sandbox:55`])
  assertEquals((await store.app(post({ action: 'redeem', transaction: 'other' }))).status, 409)
  assertEquals((await store.app(post({ action: 'redeem', transaction: 'refunded' }))).status, 409)
  assertEquals((await store.app(post({ action: 'redeem', transaction: 'sub' }))).status, 409)
  assertEquals(redeemed.length, 1)
})

Deno.test('notifications: renewal clears grace, grace sets it, owner looked up without a token', async () => {
  const n = (type: string, transaction: Json, renewal: Json | null = null, subtype?: string) => ({ notification: { notificationType: type, subtype, notificationUUID: '0e0e0e0e-0000-4000-8000-000000000001' }, transaction, renewal })
  const { store, applied, claimed } = harness({
    renew: n('DID_RENEW', sub()),
    grace: n('DID_FAIL_TO_RENEW', sub({ expiresDate: NOW - 1000 }), { gracePeriodExpiresDate: NOW + 16 * 864e5 }, 'GRACE_PERIOD'),
    anon: n('SUBSCRIBED', sub({ appAccountToken: undefined })),
  })
  const send = (payload: string) => store.notifications(new Request('https://x', { method: 'POST', body: JSON.stringify({ signedPayload: payload }) }))
  assertEquals((await send('renew')).status, 200)
  assertEquals(applied[0]!.grace, 'clear')
  await send('grace')
  assertEquals(applied[1]!.grace, 'set')
  assertEquals(applied[1]!.graceExpiresAt, new Date(NOW + 16 * 864e5).toISOString())
  await send('anon')
  assertEquals(applied[2]!.actor, B)
  assertEquals(claimed.length, 3)
  assertEquals((await send('forged')).status, 401)
})

Deno.test('notifications: a refunded pack takes its credit back; TEST is acknowledged', async () => {
  const { store, revoked, applied } = harness({
    refund: { notification: { notificationType: 'REFUND', notificationUUID: '0e0e0e0e-0000-4000-8000-000000000002' }, transaction: pack(), renewal: null },
    test: { notification: { notificationType: 'TEST' }, transaction: null, renewal: null },
  })
  const send = (payload: string) => store.notifications(new Request('https://x', { method: 'POST', body: JSON.stringify({ signedPayload: payload }) }))
  assertEquals((await send('refund')).status, 200)
  assertEquals(revoked, ['production:55'])
  assertEquals((await send('test')).status, 200)
  assertEquals(applied.length, 0)
})

Deno.test('family-shared copies are ignored, sandbox needs an allowed tester', async () => {
  const { store, applied, redeemed } = harness({ family: sub({ inAppOwnershipType: 'FAMILY_SHARED' }), s: sub(), p: pack() }, { sandboxAllowed: false })
  await store.app(post({ action: 'sync', transactions: ['family'] }))
  assertEquals(applied.length, 0)
  assertEquals((await (await store.app(post({ action: 'sync', transactions: ['s'] }))).json()).rejected, ['sandbox_tester_required'])
  assertEquals((await store.app(post({ action: 'redeem', transaction: 'p' }))).status, 403)
  assertEquals(applied.length + redeemed.length, 0)
})

Deno.test('a notification for a purchase nobody synced yet is retried later', async () => {
  const { store } = harness({ n: { notification: { notificationType: 'DID_RENEW', notificationUUID: '0e0e0e0e-0000-4000-8000-000000000003' }, transaction: sub({ appAccountToken: undefined }), renewal: null } }, { owner: null })
  const response = await store.notifications(new Request('https://x', { method: 'POST', body: JSON.stringify({ signedPayload: 'n' }) }))
  assertEquals(response.status, 503)
})
