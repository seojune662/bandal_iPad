/** Opt-in, bounded diagnostics: counts/durations only, never paths or content. */
type Metrics = Record<string, { count: number; totalMs: number; maxMs: number }>
interface Trace { startedAt: number; marks: Record<string, number>; ipc: Metrics; work: Metrics }
const trace: Trace | null = process.env['BANDAL_PERF_TRACE'] === '1'
  ? { startedAt: performance.now(), marks: {}, ipc: {}, work: {} } : null
if (trace) (globalThis as typeof globalThis & { __bandalPerformance?: Trace }).__bandalPerformance = trace
export function markStartup(name: string): void { if (trace) trace.marks[name] = performance.now() - trace.startedAt }
export function traceIpc(channel: string, duration: number): void {
  if (!trace) return
  record(trace.ipc, channel, duration)
}
function record(metrics: Metrics, name: string, duration: number): void {
  const metric = metrics[name] ??= { count: 0, totalMs: 0, maxMs: 0 }
  metric.count += 1
  metric.totalMs += duration
  metric.maxMs = Math.max(metric.maxMs, duration)
}
export function traceSyncWork<T>(name: string, work: () => T): T {
  if (!trace) return work()
  const start = performance.now()
  try { return work() } finally { record(trace.work, name, performance.now() - start) }
}
