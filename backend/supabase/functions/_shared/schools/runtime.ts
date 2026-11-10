import { createClient } from '@supabase/supabase-js'
import type { ModelRow } from '../ai/request.ts'
import { createSchools, type Store } from './service.ts'

export function runtime(env: (key: string) => string | undefined): (request: Request) => Promise<Response> {
  const db = createClient(env('SUPABASE_URL') ?? '', env('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false, autoRefreshToken: false } })
  async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const { data, error } = await db.rpc(name, args)
    if (error) throw new Error(`${name}: ${error.message}`)
    return data as T
  }
  const store: Store = {
    search: (query, country) => rpc('school_search', { q: query, country_code: country }),
    async model() {
      const settings = await db.from('ai_settings').select('auto_model').single()
      if (settings.error) throw new Error(`ai_settings: ${settings.error.message}`)
      const { data: row, error } = await db.from('ai_models').select('*').eq('id', settings.data.auto_model).maybeSingle()
      if (error) throw new Error(`ai_models: ${error.message}`)
      return row && { ...row, p_in: Number(row.p_in), p_out: Number(row.p_out), p_cache_r: Number(row.p_cache_r), p_cache_w: Number(row.p_cache_w) } as ModelRow
    },
    begin: (actor, query, country) => rpc('school_setup_begin', { actor, q: query, country_code: country }),
    // `result` is left out, not sent as null: a JSON null would arrive as a jsonb value.
    finish: (actor, run, outcome, costUcents, school) => rpc('school_setup_finish', { actor, run, outcome, cost: costUcents, ...(school ? { result: school } : {}) }),
    suggest: (actor, schoolId, links) => rpc('school_suggest', { actor, school: schoolId, suggestion: links }),
  }
  return createSchools({
    store,
    // The same check as ai-proxy and ipad-store: a real account, not an anonymous sign-in.
    async authenticate(token) {
      const { data, error } = await db.auth.getClaims(token)
      const claims = data?.claims
      return !error && typeof claims?.sub === 'string' && claims.role === 'authenticated' && claims.is_anonymous !== true ? claims.sub : null
    },
    fetch: (input, init) => fetch(input, init),
    async resolve(hostname) {
      const lookups = await Promise.allSettled((['A', 'AAAA'] as const).map(type => Deno.resolveDns(hostname, type)))
      // A host without IPv6 fails one lookup. Both failing drops the link, and if it is the resolver
      // that is broken every run would end as not_found after being paid for: that must show in the log.
      const failed = lookups.filter(lookup => lookup.status === 'rejected')
      if (failed.length === lookups.length) console.error('school link host unresolved', JSON.stringify({ hostname, error: String(failed[0]?.reason) }))
      return lookups.flatMap(lookup => lookup.status === 'fulfilled' ? lookup.value : [])
    },
    anthropic: { key: env('ANTHROPIC_API_KEY'), baseURL: env('ANTHROPIC_BASE_URL') ?? 'https://api.anthropic.com' },
    log: (message, detail) => console.error(message, JSON.stringify(detail)),
  })
}
