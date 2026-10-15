type Timer = ReturnType<typeof setTimeout>
type WatchRequest = { courseId: string; rendererSessionId?: string; subscriptionId?: string }
interface Entry { courseId: string; leases: Set<string>; timer?: Timer; flight?: Promise<void>; signature?: string; delayIndex: number; wakeRevision: number }
interface Dependencies {
  tree(courseId: string): Promise<unknown>
  invalidate(courseId: string): void
  changed(courseId: string): void
  failed(error: unknown): void
  schedule?: (callback: () => void, delay: number) => Timer
  cancel?: (timer: Timer) => void
}

/** Each renderer lease is registered before scanning can yield. Old scans may
 * finish, but cannot publish or recreate timers after their owner has gone. */
export function createMaterialWatchers(deps: Dependencies) {
  const entries = new Map<string, Entry>()
  const schedule = deps.schedule ?? setTimeout, cancel = deps.cancel ?? clearTimeout
  const delays = [2500, 5000, 10_000, 30_000]
  let active = true, session: string | undefined
  const lease = (request: WatchRequest) => `${request.rendererSessionId ?? 'legacy'}\0${request.subscriptionId ?? 'default'}`
  const current = (entry: Entry) => entries.get(entry.courseId) === entry && entry.leases.size > 0
  // Keep watch() rejections intact; only background notices need an owner check.
  function reportFailure(entry: Entry, error: unknown) { if (current(entry)) deps.failed(error) }
  function clearTimer(entry: Entry) { if (entry.timer !== undefined) { cancel(entry.timer); delete entry.timer } }
  function remove(entry: Entry) { clearTimer(entry); entry.leases.clear(); entries.delete(entry.courseId) }
  function next(entry: Entry) {
    if (!active || !current(entry) || entry.timer !== undefined) return
    entry.timer = schedule(() => { delete entry.timer; void scan(entry, true).catch(error => reportFailure(entry, error)) }, delays[entry.delayIndex]!)
  }
  function resetDelay(entry: Entry) { entry.delayIndex = 0; entry.wakeRevision++ }
  function scan(entry: Entry, invalidate: boolean, foreground = false): Promise<void> {
    if (entry.flight) return entry.flight
    if (!active || !current(entry)) return Promise.resolve()
    const revision = entry.wakeRevision
    const task = (async () => {
      if (invalidate) deps.invalidate(entry.courseId)
      const signature = JSON.stringify(await deps.tree(entry.courseId))
      if (!current(entry) || !active) return
      const changed = entry.signature !== undefined && entry.signature !== signature
      const initial = entry.signature === undefined
      entry.signature = signature
      if (changed || initial || foreground) entry.delayIndex = 0
      else if (entry.wakeRevision === revision) entry.delayIndex = Math.min(entry.delayIndex + 1, delays.length - 1)
      if (changed) deps.changed(entry.courseId)
    })().catch(error => {
      if (current(entry) && entry.wakeRevision === revision) entry.delayIndex = Math.min(entry.delayIndex + 1, delays.length - 1)
      throw error
    })
    entry.flight = task.finally(() => { delete entry.flight; next(entry) })
    return entry.flight
  }
  return {
    async watch(request: WatchRequest) {
      if (session !== undefined && request.rendererSessionId !== session) throw Object.assign(new Error('이전 화면의 자료 감시 요청입니다.'), { code: 'STALE_RENDERER_SESSION' })
      let entry = entries.get(request.courseId)
      if (!entry) { entry = { courseId: request.courseId, leases: new Set(), delayIndex: 0, wakeRevision: 0 }; entries.set(request.courseId, entry) }
      entry.leases.add(lease(request))
      if (entry.flight) await entry.flight
      else if (entry.signature === undefined) await scan(entry, false)
    },
    unwatch(request?: Partial<WatchRequest>) {
      for (const entry of entries.values()) {
        if (request?.courseId && request.courseId !== entry.courseId) continue
        if (!request?.courseId) {
          if (request?.rendererSessionId) for (const key of entry.leases) { if (key.startsWith(request.rendererSessionId + '\0')) entry.leases.delete(key) }
          else entry.leases.clear()
        } else entry.leases.delete(lease(request as WatchRequest))
        if (!entry.leases.size) remove(entry)
      }
    },
    setSession(value: string) {
      if (session === value) return
      for (const entry of entries.values()) remove(entry)
      session = value
    },
    setActive(value: boolean) {
      if (active === value) return
      active = value
      for (const entry of entries.values()) {
        clearTimer(entry)
        resetDelay(entry)
        if (active) void scan(entry, true, true).catch(error => reportFailure(entry, error))
      }
    },
    /** Mutations already emit immediately; resume fast external-change checks
     * without doing a second full tree read for the same mutation. */
    mutated(courseId: string) {
      const entry = entries.get(courseId)
      if (!entry) return
      clearTimer(entry); resetDelay(entry)
      if (!entry.flight) next(entry)
    },
    reset() { for (const entry of entries.values()) remove(entry); session = undefined },
    inspect() { return { courses: entries.size, leases: [...entries.values()].reduce((sum, entry) => sum + entry.leases.size, 0), timers: [...entries.values()].filter(entry => entry.timer !== undefined).length } }
  }
}
