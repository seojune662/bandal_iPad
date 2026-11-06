import { createClient } from '@supabase/supabase-js'
import { createAppleVerifier, type Json } from './apple.ts'
import { createStore, type StoreDB } from './service.ts'

export function runtime(env: (key: string) => string | undefined) {
  const db = createClient(env('SUPABASE_URL') ?? '', env('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false, autoRefreshToken: false } })
  async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const { data, error } = await db.rpc(name, args)
    if (error) throw new Error(['purchase_owned_by_another_account', 'purchase_revoked'].includes(error.message) ? error.message : `${name}: ${error.message}`)
    return data as T
  }
  const store: StoreDB = {
    apply: e => rpc('ipad_apply_entitlement', {
      actor: e.actor, env: e.environment, otid: e.originalTransactionId, tx: e.transactionId, product: e.productId, entitlement_plan: e.plan,
      trial: e.trial, expires: e.expiresAt, revoked: e.revokedAt, signed: e.signedAt, grace_mode: e.grace, grace: e.graceExpiresAt,
    }),
    owner: (environment, otid) => rpc<string | null>('ipad_entitlement_owner', { env: environment, otid }),
    claim: (environment, event, type) => rpc<boolean>('ipad_claim_event', { env: environment, event, kind: type }),
    redeem: (actor, environment, transactionId) => rpc<Json>('ipad_redeem_pack', { actor, env: environment, transaction_id: transactionId }),
    revokePack: (environment, transactionId) => rpc<void>('ipad_revoke_pack', { env: environment, transaction_id: transactionId }),
    status: actor => rpc<Json>('ai_status', { actor }),
  }
  const testers = new Set((env('APPLE_SANDBOX_ALLOWED_USER_IDS') ?? '').split(',').map(id => id.trim().toLowerCase()).filter(Boolean))
  return createStore({
    sandboxAllowed: actor => testers.has(actor.toLowerCase()),
    db: store,
    verifier: createAppleVerifier(Number(env('APPLE_APP_ID') ?? '6824053530')),
    async authenticate(token) {
      const { data, error } = await db.auth.getClaims(token)
      const claims = data?.claims
      return !error && typeof claims?.sub === 'string' && claims.role === 'authenticated' && claims.is_anonymous !== true ? claims.sub : null
    },
    log: (message, detail) => console.error(message, JSON.stringify(detail)),
  })
}
