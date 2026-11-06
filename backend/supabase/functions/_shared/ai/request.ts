// Turns the app's provider request into the one the proxy sends upstream: only known
// fields and client-defined tools, streaming forced, prompt caching on for Anthropic.
// The output limit is set later from the reservation (withOutputLimit).
import type { Provider } from './usage.ts'

export class ProxyError extends Error {
  constructor(readonly code: string, readonly status: number, readonly extra: Record<string, unknown> = {}) { super(code) }
}

export interface ModelRow {
  id: string; provider: Provider; label: string
  p_in: number; p_out: number; p_cache_r: number; p_cache_w: number
  context_cap: number; enabled: boolean; sort: number
}

const ANTHROPIC_KEYS = new Set(['model', 'system', 'messages', 'max_tokens', 'stream', 'tools', 'output_config'])
const OPENAI_KEYS = new Set(['model', 'instructions', 'input', 'stream', 'store', 'include', 'tools', 'reasoning', 'max_output_tokens'])
// Only tools the app runs itself: provider-side tools (web search, code execution, MCP…)
// are billed per call outside token usage and would escape metering.
const ANTHROPIC_TOOL_KEYS = new Set(['name', 'description', 'input_schema', 'eager_input_streaming', 'strict'])
const OPENAI_TOOL_KEYS = new Set(['type', 'name', 'description', 'parameters', 'strict'])
const ANTHROPIC_EFFORT = new Set(['low', 'medium', 'high', 'max'])
const OPENAI_EFFORT = new Set(['low', 'medium', 'high', 'xhigh'])
const OPENAI_INCLUDE = new Set(['reasoning.encrypted_content'])
/** Upper bound for one image after the provider downsizes it. */
const IMAGE_TOKENS = 3000

export interface Prepared {
  body: Record<string, unknown>; model: ModelRow; effort: string | null
  estimatedInput: number; requestedOutput: number
}

export function prepare(provider: Provider, input: unknown, models: ModelRow[], maxOutput: number): Prepared {
  if (!isObject(input)) throw new ProxyError('INVALID_REQUEST', 400)
  const raw = input
  const allowed = provider === 'anthropic' ? ANTHROPIC_KEYS : OPENAI_KEYS
  const unknown = Object.keys(raw).find(key => !allowed.has(key))
  if (unknown) throw new ProxyError('INVALID_REQUEST', 400, { field: unknown })
  const model = models.find(row => row.id === raw.model && row.provider === provider && row.enabled)
  if (!model) throw new ProxyError('MODEL_UNAVAILABLE', 404)
  checkTools(provider, raw.tools)

  const body: Record<string, unknown> = { ...raw, stream: true }
  let effort: string | null = null
  const requestedField = provider === 'anthropic' ? raw.max_tokens : raw.max_output_tokens
  const requestedOutput = Math.min(typeof requestedField === 'number' && requestedField >= 1 ? Math.floor(requestedField) : maxOutput, maxOutput)
  if (provider === 'anthropic') {
    if (!Array.isArray(raw.messages)) throw new ProxyError('INVALID_REQUEST', 400, { field: 'messages' })
    if (raw.output_config !== undefined) effort = onlyEffort(raw.output_config, ANTHROPIC_EFFORT, 'output_config')
    body.cache_control = { type: 'ephemeral' }
  } else {
    if (!Array.isArray(raw.input)) throw new ProxyError('INVALID_REQUEST', 400, { field: 'input' })
    if (raw.include !== undefined && (!Array.isArray(raw.include) || raw.include.some(item => !OPENAI_INCLUDE.has(String(item))))) {
      throw new ProxyError('INVALID_REQUEST', 400, { field: 'include' })
    }
    if (raw.reasoning !== undefined) effort = onlyEffort(raw.reasoning, OPENAI_EFFORT, 'reasoning')
    body.store = false
  }
  const estimatedInput = estimateTokens(raw)
  if (estimatedInput > model.context_cap) throw new ProxyError('CONTEXT_TOO_LARGE', 413, { limit: model.context_cap, estimate: estimatedInput })
  return { body, model, effort, estimatedInput, requestedOutput }
}

export function withOutputLimit(provider: Provider, body: Record<string, unknown>, limit: number): Record<string, unknown> {
  return provider === 'anthropic' ? { ...body, max_tokens: limit } : { ...body, max_output_tokens: limit }
}

function checkTools(provider: Provider, tools: unknown) {
  if (tools === undefined) return
  if (!Array.isArray(tools) || tools.length > 160) throw new ProxyError('INVALID_REQUEST', 400, { field: 'tools' })
  for (const tool of tools) {
    const ok = isObject(tool) && typeof tool.name === 'string' && (provider === 'anthropic'
      ? Object.keys(tool).every(key => ANTHROPIC_TOOL_KEYS.has(key)) && isObject(tool.input_schema)
      : tool.type === 'function' && Object.keys(tool).every(key => OPENAI_TOOL_KEYS.has(key)))
    if (!ok) throw new ProxyError('INVALID_REQUEST', 400, { field: 'tools' })
  }
}

function onlyEffort(value: unknown, allowed: Set<string>, field: string): string {
  if (!isObject(value) || Object.keys(value).some(key => key !== 'effort') || !allowed.has(String(value.effort))) {
    throw new ProxyError('INVALID_REQUEST', 400, { field })
  }
  return String(value.effort)
}

/**
 * Rough input size: UTF-8 bytes / 3 of every string (Korean ≈ 1 token per character,
 * English overestimates by about a third). An inline image counts as IMAGE_TOKENS
 * instead of its base64 length; anything else counts by its size.
 */
export function estimateTokens(value: unknown): number {
  let bytes = 0, images = 0
  const walk = (node: unknown, parent: Record<string, unknown> | null, key: string) => {
    if (typeof node === 'string') {
      const anthropicImage = key === 'data' && parent?.type === 'base64' && String(parent.media_type ?? '').startsWith('image/')
      const openaiImage = key === 'image_url' && node.startsWith('data:image/')
      if (anthropicImage || openaiImage) { images++; return }
      bytes += new TextEncoder().encode(node).length
    } else if (Array.isArray(node)) node.forEach(item => walk(item, parent, key))
    else if (isObject(node)) for (const [k, v] of Object.entries(node)) walk(v, node, k)
  }
  walk(value, null, '')
  return Math.ceil(bytes / 3) + images * IMAGE_TOKENS
}

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value)
}
