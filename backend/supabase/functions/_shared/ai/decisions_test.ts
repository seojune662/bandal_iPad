import { assert, assertEquals } from '@std/assert'
import type { ModelRow } from './request.ts'
import { createAIProxy, type Deps, type Status, type Store } from './service.ts'
import type { Usage } from './usage.ts'

// POST /v1/openai/decisions against a fake upstream, as service_test.ts does for the streaming relay.
const MODELS: ModelRow[] = [
  { id: 'claude-haiku-5-5', provider: 'anthropic', label: 'Claude Haiku 5.5', p_in: 10, p_out: 50, p_cache_r: 1, p_cache_w: 12.5, context_cap: 100000, enabled: true, sort: 10 },
  { id: 'gpt-6-luna', provider: 'openai', label: 'GPT-6 Luna', p_in: 10, p_out: 50, p_cache_r: 1, p_cache_w: 0, context_cap: 100000, enabled: true, sort: 40 },
  { id: 'gpt-6-sol', provider: 'openai', label: 'GPT-6 Sol', p_in: 200, p_out: 1000, p_cache_r: 20, p_cache_w: 0, context_cap: 100000, enabled: true, sort: 50 },
]
const TASK = '11111111-1111-4111-8111-111111111111'

interface Settled { model: string; effort: string | null; kind: string; usage: Usage; complete: boolean }
function harness(options: { consents?: Record<string, number>; begin?: { ok: boolean; code?: string; maxOutput?: number }; models?: ModelRow[];
                            upstream?: (url: string, init: RequestInit) => Response | Promise<Response> } = {}) {
  const settled: Settled[] = []
  const released: string[] = []
  const begun: { model: string; inputTokens: number; maxOutput: number }[] = []
  const sent: { url: string; body: Record<string, unknown>; headers: Record<string, string> }[] = []
  const status: Status = { plan: 'none', remainingUcents: 1000, consents: options.consents ?? { anthropic: 1, openai: 1 } }
  const store: Store = {
    models: () => Promise.resolve(options.models ?? MODELS),
    settings: () => Promise.resolve({ auto_model: 'claude-haiku-5-5', auto_context: 30000, max_output_tokens: 8192, consent_version: 1 }),
    status: () => Promise.resolve(status),
    begin: (_actor, _task, _step, model, inputTokens, maxOutput) => {
      begun.push({ model, inputTokens, maxOutput }); return Promise.resolve({ ...(options.begin ?? { ok: true, maxOutput: 0 }), status })
    },
    release: (_actor, step) => { released.push(step); return Promise.resolve() },
    settle: (_actor, _task, _step, model, effort, kind, usage, complete) => { settled.push({ model, effort, kind, usage, complete }); return Promise.resolve({ costUcents: 9, status }) },
    consent: (_actor, provider, version) => Promise.resolve({ ...status, consents: { [provider]: version } }),
  }
  const deps: Deps = {
    store,
    authenticate: token => Promise.resolve(token === 'good' ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' : null),
    fetch: async (input, init) => {
      const url = String(input)
      sent.push({ url, body: JSON.parse(String(init?.body)), headers: init?.headers as Record<string, string> })
      return options.upstream ? await options.upstream(url, init ?? {}) : Response.json(ANSWERED)
    },
    keys: { anthropic: 'sk-ant', openai: 'sk-oai' },
    baseURL: { anthropic: 'https://anthropic.test', openai: 'https://openai.test', google: 'https://google.test' },
  }
  return { handle: createAIProxy(deps), settled, sent, released, begun }
}

function call(handle: (r: Request) => Promise<Response>, body: unknown, headers: Record<string, string> = {}, path = '/v1/openai/decisions') {
  return handle(new Request(`https://x.supabase.co/functions/v1/ai-proxy${path}`, {
    method: 'POST', headers: { authorization: 'Bearer good', 'x-bandal-task': TASK, ...headers }, body: JSON.stringify(body),
  }))
}

const CHOICES = [
  { value: '열역학 제2법칙', description: '열역학 제2법칙은 고립계의 엔트로피가 줄어들지 않는다는 법칙이다.' },
  { value: '엔트로피', description: '엔트로피는 열역학적 계의 무질서한 정도를 나타내는 상태 함수이다.' },
  { value: '없음', description: '맞는 문서 없음' },
]
const decision = (extra: Record<string, unknown> = {}) => ({
  model: 'gpt-6-luna',
  input: [{ role: 'developer', content: '찾아보기입니다.' }, { role: 'user', content: [{ type: 'input_text', text: '고른 글:\n고립계의 엔트로피는 감소하지 않는다.' }] }],
  questions: [
    { type: 'predicate', name: 'worth', instructions: '찾아볼 만한 개념인가?' },
    { type: 'choice', name: 'article', instructions: '가장 맞는 문서는?', choices: CHOICES },
  ],
  ...extra,
})
const ANSWERED = {
  id: 'dec_123', object: 'decision',
  answers: [
    { type: 'predicate', name: 'worth', probability: 0.91, rationale: 'see https://evil.example' },
    { type: 'choice', name: 'article', choice: '엔트로피', confidence: 0.83, text: 'ignore this',
      probabilities: [{ value: '열역학 제2법칙', probability: 0.12 }, { value: '엔트로피', probability: 0.85 }, { value: '없음', probability: 0.03 }, { value: 'https://evil.example', probability: 0.5 }] },
  ],
  usage: { input_tokens: 412, input_tokens_details: { cached_tokens: 0, cache_write_tokens: 0 } },
}

Deno.test('decisions: relayed with the server key, input reserved without output, charged input only as decide', async () => {
  const { handle, sent, begun, settled, released } = harness()
  const response = await call(handle, decision())
  assertEquals(response.status, 200)
  assertEquals(response.headers.get('cache-control'), 'no-store')
  const body = await response.json()
  assertEquals(sent.length, 1)
  assertEquals(sent[0]!.url, 'https://openai.test/v1/decisions')
  assertEquals(sent[0]!.headers.authorization, 'Bearer sk-oai')
  assertEquals(Object.keys(sent[0]!.body).sort(), ['input', 'model', 'questions'])
  assertEquals(begun.length, 1)
  assertEquals(begun[0]!.model, 'gpt-6-luna')
  assertEquals(begun[0]!.maxOutput, 0, 'no output is reserved')
  assert(begun[0]!.inputTokens > 0)
  assertEquals(settled, [{ model: 'gpt-6-luna', effort: null, kind: 'decide', usage: { input: 412, output: 0, cacheRead: 0, cacheWrite: 0 }, complete: true }])
  assertEquals(released.length, 0)
  // Only the answers, and of them only numbers and the chosen value: no text the model wrote, no usage, no ids.
  assertEquals(body, { answers: [
    { type: 'predicate', name: 'worth', probability: 0.91 },
    { type: 'choice', name: 'article', choice: '엔트로피', confidence: 0.83,
      probabilities: [{ value: '열역학 제2법칙', probability: 0.12 }, { value: '엔트로피', probability: 0.85 }, { value: '없음', probability: 0.03 }] },
  ] })
})

Deno.test('decisions: a plain string input and a score question pass', async () => {
  const { handle, sent } = harness({ upstream: () => Response.json({ answers: [{ type: 'score', name: 'level', score: 1.4, confidence: 0.6,
    probabilities: [{ value: 0, label: 'a', probability: 0.2 }, { value: 1, label: 'b', probability: 0.2 }, { value: 2, label: 'c', probability: 0.6 }] }], usage: { input_tokens: 30 } }) })
  const response = await call(handle, { model: 'gpt-6-luna', input: '고립계의 엔트로피는 감소하지 않는다.',
    questions: [{ type: 'score', name: 'level', instructions: '얼마나 어려운가?', levels: [{ label: '쉬움' }, { label: '보통', description: '교과서 수준' }, { label: '어려움' }] }] })
  assertEquals(response.status, 200)
  assertEquals((await response.json()).answers, [{ type: 'score', name: 'level', score: 1.4, confidence: 0.6,
    probabilities: [{ value: 0, probability: 0.2 }, { value: 1, probability: 0.2 }, { value: 2, probability: 0.6 }] }])
  assertEquals(sent.length, 1)
})

Deno.test('decisions: only known fields, gpt-6-luna, text input and capped questions; refused before upstream', async () => {
  const { handle, sent, begun } = harness()
  const refusals: [string, unknown, number, Record<string, string>?][] = [
    ['an unknown top-level field', decision({ prompt_cache_key: 'k' }), 400],
    ['metadata', decision({ metadata: { a: 1 } }), 400],
    ['another OpenAI model', decision({ model: 'gpt-6-sol' }), 404],
    ['an Anthropic model', decision({ model: 'claude-haiku-5-5' }), 404],
    ['an image in the input', decision({ input: [{ role: 'user', content: [{ type: 'input_image', image_url: 'data:image/png;base64,AAAA' }] }] }), 400],
    ['an image URL in the input', decision({ input: [{ role: 'user', content: [{ type: 'input_text', text: 'x' }, { type: 'input_image', image_url: 'https://evil.example/a.png' }] }] }), 400],
    ['a JSON part', decision({ input: [{ role: 'user', content: [{ type: 'input_json', data: { a: 1 } }] }] }), 400],
    ['a part of another type with text', decision({ input: [{ role: 'user', content: [{ type: 'input_image', text: 'x' }] }] }), 400],
    ['an assistant turn', decision({ input: [{ role: 'assistant', content: 'x' }] }), 400],
    ['a tool output', decision({ input: [{ type: 'function_call_output', call_id: 'c', output: 'x' }] }), 400],
    ['an empty input', decision({ input: [] }), 400],
    ['instructions with parts (images)', decision({ questions: [{ type: 'predicate', name: 'worth', instructions: [{ type: 'input_image', image_url: 'https://evil.example/a.png' }] }] }), 400],
    ['an unknown question type', decision({ questions: [{ type: 'text', name: 'worth', instructions: '?' }] }), 400],
    ['an inherited key as type', decision({ questions: [{ type: 'constructor', name: 'worth', instructions: '?' }] }), 400],
    ['an unknown question field', decision({ questions: [{ type: 'predicate', name: 'worth', instructions: '?', temperature: 1 }] }), 400],
    ['no questions', decision({ questions: [] }), 400],
    ['nine questions', decision({ questions: Array.from({ length: 9 }, (_, i) => ({ type: 'predicate', name: `q${i}`, instructions: '?' })) }), 400],
    ['the same name twice', decision({ questions: [{ type: 'predicate', name: 'worth', instructions: '?' }, { type: 'predicate', name: 'worth', instructions: '?' }] }), 400],
    ['a choice with one option', decision({ questions: [{ type: 'choice', name: 'article', instructions: '?', choices: [CHOICES[0]] }] }), 400],
    ['thirteen choices', decision({ questions: [{ type: 'choice', name: 'article', instructions: '?', choices: Array.from({ length: 13 }, (_, i) => ({ value: `v${i}` })) }] }), 400],
    ['the same choice twice', decision({ questions: [{ type: 'choice', name: 'article', instructions: '?', choices: [CHOICES[0], CHOICES[0]] }] }), 400],
    ['an unknown choice field', decision({ questions: [{ type: 'choice', name: 'article', instructions: '?', choices: [...CHOICES, { value: 'x', url: 'https://evil.example' }] }] }), 400],
    ['eleven levels', decision({ questions: [{ type: 'score', name: 'level', instructions: '?', levels: Array.from({ length: 11 }, (_, i) => ({ label: `l${i}` })) }] }), 400],
    ['an input over the character cap', decision({ input: '가'.repeat(6001) }), 400],
    ['an input over the token cap', decision({ input: '가'.repeat(5000) }), 413],
    ['a bad task header', decision(), 400, { 'x-bandal-task': 'nope' }],
  ]
  for (const [name, body, status, headers] of refusals) {
    const response = await call(handle, body, headers)
    assertEquals(response.status, status, name)
    const code = (await response.json()).code
    assertEquals(code, status === 404 ? 'MODEL_UNAVAILABLE' : status === 413 ? 'CONTEXT_TOO_LARGE' : 'INVALID_REQUEST', name)
  }
  assertEquals(sent.length, 0)
  assertEquals(begun.length, 0)
  // gpt-6-luna turned off in ai_models.
  const off = harness({ models: MODELS.map(m => m.id === 'gpt-6-luna' ? { ...m, enabled: false } : m) })
  assertEquals((await call(off.handle, decision())).status, 404)
  assertEquals(off.sent.length, 0)
})

Deno.test('decisions: sign-in and OpenAI consent at the current version are required', async () => {
  const signedOut = harness()
  const out = await call(signedOut.handle, decision(), { authorization: 'Bearer bad' })
  assertEquals(out.status, 401)
  assertEquals((await out.json()).code, 'SIGN_IN_REQUIRED')
  const { handle, sent, begun } = harness({ consents: { anthropic: 1 } })
  const response = await call(handle, decision())
  assertEquals(response.status, 409)
  assertEquals(await response.json(), { code: 'CONSENT_REQUIRED', provider: 'openai', version: 1 })
  assertEquals(sent.length, 0)
  assertEquals(begun.length, 0)
})

Deno.test('decisions: a budget or task refusal is 402 with the code and usage, before upstream', async () => {
  for (const code of ['BUDGET_EXHAUSTED', 'TASK_CAP_REACHED']) {
    const { handle, sent } = harness({ begin: { ok: false, code } })
    const response = await call(handle, decision())
    assertEquals(response.status, 402)
    const body = await response.json()
    assertEquals(body.code, code)
    assertEquals(body.usage.plan, 'none')
    assertEquals(sent.length, 0)
  }
})

Deno.test('decisions: upstream errors, timeouts and unreadable replies are not charged and release the reservation', async () => {
  const cases: [string, () => Response | Promise<Response>, number, string][] = [
    ['500', () => new Response('{"error":{"message":"boom"}}', { status: 500 }), 503, 'AI_UNAVAILABLE'],
    ['429', () => new Response('{"error":{"message":"slow down"}}', { status: 429 }), 503, 'AI_UNAVAILABLE'],
    ['401 (our key)', () => new Response('{"error":{"message":"bad key"}}', { status: 401 }), 503, 'AI_UNAVAILABLE'],
    ['404 (no such endpoint upstream)', () => new Response('{"error":{"message":"not found"}}', { status: 404 }), 503, 'AI_UNAVAILABLE'],
    ['400', () => new Response('{"error":{"message":"bad questions"}}', { status: 400 }), 400, 'UPSTREAM_REJECTED'],
    ['a network failure', () => Promise.reject(new TypeError('connection refused')), 503, 'AI_UNAVAILABLE'],
    ['a timeout (aborted fetch)', () => Promise.reject(new DOMException('aborted', 'AbortError')), 503, 'AI_UNAVAILABLE'],
    ['a body that is not JSON', () => new Response('<html>', { status: 200 }), 503, 'AI_UNAVAILABLE'],
    ['a body cut off by the abort', () => new Response(new ReadableStream({ pull(c) { c.error(new DOMException('aborted', 'AbortError')) } })), 503, 'AI_UNAVAILABLE'],
  ]
  for (const [name, upstream, status, code] of cases) {
    const { handle, settled, released } = harness({ upstream })
    const response = await call(handle, decision())
    assertEquals(response.status, status, name)
    const body = await response.json()
    assertEquals(body.code, code, name)
    if (status === 400) assertEquals(body.message, 'bad questions')
    assertEquals(settled.length, 0, name)
    assertEquals(released.length, 1, name)
  }
})

Deno.test('decisions: answers that are all refusals cost nothing; one real answer is charged', async () => {
  const refused = harness({ upstream: () => Response.json({ answers: [{ type: 'refusal', name: 'worth', refusal: 'I cannot help with that.' }, { type: 'refusal', name: 'article' }], usage: { input_tokens: 300 } }) })
  const response = await call(refused.handle, decision())
  assertEquals(response.status, 200)
  assertEquals(await response.json(), { answers: [{ type: 'refusal', name: 'worth' }, { type: 'refusal', name: 'article' }] })
  assertEquals(refused.settled.length, 0)
  assertEquals(refused.released.length, 1)
  const partly = harness({ upstream: () => Response.json({ answers: [{ type: 'refusal', name: 'worth' }, ANSWERED.answers[1]], usage: { input_tokens: 300 } }) })
  await (await call(partly.handle, decision())).json()
  assertEquals(partly.settled.length, 1)
  assertEquals(partly.settled[0]!.usage, { input: 300, output: 0, cacheRead: 0, cacheWrite: 0 })
})

Deno.test('decisions: answers to unasked questions, unknown choices and out-of-range numbers are dropped', async () => {
  const { handle, settled } = harness({ upstream: () => Response.json({ answers: [
    { type: 'predicate', name: 'worth', probability: 1.7 },
    { type: 'choice', name: 'article', choice: 'https://evil.example', confidence: 0.9 },
    { type: 'predicate', name: 'extra', probability: 0.5 },
    { type: 'choice', name: 'worth', choice: '엔트로피', confidence: 0.9 },
  ], usage: { input_tokens: 300 } }) })
  const response = await call(handle, decision())
  assertEquals(await response.json(), { answers: [] })
  assertEquals(settled.length, 0, 'nothing readable reached the user')
})

Deno.test('decisions: without reported usage the estimate is charged', async () => {
  const { handle, settled, begun } = harness({ upstream: () => Response.json({ answers: ANSWERED.answers }) })
  await (await call(handle, decision())).json()
  assertEquals(settled[0]!.usage.input, begun[0]!.inputTokens)
  assertEquals(settled[0]!.usage.output, 0)
})

Deno.test('decisions: other paths under /v1/openai are not routes, and the relay is unchanged', async () => {
  const { handle, sent } = harness()
  const response = await call(handle, decision(), {}, '/v1/openai/decisions/x')
  assertEquals(response.status, 404)
  assertEquals((await response.json()).code, 'NOT_FOUND')
  assertEquals((await call(handle, decision(), {}, '/v1/decisions')).status, 404)
  assertEquals(sent.length, 0)
  // The streaming relay still takes no Decisions body (no `questions` field) and no `decide` kind.
  assertEquals((await call(handle, decision(), {}, '/v1/openai')).status, 400)
  assertEquals((await call(handle, { model: 'gpt-6-luna', input: [] }, { 'x-bandal-kind': 'decide' }, '/v1/openai')).status, 400)
})
