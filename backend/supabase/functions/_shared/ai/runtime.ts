import { createClient } from '@supabase/supabase-js'
import type { ModelRow } from './request.ts'
import { createAIProxy, type Settings, type Status, type Store } from './service.ts'

export function runtime(env: (key: string) => string | undefined): (request: Request) => Promise<Response> {
  const url = env('SUPABASE_URL') ?? ''
  const db = createClient(url, env('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false, autoRefreshToken: false } })
  async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
    const { data, error } = await db.rpc(name, args)
    if (error) throw new Error(`${name}: ${error.message}`)
    return data as T
  }
  const store: Store = {
    async models() {
      const { data, error } = await db.from('ai_models').select('*')
      if (error) throw new Error(`ai_models: ${error.message}`)
      return (data ?? []).map(row => ({ ...row, p_in: Number(row.p_in), p_out: Number(row.p_out), p_cache_r: Number(row.p_cache_r), p_cache_w: Number(row.p_cache_w) })) as ModelRow[]
    },
    async settings() {
      const { data, error } = await db.from('ai_settings').select('auto_model,auto_context,max_output_tokens,consent_version').single()
      if (error) throw new Error(`ai_settings: ${error.message}`)
      return data as Settings
    },
    status: actor => rpc<Status>('ai_status', { actor }),
    begin: (actor, task, step, model, inputTokens, maxOutput) => rpc('ai_begin', { actor, task, step, model_id: model, input_tokens: inputTokens, max_output: maxOutput }),
    release: (actor, step) => rpc<void>('ai_release', { actor, step }),
    settle: (actor, task, step, model, effort, kind, u, complete) => rpc('ai_settle', {
      actor, task, step, model_id: model, effort, kind, t_in: u.input, t_out: u.output, t_cache_r: u.cacheRead, t_cache_w: u.cacheWrite, complete,
    }),
    consent: (actor, provider, version) => rpc<Status>('ai_record_consent', { actor, provider_id: provider, consent_version: version }),
  }
  const edge = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime
  return createAIProxy({
    store,
    async authenticate(token) {
      const { data, error } = await db.auth.getClaims(token)
      const claims = data?.claims
      // Anonymous sign-ins would each get a fresh free budget.
      return !error && typeof claims?.sub === 'string' && claims.role === 'authenticated' && claims.is_anonymous !== true ? claims.sub : null
    },
    fetch: (input, init) => fetch(input, init),
    keys: { anthropic: env('ANTHROPIC_API_KEY'), openai: env('OPENAI_API_KEY') },
    baseURL: { anthropic: env('ANTHROPIC_BASE_URL') ?? 'https://api.anthropic.com', openai: env('OPENAI_BASE_URL') ?? 'https://api.openai.com' },
    waitUntil: edge ? p => edge.waitUntil(p) : undefined,
    log: (message, detail) => console.error(message, JSON.stringify(detail)),
  })
}
