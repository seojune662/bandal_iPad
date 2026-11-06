// Reads token usage out of a provider's SSE stream while the bytes pass through untouched.
export type Provider = 'anthropic' | 'openai'
export interface Usage { input: number; output: number; cacheRead: number; cacheWrite: number }

export class UsageMeter {
  private buffer = ''
  private generatedBytes = 0
  private inputSeen = false
  /** The provider reported its final usage (even for a step it cut short). */
  exact = false
  /** The provider finished the step normally. */
  completed = false
  /** The provider stopped at the output limit (OpenAI `response.incomplete`); still a delivered answer. */
  truncated = false
  /** Something reached the user: text, thinking, or a tool call. */
  content = false
  usage: Usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
  constructor(readonly provider: Provider) {}

  feed(chunk: string) {
    this.buffer += chunk
    let newline: number
    while ((newline = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newline).trim()
      this.buffer = this.buffer.slice(newline + 1)
      if (line.startsWith('data:')) this.line(line.slice(5).trim())
    }
  }

  /** A step the model itself broke (error event, `response.failed`, cut-off stream, timeout) or that
   *  produced nothing is not the user's to pay for. A client leaving does not count: upstream is read to the end. */
  get billable(): boolean { return (this.completed || this.truncated) && this.content }

  /** Usage to charge: exact when the provider reported it, otherwise estimated from what streamed. */
  charge(estimatedInput: number): Usage {
    if (this.exact) return this.usage
    return {
      input: this.inputSeen ? this.usage.input : estimatedInput,
      output: Math.max(this.usage.output, Math.ceil(this.generatedBytes / 3)),
      cacheRead: this.usage.cacheRead, cacheWrite: this.usage.cacheWrite,
    }
  }

  private generated(count: number) {
    this.generatedBytes += count
    if (count > 0) this.content = true
  }

  private line(data: string) {
    if (!data || data === '[DONE]') return
    let event: Record<string, unknown>
    try { event = JSON.parse(data) } catch { return }
    if (this.provider === 'anthropic') this.anthropic(event)
    else this.openai(event)
  }

  private anthropic(event: Record<string, unknown>) {
    const type = event.type
    if (type === 'message_start') {
      this.inputSeen = true
      this.applyAnthropic(record(record(event.message).usage))
    } else if (type === 'content_block_start') {
      if (record(event.content_block).type === 'tool_use') this.content = true
    } else if (type === 'content_block_delta') {
      const delta = record(event.delta)
      this.generated(bytes(delta.text) + bytes(delta.partial_json) + bytes(delta.thinking))
    } else if (type === 'message_delta') {
      // Cumulative: carries the final output and, after server-side work, updated input counts.
      this.applyAnthropic(record(event.usage))
      this.exact = true
    } else if (type === 'message_stop') {
      this.completed = true
      this.exact = true
    }
  }

  private applyAnthropic(usage: Record<string, unknown>) {
    if (usage.input_tokens !== undefined) this.usage.input = int(usage.input_tokens)
    if (usage.cache_read_input_tokens !== undefined) this.usage.cacheRead = int(usage.cache_read_input_tokens)
    if (usage.cache_creation_input_tokens !== undefined) this.usage.cacheWrite = int(usage.cache_creation_input_tokens)
    if (usage.output_tokens !== undefined) this.usage.output = int(usage.output_tokens)
  }

  private openai(event: Record<string, unknown>) {
    const type = String(event.type ?? '')
    if (type.endsWith('.delta')) {
      this.generated(bytes(event.delta))
    } else if (type === 'response.output_item.added') {
      if (record(event.item).type === 'function_call') this.content = true
    } else if (type === 'response.completed' || type === 'response.incomplete' || type === 'response.failed') {
      const usage = record(record(event.response).usage)
      if (Object.keys(usage).length > 0) {
        const cached = int(record(usage.input_tokens_details).cached_tokens)
        this.inputSeen = true
        this.usage = { input: Math.max(int(usage.input_tokens) - cached, 0), output: int(usage.output_tokens), cacheRead: cached, cacheWrite: 0 }
        this.exact = true
      }
      if (type === 'response.completed') this.completed = true
      if (type === 'response.incomplete') this.truncated = true
    }
  }
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}
function int(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0
}
function bytes(value: unknown): number {
  return typeof value === 'string' ? new TextEncoder().encode(value).length : 0
}
