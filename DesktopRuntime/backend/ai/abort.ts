// JavaScriptCore has no DOM AbortController; this adapter covers the standard
// one-shot cancellation API used by the unchanged desktop learning runtime.
const host = globalThis as any
if (!host.AbortController) {
  class Signal {
    aborted = false; reason: unknown
    private listeners = new Map<Function, boolean>()
    addEventListener(type: string, listener: Function, options?: { once?: boolean }) { if (type === 'abort') this.listeners.set(listener, options?.once === true) }
    removeEventListener(type: string, listener: Function) { if (type === 'abort') this.listeners.delete(listener) }
    throwIfAborted() { if (this.aborted) throw this.reason }
    abort(reason?: unknown) {
      if (this.aborted) return
      this.aborted = true; this.reason = reason ?? Object.assign(new Error('The operation was aborted'), { name: 'AbortError' })
      for (const [listener, once] of [...this.listeners]) { if (once) this.listeners.delete(listener); listener.call(this, { type: 'abort', target: this }) }
    }
  }
  host.AbortController = class { signal = new Signal(); abort(reason?: unknown) { this.signal.abort(reason) } }
}
