import { createClient } from '@supabase/supabase-js'
import { createReferral, type Store } from './service.ts'

export function runtime(env: (key: string) => string | undefined): (request: Request) => Promise<Response> {
  const db = createClient(env('SUPABASE_URL') ?? '', env('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false, autoRefreshToken: false } })
  async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const { data, error } = await db.rpc(name, args)
    if (error) throw new Error(`${name}: ${error.message}`)
    return data as T
  }
  const store: Store = {
    check: code => rpc('referral_check', { entered: code }),
    claim: (actor, code) => rpc('referral_claim_code', { actor, entered: code }),
    complete: actor => rpc('referral_complete', { actor }),
    status: actor => rpc('referral_status', { actor }),
  }
  return createReferral({
    store,
    // The same check as ai-proxy, ipad-store and schools: a real account, not an anonymous sign-in.
    async authenticate(token) {
      const { data, error } = await db.auth.getClaims(token)
      const claims = data?.claims
      return !error && typeof claims?.sub === 'string' && claims.role === 'authenticated' && claims.is_anonymous !== true ? claims.sub : null
    },
    log: (message, detail) => console.error(message, JSON.stringify(detail)),
  })
}
