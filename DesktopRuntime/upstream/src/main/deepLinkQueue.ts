/**
 * A one-slot handler with a replay buffer for `bandal://` deep links.
 *
 * WHY THIS EXISTS: on macOS a cold start from a deep link delivers `open-url`
 * *during* app startup — before `whenReady()` resolves, before the DB is open,
 * before any window exists. The listener therefore has to be registered at
 * module scope, but the thing that can act on the URL (the IPC router, which
 * owns the group runtime) does not exist yet. Dropping the URL there is the
 * classic "OAuth works on the second try only" bug: the browser hands the code
 * back, nothing happens, the user clicks 로그인 again.
 *
 * So: `push()` before `attach()` buffers, `attach()` drains in arrival order,
 * and every later `push()` goes straight through.
 *
 * Pure and Electron-free so the ordering can actually be tested.
 */

export interface DeepLinkQueue {
  /** Called from `open-url` / `second-instance` / argv scan. Never throws. */
  push(url: string): void
  /** Installs the handler and replays anything buffered, oldest first. */
  attach(handler: (url: string) => void): void
  /** Buffered-but-undelivered URLs. Test/diagnostics only. */
  pending(): readonly string[]
}

/**
 * A deep link is a user gesture, so the buffer only ever holds a handful.
 * The cap exists so a misbehaving caller cannot grow it without bound.
 */
export const DEEP_LINK_BUFFER_LIMIT = 8

export function createDeepLinkQueue(): DeepLinkQueue {
  let handler: ((url: string) => void) | null = null
  let buffered: readonly string[] = []

  function deliver(url: string): void {
    if (handler === null) return
    try {
      handler(url)
    } catch (error) {
      // A throwing handler must not poison the queue: the next deep link
      // (a retried sign-in, usually) still has to get through.
      console.error('[deeplink] handler failed', error)
    }
  }

  return {
    push(url) {
      if (typeof url !== 'string' || url.length === 0) return
      if (handler !== null) {
        deliver(url)
        return
      }
      // Oldest out first: the newest callback is the one the user is waiting on.
      const next = [...buffered, url]
      buffered = next.slice(Math.max(0, next.length - DEEP_LINK_BUFFER_LIMIT))
    },

    attach(next) {
      handler = next
      const replay = buffered
      buffered = []
      for (const url of replay) deliver(url)
    },

    pending: () => buffered
  }
}
