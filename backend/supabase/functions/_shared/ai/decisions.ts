// POST /v1/openai/decisions: OpenAI's Decisions API (POST /v1/decisions) for the app, metered on input tokens only.
// The decision model writes nothing: the app gets back each answer's probability, choice or score and confidence,
// never text or links. The request is filtered to known fields; no images, nothing a question could carry beyond text.
import { estimateTokens, ProxyError, type ModelRow } from './request.ts'
import type { Deps } from './service.ts'
import { int, record } from './usage.ts'

/** Models the Decisions API takes (and that must also be an enabled `openai` row in `ai_models`). */
export const DECISION_MODELS = new Set(['gpt-6-luna'])
export const DECISION_LIMITS = {
  questions: 8, choices: 12, levels: 10,
  nameCharacters: 64, instructionCharacters: 1000, valueCharacters: 80, descriptionCharacters: 400,
  messages: 8, inputCharacters: 6000,
  /** The whole request (input and questions), estimated as the relay does (UTF-8 bytes / 3). */
  inputTokens: 4000,
  bodyBytes: 64 * 1024,
}
/** A decision answers in well under a second; one still running after this is given up like a stalled stream. */
const DECISION_TIMEOUT_MS = 20_000
const SETTLE_RETRY_MS = [0, 500, 2000]
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
const NAME = /^[A-Za-z][A-Za-z0-9_-]*$/
const TOP_KEYS = new Set(['model', 'input', 'questions'])
const MESSAGE_KEYS = new Set(['type', 'role', 'content'])
const ROLES = new Set(['developer', 'system', 'user'])
const QUESTION_KEYS = new Map<string, Set<string>>([
  ['predicate', new Set(['type', 'name', 'instructions'])],
  ['choice', new Set(['type', 'name', 'instructions', 'choices'])],
  ['score', new Set(['type', 'name', 'instructions', 'levels'])],
])

interface Question { type: 'predicate' | 'choice' | 'score'; name: string; values: Set<string>; levels: number }
export interface PreparedDecision {
  body: Record<string, unknown>; model: ModelRow; questions: Map<string, Question>; estimatedInput: number
}
export type DecisionAnswer =
  | { type: 'predicate'; name: string; probability: number }
  | { type: 'choice'; name: string; choice: string; confidence: number; probabilities: { value: string; probability: number }[] }
  | { type: 'score'; name: string; score: number; confidence: number; probabilities: { value: number; probability: number }[] }
  | { type: 'refusal'; name: string }

const invalid = (field: string) => new ProxyError('INVALID_REQUEST', 400, { field })

export function prepareDecision(input: unknown, models: ModelRow[]): PreparedDecision {
  if (!isObject(input)) throw new ProxyError('INVALID_REQUEST', 400)
  const unknown = Object.keys(input).find(key => !TOP_KEYS.has(key))
  if (unknown) throw invalid(unknown)
  const model = models.find(row => row.id === input.model && row.provider === 'openai' && row.enabled && DECISION_MODELS.has(row.id))
  if (!model) throw new ProxyError('MODEL_UNAVAILABLE', 404)
  checkInput(input.input)

  const list = input.questions
  if (!Array.isArray(list) || list.length < 1 || list.length > DECISION_LIMITS.questions) throw invalid('questions')
  const questions = new Map<string, Question>()
  for (const item of list) {
    const keys = isObject(item) && typeof item.type === 'string' ? QUESTION_KEYS.get(item.type) : undefined
    if (!isObject(item) || !keys || Object.keys(item).some(key => !keys.has(key))) throw invalid('questions')
    const type = item.type as Question['type']
    const name = item.name
    if (typeof name !== 'string' || name.length > DECISION_LIMITS.nameCharacters || !NAME.test(name) || questions.has(name)) throw invalid('questions')
    // Only a string: the array form of instructions can carry an image.
    if (!text(item.instructions, DECISION_LIMITS.instructionCharacters)) throw invalid('questions')
    const values = new Set<string>()
    let levels = 0
    if (type === 'choice') {
      const choices = item.choices
      if (!Array.isArray(choices) || choices.length < 2 || choices.length > DECISION_LIMITS.choices) throw invalid('choices')
      for (const choice of choices) {
        if (!isObject(choice) || Object.keys(choice).some(key => key !== 'value' && key !== 'description') ||
            !text(choice.value, DECISION_LIMITS.valueCharacters) || values.has(choice.value as string) ||
            (choice.description !== undefined && !text(choice.description, DECISION_LIMITS.descriptionCharacters))) throw invalid('choices')
        values.add(choice.value as string)
      }
    } else if (type === 'score') {
      const list = item.levels
      if (!Array.isArray(list) || list.length < 2 || list.length > DECISION_LIMITS.levels) throw invalid('levels')
      for (const level of list) {
        if (!isObject(level) || Object.keys(level).some(key => key !== 'label' && key !== 'description') ||
            !text(level.label, DECISION_LIMITS.valueCharacters) ||
            (level.description !== undefined && !text(level.description, DECISION_LIMITS.descriptionCharacters))) throw invalid('levels')
      }
      levels = list.length
    }
    questions.set(name, { type, name, values, levels })
  }
  const body = { model: model.id, input: input.input, questions: list }
  const estimatedInput = estimateTokens({ input: input.input, questions: list })
  if (estimatedInput > DECISION_LIMITS.inputTokens) throw new ProxyError('CONTEXT_TOO_LARGE', 413, { limit: DECISION_LIMITS.inputTokens, estimate: estimatedInput })
  return { body, model, questions, estimatedInput }
}

/** A string, or text-only messages from the developer, system or user. No images, files, JSON parts or tool items. */
function checkInput(value: unknown) {
  if (typeof value === 'string') {
    if (!text(value, DECISION_LIMITS.inputCharacters)) throw invalid('input')
    return
  }
  if (!Array.isArray(value) || value.length < 1 || value.length > DECISION_LIMITS.messages) throw invalid('input')
  let characters = 0
  for (const message of value) {
    if (!isObject(message) || Object.keys(message).some(key => !MESSAGE_KEYS.has(key)) || !ROLES.has(String(message.role)) ||
        (message.type !== undefined && message.type !== 'message')) throw invalid('input')
    const parts = typeof message.content === 'string' ? [{ type: 'input_text', text: message.content }] : message.content
    if (!Array.isArray(parts) || parts.length < 1) throw invalid('input')
    for (const part of parts) {
      if (!isObject(part) || part.type !== 'input_text' || Object.keys(part).some(key => key !== 'type' && key !== 'text') ||
          typeof part.text !== 'string' || !part.text) throw invalid('input')
      characters += part.text.length
    }
  }
  if (characters > DECISION_LIMITS.inputCharacters) throw invalid('input')
}

/** Only the numbers and the chosen value of each answer to a question that was asked; text the model wrote is dropped. */
export function decisionAnswers(response: unknown, questions: Map<string, Question>): DecisionAnswer[] {
  const list = record(response).answers
  const answers: DecisionAnswer[] = []
  const seen = new Set<string>()
  for (const raw of Array.isArray(list) ? list : []) {
    const item = record(raw)
    const question = typeof item.name === 'string' ? questions.get(item.name) : undefined
    if (!question || seen.has(question.name)) continue
    const answer = readAnswer(item, question)
    if (!answer) continue
    seen.add(question.name)
    answers.push(answer)
  }
  return answers
}

function readAnswer(item: Record<string, unknown>, question: Question): DecisionAnswer | null {
  const name = question.name
  if (item.type === 'refusal') return { type: 'refusal', name }
  if (item.type !== question.type) return null
  if (question.type === 'predicate') {
    return unit(item.probability) ? { type: 'predicate', name, probability: item.probability } : null
  }
  if (!unit(item.confidence)) return null
  const probabilities = (Array.isArray(item.probabilities) ? item.probabilities : []).map(record)
  if (question.type === 'choice') {
    if (typeof item.choice !== 'string' || !question.values.has(item.choice)) return null
    return { type: 'choice', name, choice: item.choice, confidence: item.confidence, probabilities: probabilities
      .filter(entry => typeof entry.value === 'string' && question.values.has(entry.value) && unit(entry.probability))
      .map(entry => ({ value: entry.value as string, probability: entry.probability as number })) }
  }
  if (typeof item.score !== 'number' || !Number.isFinite(item.score) || item.score < 0 || item.score > question.levels - 1) return null
  return { type: 'score', name, score: item.score, confidence: item.confidence, probabilities: probabilities
    .filter(entry => Number.isInteger(entry.value) && (entry.value as number) >= 0 && (entry.value as number) < question.levels && unit(entry.probability))
    .map(entry => ({ value: entry.value as number, probability: entry.probability as number })) }
}

/** The route: same sign-in, OpenAI consent and budget checks as the relay; reserves and charges input only. */
export async function decide(deps: Deps, request: Request, actor: string): Promise<Response> {
  const task = request.headers.get('x-bandal-task') ?? ''
  if (!UUID.test(task)) throw new ProxyError('INVALID_REQUEST', 400, { field: 'headers' })
  const key = deps.keys.openai
  if (!key) throw new ProxyError('AI_UNAVAILABLE', 503)
  const raw = await request.text()
  if (new TextEncoder().encode(raw).length > DECISION_LIMITS.bodyBytes) throw new ProxyError('CONTEXT_TOO_LARGE', 413)
  let input: unknown
  try { input = JSON.parse(raw) } catch { throw new ProxyError('INVALID_REQUEST', 400) }

  const [models, settings, status] = await Promise.all([deps.store.models(), deps.store.settings(), deps.store.status(actor)])
  if ((status.consents?.openai ?? 0) < settings.consent_version) throw new ProxyError('CONSENT_REQUIRED', 409, { provider: 'openai', version: settings.consent_version })
  const prepared = prepareDecision(input, models)
  const step = crypto.randomUUID()
  // No output is billed, so none is reserved: refused only when the input does not fit what is left.
  const begun = await deps.store.begin(actor, task, step, prepared.model.id, prepared.estimatedInput, 0)
  if (!begun.ok) throw new ProxyError(begun.code ?? 'BUDGET_EXHAUSTED', 402, { usage: begun.status })
  const release = () => deps.store.release(actor, step).catch(() => {})

  const abort = new AbortController()
  const timer = setTimeout(() => abort.abort(), DECISION_TIMEOUT_MS)
  let reply: unknown
  try {
    let upstream: Response
    try {
      upstream = await deps.fetch(`${deps.baseURL.openai}/v1/decisions`, {
        method: 'POST', signal: abort.signal, body: JSON.stringify(prepared.body),
        headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
      })
    } catch (error) {
      await release()
      deps.log?.('ai upstream unreachable', { provider: 'openai', route: 'decisions', error: String(error) })
      throw new ProxyError('AI_UNAVAILABLE', 503)
    }
    if (!upstream.ok) {
      await release()
      const detail = (await upstream.text().catch(() => '')).slice(0, 4096)
      deps.log?.('ai upstream error', { provider: 'openai', route: 'decisions', status: upstream.status, detail })
      if (upstream.status === 400) throw new ProxyError('UPSTREAM_REJECTED', 400, { message: upstreamMessage(detail) })
      throw new ProxyError('AI_UNAVAILABLE', 503, { upstream: upstream.status })
    }
    try { reply = await upstream.json() } catch (error) {
      await release()
      deps.log?.('ai stream interrupted', { provider: 'openai', route: 'decisions', error: String(error) })
      throw new ProxyError('AI_UNAVAILABLE', 503)
    }
  } finally {
    clearTimeout(timer)
  }

  const answers = decisionAnswers(reply, prepared.questions)
  // Nothing but refusals (or nothing readable) reached the user: not theirs to pay for, as with an empty text answer.
  if (!answers.some(answer => answer.type !== 'refusal')) {
    deps.log?.('ai step not billed', { provider: 'openai', route: 'decisions', step, answers: answers.length })
    await release()
    return Response.json({ answers }, { headers: HEADERS })
  }
  const reported = int(record(record(reply).usage).input_tokens)
  const usage = { input: reported > 0 ? reported : prepared.estimatedInput, output: 0, cacheRead: 0, cacheWrite: 0 }
  for (const delay of SETTLE_RETRY_MS) {
    if (delay) await new Promise(resolve => setTimeout(resolve, delay))
    try {
      await deps.store.settle(actor, task, step, prepared.model.id, null, 'decide', usage, true)
      break
    } catch (error) {
      // ponytail: as with the relay, three failed settles leave the step unbilled once its reservation expires.
      deps.log?.('ai settle failed', { step, error: String(error) })
    }
  }
  return Response.json({ answers }, { headers: HEADERS })
}

function upstreamMessage(detail: string): string {
  try {
    const message = (JSON.parse(detail) as { error?: { message?: unknown } }).error?.message
    return typeof message === 'string' ? message.slice(0, 500) : ''
  } catch { return '' }
}
function text(value: unknown, limit: number): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= limit
}
function unit(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1
}
function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value)
}
