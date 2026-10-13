import type { Database } from 'better-sqlite3'

/** Move occasional WAL checkpoint disk work off the UI process without
 * changing transaction durability. PASSIVE checkpoints never wait on writers. */
export function startBackgroundCheckpoints(db: Database, checkpoint: () => Promise<unknown>, onError: (error: unknown) => void) {
  const previous = db.pragma('wal_autocheckpoint', { simple: true }) as number
  db.pragma('wal_autocheckpoint = 0')
  let stopped = false
  let pending = false
  let last = -Infinity
  const request = (): void => {
    if (stopped || pending || Date.now() - last < 5000) return
    pending = true
    last = Date.now()
    void Promise.resolve().then(checkpoint).catch(onError).finally(() => { pending = false })
  }
  const timer = setInterval(request, 15_000)
  timer.unref?.()
  return {
    request,
    dispose(): void {
      stopped = true
      clearInterval(timer)
      if (db.open) db.pragma(`wal_autocheckpoint = ${previous}`)
    }
  }
}
