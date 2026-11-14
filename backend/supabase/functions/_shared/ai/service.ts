// ai-proxy: authenticated, metered relay from the iPad app to Anthropic, OpenAI and Google (Gemini).
//   GET|POST /config      models, Auto, usage, consent state
//   POST /consent         {provider, version}
//   POST /v1/anthropic    Messages API body (streamed back as-is, plus a final bandal_usage event)
//   POST /v1/openai       Responses API body (same)
//   POST /v1/google       Gemini generateContent body plus `model` (same; sent to :streamGenerateContent?alt=sse)
//   POST /v1/openai/decisions  Decisions API body (JSON in, `{answers}` out; input tokens only, see decisions.ts)
import { decide } from './decisions.ts'
import { prepare, ProxyError, withOutputLimit, type ModelRow } from './request.ts'
import { UsageMeter, type Provider, type Usage } from './usage.ts'

export interface Settings {
  auto_model: string; auto_context: number; max_output_tokens: number; consent_version: number
}
export type Status = Record<string, unknown> & { consents?: Record<string, number> }

export interface Store {
  models(): Promise<ModelRow[]>
  settings(): Promise<Settings>
  status(actor: string): Promise<Status>
  begin(actor: string, task: string, step: string, model: string, inputTokens: number, maxOutput: number): Promise<{ ok: boolean; code?: string; maxOutput?: number; status: Status }>
  release(actor: string, step: string): Promise<void>
  settle(actor: string, task: string, step: string, model: string, effort: string | null, kind: string, usage: Usage, complete: boolean): Promise<{ costUcents: number; status: Status }>
  consent(actor: string, provider: Provider, version: number): Promise<Status>
}

export interface Deps {
  store: Store
  authenticate(token: string): Promise<string | null>
  fetch: typeof fetch
  keys: Partial<Record<Provider, string>>
  baseURL: Record<Provider, string>
  waitUntil?(promise: Promise<unknown>): void
  log?(message: string, detail: unknown): void
}

const KINDS = new Set(['question', 'summary', 'quiz', 'translate', 'routine', 'explain'])
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
/** Per-step upstream limit, under the Edge Function wall clock (150 s); the app waits 180 s. */
const STEP_TIMEOUT_MS = 120_000
const MAX_BODY_BYTES = 32 * 1024 * 1024
const SETTLE_RETRY_MS = [0, 500, 2000]

export function createAIProxy(deps: Deps): (request: Request) => Promise<Response> {
  const json = (value: unknown, status = 200) => Response.json(value, { status, headers: HEADERS })

  async function actorOf(request: Request): Promise<string> {
    const header = request.headers.get('authorization') ?? ''
    const actor = header.startsWith('Bearer ') ? await deps.authenticate(header.slice(7)) : null
    if (!actor) throw new ProxyError('SIGN_IN_REQUIRED', 401)
    return actor
  }

  async function config(actor: string) {
    const [models, settings, status] = await Promise.all([deps.store.models(), deps.store.settings(), deps.store.status(actor)])
    const enabled = models.filter(m => m.enabled).sort((a, b) => a.sort - b.sort)
    const auto = models.find(m => m.id === settings.auto_model)
    if (!auto) throw new ProxyError('AI_UNAVAILABLE', 503)
    return {
      models: enabled.map(m => ({ id: m.id, provider: m.provider, label: m.label, contextCap: m.context_cap, badge: Math.max(1, Math.round(m.p_in / auto.p_in)) })),
      auto: { id: auto.id, provider: auto.provider, contextCap: settings.auto_context },
      consentVersion: settings.consent_version,
      usage: status,
    }
  }

  async function relay(request: Request, actor: string, provider: Provider): Promise<Response> {
    const task = request.headers.get('x-bandal-task') ?? ''
    const kind = request.headers.get('x-bandal-kind') ?? 'question'
    if (!UUID.test(task) || !KINDS.has(kind)) throw new ProxyError('INVALID_REQUEST', 400, { field: 'headers' })
    const key = deps.keys[provider]
    if (!key) throw new ProxyError('AI_UNAVAILABLE', 503)
    const text = await request.text()
    if (text.length > MAX_BODY_BYTES) throw new ProxyError('CONTEXT_TOO_LARGE', 413)
    let input: unknown
    try { input = JSON.parse(text) } catch { throw new ProxyError('INVALID_REQUEST', 400) }

    const [models, settings, status] = await Promise.all([deps.store.models(), deps.store.settings(), deps.store.status(actor)])
    if ((status.consents?.[provider] ?? 0) < settings.consent_version) throw new ProxyError('CONSENT_REQUIRED', 409, { provider, version: settings.consent_version })
    const prepared = prepare(provider, input, models, settings.max_output_tokens)
    const step = crypto.randomUUID()
    const begun = await deps.store.begin(actor, task, step, prepared.model.id, prepared.estimatedInput, prepared.requestedOutput)
    if (!begun.ok || !begun.maxOutput) throw new ProxyError(begun.code ?? 'BUDGET_EXHAUSTED', 402, { usage: begun.status })
    const body = withOutputLimit(provider, prepared.body, begun.maxOutput)

    const abort = new AbortController()
    const timer = setTimeout(() => abort.abort(), STEP_TIMEOUT_MS)
    let upstream: Response
    try {
      const url = provider === 'anthropic' ? `${deps.baseURL.anthropic}/v1/messages`
        : provider === 'google' ? `${deps.baseURL.google}/v1beta/models/${encodeURIComponent(prepared.model.id)}:streamGenerateContent?alt=sse`
        : `${deps.baseURL.openai}/v1/responses`
      upstream = await deps.fetch(url, {
        method: 'POST', signal: abort.signal, body: JSON.stringify(body),
        headers: provider === 'anthropic'
          ? { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' }
          : provider === 'google' ? { 'content-type': 'application/json', 'x-goog-api-key': key }
          : { 'content-type': 'application/json', authorization: `Bearer ${key}` },
      })
    } catch (error) {
      clearTimeout(timer)
      await deps.store.release(actor, step).catch(() => {})
      deps.log?.('ai upstream unreachable', { provider, error: String(error) })
      throw new ProxyError('AI_UNAVAILABLE', 503)
    }
    // A refused step costs nothing. Our key's auth or rate limits are not the user's, so only
    // a request the provider rejects as malformed keeps its status.
    if (!upstream.ok || !upstream.body) {
      clearTimeout(timer)
      await deps.store.release(actor, step).catch(() => {})
      const detail = (await upstream.text().catch(() => '')).slice(0, 4096)
      deps.log?.('ai upstream error', { provider, status: upstream.status, detail })
      if (upstream.status === 400) throw new ProxyError('UPSTREAM_REJECTED', 400, { message: upstreamMessage(detail) })
      throw new ProxyError('AI_UNAVAILABLE', 503, { upstream: upstream.status })
    }

    const meter = new UsageMeter(provider)
    const reader = upstream.body.getReader()
    const decoder = new TextDecoder(), encoder = new TextEncoder()
    let attached = true
    const settle = async () => {
      const usage = meter.charge(prepared.estimatedInput)
      for (const delay of SETTLE_RETRY_MS) {
        if (delay) await new Promise(resolve => setTimeout(resolve, delay))
        try { return await deps.store.settle(actor, task, step, prepared.model.id, prepared.effort, kind, usage, meter.completed) } catch (error) {
          deps.log?.('ai settle failed', { step, error: String(error) })
        }
      }
      // ponytail: after three failures the step goes unbilled once its reservation expires;
      // the log line is the only trace. Queue failed settles in a table if this ever shows up.
      return null
    }
    // Upstream is read to the end even when the app goes away, so a delivered step is charged
    // with the provider's own usage (an estimate only when the usage event never came).
    let output!: ReadableStreamDefaultController<Uint8Array>
    const stream = new ReadableStream<Uint8Array>({
      start(controller) { output = controller },
      cancel() { attached = false },
    })
    const pump = (async () => {
      try {
        while (true) {
          const { done, value } = await reader.read()
          if (done) break
          meter.feed(decoder.decode(value, { stream: true }))
          if (attached) output.enqueue(value)
        }
      } catch (error) {
        deps.log?.('ai stream interrupted', { provider, error: String(error) })
      } finally {
        clearTimeout(timer)
      }
      // Model-side failures and empty answers cost the user nothing; the provider may still bill us.
      const result = meter.billable ? await settle() : null
      if (!meter.billable) {
        deps.log?.('ai step not billed', { provider, step, completed: meter.completed, content: meter.content })
        await deps.store.release(actor, step).catch(() => {})
      }
      if (!attached) return
      if (result) output.enqueue(encoder.encode(`data: ${JSON.stringify({ bandal_usage: { costUcents: result.costUcents, ...result.status } })}\n\n`))
      output.close()
    })()
    deps.waitUntil?.(pump)
    return new Response(stream, { headers: { ...HEADERS, 'content-type': 'text/event-stream' } })
  }

  return async (request: Request): Promise<Response> => {
    try {
      const path = new URL(request.url).pathname.replace(/^.*\/ai-proxy/, '') || '/'
      const actor = await actorOf(request)
      if ((request.method === 'GET' || request.method === 'POST') && path === '/config') return json(await config(actor))
      if (request.method === 'POST' && path === '/consent') {
        const input = await request.json().catch(() => null) as Record<string, unknown> | null
        const provider = input?.provider, version = input?.version
        if ((provider !== 'anthropic' && provider !== 'openai' && provider !== 'google') || typeof version !== 'number' || !Number.isInteger(version) || version < 1) {
          throw new ProxyError('INVALID_REQUEST', 400)
        }
        return json(await deps.store.consent(actor, provider, version))
      }
      if (request.method === 'POST' && path === '/v1/openai/decisions') return await decide(deps, request, actor)
      if (request.method === 'POST' && (path === '/v1/anthropic' || path === '/v1/openai' || path === '/v1/google')) {
        return await relay(request, actor, path.slice(4) as Provider)
      }
      throw new ProxyError('NOT_FOUND', 404)
    } catch (error) {
      if (error instanceof ProxyError) return json({ code: error.code, ...error.extra }, error.status)
      deps.log?.('ai proxy failed', { error: String(error) })
      return json({ code: 'AI_UNAVAILABLE' }, 503)
    }
  }
}

function upstreamMessage(detail: string): string {
  try {
    const message = (JSON.parse(detail) as { error?: { message?: unknown } }).error?.message
    return typeof message === 'string' ? message.slice(0, 500) : ''
  } catch { return '' }
}
