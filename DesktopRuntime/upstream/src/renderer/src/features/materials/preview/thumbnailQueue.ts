/** PDF workers and video decoders share two slots across the hover card and clips. */
const MAX_ACTIVE_THUMBNAILS = 2
let active = 0
const waiting: Array<() => void> = []

function drain(): void {
  while (active < MAX_ACTIVE_THUMBNAILS && waiting.length > 0) waiting.shift()?.()
}

/**
 * Each caller owns its cancellation. Queued jobs are removed immediately; a
 * running slot is held until its decoder/worker has actually finished cleanup.
 */
export function runThumbnailTask<T>(signal: AbortSignal, task: () => Promise<T>): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason)
  return new Promise<T>((resolve, reject) => {
    let started = false
    const abort = (): void => {
      if (!started) {
        const index = waiting.indexOf(start)
        if (index >= 0) waiting.splice(index, 1)
        signal.removeEventListener('abort', abort)
      }
      reject(signal.reason)
    }
    const finish = (): void => {
      signal.removeEventListener('abort', abort)
      active -= 1
      drain()
    }
    const start = (): void => {
      if (signal.aborted) { abort(); return }
      started = true
      active += 1
      let pending: Promise<T>
      try { pending = task() } catch (error) { finish(); reject(error); return }
      void pending.then((value) => { finish(); resolve(value) }, (error) => { finish(); reject(error) })
    }
    signal.addEventListener('abort', abort, { once: true })
    waiting.push(start)
    drain()
  })
}
