/** Two foreground reads at a time. New selections precede queued old tabs;
 * an unmounted/hidden tab removes its request before it starts reading. */
const queue: { start: () => void; signal: AbortSignal }[] = []
let running = 0
function pump(): void {
  while (running < 2 && queue.length) {
    const job = queue.pop()!
    if (job.signal.aborted) continue
    running += 1
    job.start()
  }
}
export function readVisibleDocument<T>(read: () => Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    let started = false
    const abort = (): void => {
      if (!started) { const index = queue.indexOf(job); if (index >= 0) queue.splice(index, 1) }
      reject(new DOMException('Document no longer visible', 'AbortError'))
    }
    const job = { signal, start: (): void => {
      started = true
      void read().then(resolve, reject).finally(() => {
        signal.removeEventListener('abort', abort)
        running -= 1
        pump()
      })
    } }
    if (signal.aborted) { abort(); return }
    signal.addEventListener('abort', abort, { once: true })
    queue.push(job)
    pump()
  })
}
