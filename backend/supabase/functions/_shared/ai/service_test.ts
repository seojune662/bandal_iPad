import { assert, assertEquals } from '@std/assert'
import type { ModelRow } from './request.ts'
import { estimateTokens } from './request.ts'
import { createAIProxy, type Deps, type Status, type Store } from './service.ts'
import { UsageMeter, type Usage } from './usage.ts'

const MODELS: ModelRow[] = [
  { id: 'claude-haiku-5-5', provider: 'anthropic', label: 'Claude Haiku 5.5', p_in: 10, p_out: 50, p_cache_r: 1, p_cache_w: 12.5, context_cap: 100000, enabled: true, sort: 10 },
  { id: 'claude-sonnet-5-5', provider: 'anthropic', label: 'Claude Sonnet 5.5', p_in: 200, p_out: 1000, p_cache_r: 20, p_cache_w: 250, context_cap: 100000, enabled: true, sort: 20 },
  { id: 'claude-opus-5-5', provider: 'anthropic', label: 'Claude Opus 5.5', p_in: 400, p_out: 2000, p_cache_r: 20, p_cache_w: 500, context_cap: 100000, enabled: false, sort: 30 },
  { id: 'gpt-6-luna', provider: 'openai', label: 'GPT-6 Luna', p_in: 10, p_out: 50, p_cache_r: 1, p_cache_w: 0, context_cap: 100000, enabled: true, sort: 40 },
  { id: 'gemini-test', provider: 'google', label: 'Gemini Test', p_in: 10, p_out: 50, p_cache_r: 1, p_cache_w: 0, context_cap: 100000, enabled: true, sort: 70 },
]
const TASK = '11111111-1111-4111-8111-111111111111'

interface Settled { model: string; effort: string | null; kind: string; usage: Usage; complete: boolean }
function harness(options: { consents?: Record<string, number>; begin?: { ok: boolean; code?: string; maxOutput?: number }; upstream?: (url: string, init: RequestInit) => Response } = {}) {
  const settled: Settled[] = []
  const released: string[] = []
  const begun: { inputTokens: number; maxOutput: number }[] = []
  const sent: { url: string; body: Record<string, unknown>; headers: Record<string, string> }[] = []
  const status: Status = { plan: 'plus', remainingUcents: 1000, consents: options.consents ?? { anthropic: 1, openai: 1, google: 1 } }
  const store: Store = {
    models: () => Promise.resolve(MODELS),
    settings: () => Promise.resolve({ auto_model: 'claude-haiku-5-5', auto_context: 30000, max_output_tokens: 8192, consent_version: 1 }),
    status: () => Promise.resolve(status),
    begin: (_actor, _task, _step, _model, inputTokens, maxOutput) => { begun.push({ inputTokens, maxOutput }); return Promise.resolve({ ...(options.begin ?? { ok: true, maxOutput: 4000 }), status }) },
    release: (_actor, step) => { released.push(step); return Promise.resolve() },
    settle: (_actor, _task, _step, model, effort, kind, usage, complete) => { settled.push({ model, effort, kind, usage, complete }); return Promise.resolve({ costUcents: 42, status }) },
    consent: (_actor, provider, version) => Promise.resolve({ ...status, consents: { [provider]: version } }),
  }
  const deps: Deps = {
    store,
    authenticate: token => Promise.resolve(token === 'good' ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' : null),
    fetch: (input, init) => {
      const url = String(input)
      sent.push({ url, body: JSON.parse(String(init?.body)), headers: init?.headers as Record<string, string> })
      return Promise.resolve(options.upstream ? options.upstream(url, init ?? {}) : sse(ANTHROPIC_STREAM))
    },
    keys: { anthropic: 'sk-ant', openai: 'sk-oai', google: 'g-key' },
    baseURL: { anthropic: 'https://anthropic.test', openai: 'https://openai.test', google: 'https://google.test' },
  }
  return { handle: createAIProxy(deps), settled, sent, released, begun, store }
}

function sse(events: unknown[]): Response {
  return new Response(events.map(e => `data: ${JSON.stringify(e)}\n\n`).join(''), { headers: { 'content-type': 'text/event-stream' } })
}
const ANTHROPIC_STREAM = [
  { type: 'message_start', message: { usage: { input_tokens: 1200, cache_read_input_tokens: 300, cache_creation_input_tokens: 50, output_tokens: 1 } } },
  { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '안녕하세요' } },
  { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 80 } },
  { type: 'message_stop' },
]
const OPENAI_STREAM = [
  { type: 'response.output_text.delta', delta: 'Hi' },
  { type: 'response.completed', response: { usage: { input_tokens: 1000, input_tokens_details: { cached_tokens: 400 }, output_tokens: 60 } } },
]

function call(handle: (r: Request) => Promise<Response>, path: string, body?: unknown, headers: Record<string, string> = {}) {
  return handle(new Request(`https://x.supabase.co/functions/v1/ai-proxy${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { authorization: 'Bearer good', 'x-bandal-task': TASK, ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  }))
}
const anthropicBody = (extra: Record<string, unknown> = {}) => ({ model: 'claude-haiku-5-5', system: 's', messages: [{ role: 'user', content: 'hi' }], max_tokens: 99999, stream: true, ...extra })

Deno.test('rejects a missing or invalid token before anything else', async () => {
  const { handle, sent } = harness()
  const response = await call(handle, '/config', undefined, { authorization: 'Bearer bad' })
  assertEquals(response.status, 401)
  assertEquals((await response.json()).code, 'SIGN_IN_REQUIRED')
  assertEquals(sent.length, 0)
})

Deno.test('config lists enabled models with input-price badges against Auto', async () => {
  const { handle } = harness()
  const config = await (await call(handle, '/config')).json()
  assertEquals(config.models.map((m: { id: string }) => m.id), ['claude-haiku-5-5', 'claude-sonnet-5-5', 'gpt-6-luna', 'gemini-test'])
  assertEquals(config.models[1].badge, 20)
  assertEquals(config.auto, { id: 'claude-haiku-5-5', provider: 'anthropic', contextCap: 30000 })
  assertEquals(config.usage.plan, 'plus')
})

Deno.test('asks the reservation for the capped output', async () => {
  const { handle, begun } = harness()
  await (await call(handle, '/v1/anthropic', anthropicBody())).text()
  assertEquals(begun[0]!.maxOutput, 8192)
})

Deno.test('relays Anthropic with server key, capped output and caching, then appends usage', async () => {
  const { handle, settled, sent } = harness()
  const response = await call(handle, '/v1/anthropic', anthropicBody({ output_config: { effort: 'low' } }), { 'x-bandal-kind': 'summary' })
  assertEquals(response.status, 200)
  const text = await response.text()
  assert(text.includes('안녕하세요'))
  assert(text.trimEnd().endsWith('}'))
  const last = JSON.parse(text.trim().split('\n').at(-1)!.slice(5))
  assertEquals(last.bandal_usage.costUcents, 42)
  assertEquals(sent[0]!.url, 'https://anthropic.test/v1/messages')
  assertEquals(sent[0]!.headers['x-api-key'], 'sk-ant')
  assertEquals(sent[0]!.body.max_tokens, 4000) // from the reservation, after capping 99999 → 8192
  assertEquals(sent[0]!.body.cache_control, { type: 'ephemeral' })
  assertEquals(settled, [{ model: 'claude-haiku-5-5', effort: 'low', kind: 'summary', usage: { input: 1200, output: 80, cacheRead: 300, cacheWrite: 50 }, complete: true }])
})

Deno.test('relays OpenAI and splits cached input out of input tokens', async () => {
  const { handle, settled, sent } = harness({ upstream: () => sse(OPENAI_STREAM) })
  const response = await call(handle, '/v1/openai', { model: 'gpt-6-luna', instructions: 's', input: [{ role: 'user', content: 'hi' }], stream: true, store: true, reasoning: { effort: 'high' } })
  await response.text()
  assertEquals(sent[0]!.url, 'https://openai.test/v1/responses')
  assertEquals(sent[0]!.headers.authorization, 'Bearer sk-oai')
  assertEquals(sent[0]!.body.store, false)
  assertEquals(sent[0]!.body.max_output_tokens, 4000)
  assertEquals(settled[0]!.usage, { input: 600, output: 60, cacheRead: 400, cacheWrite: 0 })
  assertEquals(settled[0]!.effort, 'high')
})

const GOOGLE_STREAM = [
  { candidates: [{ content: { role: 'model', parts: [{ text: '안녕' }] } }], usageMetadata: { promptTokenCount: 900, candidatesTokenCount: 3 } },
  { candidates: [{ content: { role: 'model', parts: [{ text: '하세요' }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 900, cachedContentTokenCount: 200, candidatesTokenCount: 40, thoughtsTokenCount: 10 } },
]
const googleBody = (extra: Record<string, unknown> = {}) => ({ model: 'gemini-test', systemInstruction: { parts: [{ text: 's' }] }, contents: [{ role: 'user', parts: [{ text: 'hi' }] }], ...extra })

Deno.test('relays Gemini to streamGenerateContent with the key header, the model in the URL and thinking billed as output', async () => {
  const { handle, settled, sent } = harness({ upstream: () => sse(GOOGLE_STREAM) })
  const response = await call(handle, '/v1/google', googleBody({ generationConfig: { maxOutputTokens: 99999 } }))
  assertEquals(response.status, 200)
  assert((await response.text()).includes('bandal_usage'))
  assertEquals(sent[0]!.url, 'https://google.test/v1beta/models/gemini-test:streamGenerateContent?alt=sse')
  assertEquals(sent[0]!.headers['x-goog-api-key'], 'g-key')
  assertEquals(sent[0]!.body.model, undefined)
  assertEquals(sent[0]!.body.stream, undefined)
  assertEquals(sent[0]!.body.generationConfig, { maxOutputTokens: 4000 })
  assertEquals(settled, [{ model: 'gemini-test', effort: null, kind: 'question', usage: { input: 700, output: 50, cacheRead: 200, cacheWrite: 0 }, complete: true }])
})

Deno.test('Gemini: only function declarations as tools, known config keys, and its own consent', async () => {
  const { handle, sent } = harness()
  assertEquals((await call(handle, '/v1/google', googleBody({ tools: [{ googleSearch: {} }] }))).status, 400)
  assertEquals((await call(handle, '/v1/google', googleBody({ tools: [{ codeExecution: {} }] }))).status, 400)
  assertEquals((await call(handle, '/v1/google', googleBody({ generationConfig: { responseMimeType: 'application/json' } }))).status, 400)
  assertEquals((await call(handle, '/v1/google', googleBody({ model: 'gpt-6-luna' }))).status, 404)
  assertEquals(sent.length, 0)
  const ok = await call(handle, '/v1/google', googleBody({ tools: [{ functionDeclarations: [{ name: 'read_material', description: 'd', parametersJsonSchema: { type: 'object', properties: {} } }] }] }))
  assertEquals(ok.status, 200)
  await ok.text()
  const refused = await call(harness({ consents: { anthropic: 1 } }).handle, '/v1/google', googleBody())
  assertEquals(refused.status, 409)
  assertEquals((await refused.json()).provider, 'google')
})

Deno.test('refuses unknown fields, disabled or cross-provider models, and bad headers without calling upstream', async () => {
  const { handle, sent } = harness()
  assertEquals((await call(handle, '/v1/anthropic', anthropicBody({ metadata: {} }))).status, 400)
  assertEquals((await call(handle, '/v1/anthropic', anthropicBody({ model: 'claude-opus-5-5' }))).status, 404)
  assertEquals((await call(handle, '/v1/anthropic', anthropicBody({ model: 'gpt-6-luna' }))).status, 404)
  assertEquals((await call(handle, '/v1/anthropic', anthropicBody({ output_config: { effort: 'ultra' } }))).status, 400)
  assertEquals((await call(handle, '/v1/anthropic', anthropicBody(), { 'x-bandal-task': 'nope' })).status, 400)
  assertEquals((await call(handle, '/v1/anthropic', anthropicBody(), { 'x-bandal-kind': 'chat' })).status, 400)
  assertEquals(sent.length, 0)
})

Deno.test('requires consent for the provider at the current version', async () => {
  const { handle, sent } = harness({ consents: { openai: 1 } })
  const response = await call(handle, '/v1/anthropic', anthropicBody())
  assertEquals(response.status, 409)
  assertEquals(await response.json(), { code: 'CONSENT_REQUIRED', provider: 'anthropic', version: 1 })
  assertEquals(sent.length, 0)
})

Deno.test('records consent', async () => {
  const { handle } = harness({ consents: {} })
  const status = await (await call(handle, '/consent', { provider: 'anthropic', version: 1 })).json()
  assertEquals(status.consents, { anthropic: 1 })
  assertEquals((await call(handle, '/consent', { provider: 'gemini', version: 1 })).status, 400)
})

Deno.test('budget and task refusals return 402 with the code and usage', async () => {
  for (const code of ['BUDGET_EXHAUSTED', 'TASK_CAP_REACHED']) {
    const { handle, sent } = harness({ begin: { ok: false, code } })
    const response = await call(handle, '/v1/anthropic', anthropicBody())
    assertEquals(response.status, 402)
    const body = await response.json()
    assertEquals(body.code, code)
    assertEquals(body.usage.plan, 'plus')
    assertEquals(sent.length, 0)
  }
})

Deno.test('context over the model cap is refused', async () => {
  const { handle } = harness()
  const response = await call(handle, '/v1/anthropic', anthropicBody({ messages: [{ role: 'user', content: '가'.repeat(110000) }] }))
  assertEquals(response.status, 413)
  assertEquals((await response.json()).code, 'CONTEXT_TOO_LARGE')
})

Deno.test('upstream refusals are not charged and release the reservation', async () => {
  for (const [status, code, expected] of [[529, 'AI_UNAVAILABLE', 503], [429, 'AI_UNAVAILABLE', 503], [401, 'AI_UNAVAILABLE', 503], [400, 'UPSTREAM_REJECTED', 400]] as const) {
    const { handle, settled, released } = harness({ upstream: () => new Response('{"error":{"message":"nope"}}', { status }) })
    const response = await call(handle, '/v1/anthropic', anthropicBody())
    assertEquals(response.status, expected)
    const body = await response.json()
    assertEquals(body.code, code)
    if (status === 400) assertEquals(body.message, 'nope')
    assertEquals(settled.length, 0)
    assertEquals(released.length, 1)
  }
})

Deno.test('provider-side tools are refused; app tools pass', async () => {
  const { handle, sent } = harness()
  assertEquals((await call(handle, '/v1/anthropic', anthropicBody({ tools: [{ type: 'web_search_20260209', name: 'web_search' }] }))).status, 400)
  assertEquals((await call(handle, '/v1/openai', { model: 'gpt-6-luna', input: [], tools: [{ type: 'web_search' }] })).status, 400)
  assertEquals((await call(handle, '/v1/openai', { model: 'gpt-6-luna', input: [], tools: [{ type: 'mcp', server_url: 'https://evil.test' }] })).status, 400)
  assertEquals(sent.length, 0)
  const ok = await call(handle, '/v1/anthropic', anthropicBody({ tools: [{ name: 'read_material', description: 'd', input_schema: { type: 'object', properties: {} } }] }))
  assertEquals(ok.status, 200)
  await ok.text()
})

Deno.test('OpenAI incomplete responses are charged with their reported usage', async () => {
  const { handle, settled } = harness({ upstream: () => sse([{ type: 'response.output_text.delta', delta: 'long' }, { type: 'response.incomplete', response: { usage: { input_tokens: 500, output_tokens: 8000 } } }]) })
  await (await call(handle, '/v1/openai', { model: 'gpt-6-luna', input: [] })).text()
  assertEquals(settled[0]!.usage.output, 8000)
  assertEquals(settled[0]!.complete, false)
})

// 5xx before the stream is covered by 'upstream refusals'; these are failures after it opened.
const MODEL_FAILURES: [string, string, () => Response][] = [
  ['an Anthropic error event mid-stream', '/v1/anthropic', () => sse([...ANTHROPIC_STREAM.slice(0, 2), { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } }])],
  ['a stream cut off before message_stop', '/v1/anthropic', () => sse(ANTHROPIC_STREAM.slice(0, 2))],
  ['an upstream read that fails (timeout abort, network)', '/v1/anthropic', () => {
    let sent = false
    return new Response(new ReadableStream<Uint8Array>({ pull(c) {
      if (sent) { c.error(new DOMException('aborted', 'AbortError')); return }
      sent = true; c.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(ANTHROPIC_STREAM[0])}\n\n`))
    } }))
  }],
  ['an empty Anthropic answer', '/v1/anthropic', () => sse([ANTHROPIC_STREAM[0], { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 2 } }, { type: 'message_stop' }])],
  ['OpenAI response.failed', '/v1/openai', () => sse([{ type: 'response.output_text.delta', delta: 'Hi' }, { type: 'response.failed', response: { usage: { input_tokens: 900, output_tokens: 3 } } }])],
  ['an empty OpenAI answer', '/v1/openai', () => sse([{ type: 'response.completed', response: { usage: { input_tokens: 900, output_tokens: 0 } } }])],
]
for (const [name, path, upstream] of MODEL_FAILURES) {
  Deno.test(`${name} is not charged and releases the reservation`, async () => {
    const { handle, settled, released } = harness({ upstream })
    const body = path === '/v1/openai' ? { model: 'gpt-6-luna', input: [] } : anthropicBody()
    const text = await (await call(handle, path, body)).text()
    assertEquals(settled.length, 0)
    assertEquals(released.length, 1)
    assert(!text.includes('bandal_usage'))
  })
}

Deno.test('a tool call with empty arguments is a delivered answer', async () => {
  const { handle, settled } = harness({ upstream: () => sse([ANTHROPIC_STREAM[0],
    { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 't', name: 'list_materials', input: {} } },
    { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 12 } }, { type: 'message_stop' }]) })
  await (await call(handle, '/v1/anthropic', anthropicBody())).text()
  assertEquals(settled.length, 1)
  assertEquals(settled[0]!.usage.output, 12)
})

Deno.test('a client that leaves mid-stream is still charged once, with the provider\'s usage', async () => {
  let push!: ReadableStreamDefaultController<Uint8Array>
  const body = new ReadableStream<Uint8Array>({ start(c) { push = c } })
  const { handle, settled } = harness({ upstream: () => new Response(body) })
  const response = await call(handle, '/v1/anthropic', anthropicBody())
  const encode = (e: unknown) => new TextEncoder().encode(`data: ${JSON.stringify(e)}\n\n`)
  push.enqueue(encode(ANTHROPIC_STREAM[0]))
  const reader = response.body!.getReader()
  await reader.read()
  await reader.cancel()
  assertEquals(settled.length, 0) // still reading upstream
  for (const e of ANTHROPIC_STREAM.slice(1)) push.enqueue(encode(e))
  push.close()
  await new Promise(resolve => setTimeout(resolve, 10))
  assertEquals(settled.length, 1)
  assertEquals(settled[0]!.complete, true)
  assertEquals(settled[0]!.usage.output, 80)
})

Deno.test('a failed settle is retried', async () => {
  const h = harness()
  let failures = 1
  const handle = createAIProxy({
    store: { ...h.store, settle: () => failures-- > 0 ? Promise.reject(new Error('db')) : Promise.resolve({ costUcents: 7, status: {} }) },
    authenticate: () => Promise.resolve('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    fetch: () => Promise.resolve(sse(ANTHROPIC_STREAM)),
    keys: { anthropic: 'k' }, baseURL: { anthropic: 'https://a.test', openai: 'https://o.test', google: 'https://g.test' },
  })
  const text = await (await call(handle, '/v1/anthropic', anthropicBody())).text()
  assert(text.includes('"costUcents":7'))
})

Deno.test('meter handles events split across chunks', () => {
  const meter = new UsageMeter('anthropic')
  const text = ANTHROPIC_STREAM.map(e => `data: ${JSON.stringify(e)}\n\n`).join('')
  for (let i = 0; i < text.length; i += 7) meter.feed(text.slice(i, i + 7))
  assert(meter.completed)
  assertEquals(meter.usage.output, 80)
})

Deno.test('images count as fixed tokens, not base64 size', () => {
  const image = 'A'.repeat(3_000_000)
  assert(estimateTokens({ messages: [{ content: [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: image } }] }] }) < 3010)
  assert(estimateTokens({ messages: [{ content: [{ type: 'tool_use', input: { data: image } }] }] }) > 900_000) // not an image: counted by size
  assert(estimateTokens({ input: [{ content: [{ type: 'input_image', image_url: `data:image/png;base64,${image}` }] }] }) < 3010)
})
