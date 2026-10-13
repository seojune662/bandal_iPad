export const PACK_RUN_GUARD_TTL_MS = 15 * 60 * 1000

interface ArmedPackRun {
  packId: string
  allowed: ReadonlySet<string>
  expiresAt: number
  timer: ReturnType<typeof setTimeout>
}

export interface PackRunGuard {
  arm(
    courseId: string,
    restriction: { packId: string; allowed: ReadonlySet<string> }
  ): void
  clear(courseId: string): void
  restrictionFor(courseId: string): ReadonlySet<string> | null
}

export interface PackRunGuardDeps {
  now?: () => number
  ttlMs?: number
}

/**
 * Holds the declared tool boundary only while a workflow-pack turn is alive.
 * The timer is a backstop for a provider promise that never settles.
 */
export function createPackRunGuard(
  deps: PackRunGuardDeps = {}
): PackRunGuard {
  const now = deps.now ?? Date.now
  const configuredTtl = deps.ttlMs ?? PACK_RUN_GUARD_TTL_MS
  const ttlMs =
    Number.isFinite(configuredTtl) && configuredTtl >= 0
      ? configuredTtl
      : PACK_RUN_GUARD_TTL_MS
  const armed = new Map<string, ArmedPackRun>()

  function clear(courseId: string): void {
    const current = armed.get(courseId)
    if (current === undefined) return
    clearTimeout(current.timer)
    armed.delete(courseId)
  }

  return {
    arm(courseId, restriction) {
      clear(courseId)
      const expiresAt = now() + ttlMs
      // Copy at the boundary: callers cannot widen an active run by mutating
      // the Set they passed after arm().
      const allowed = new Set(restriction.allowed)
      const timer = setTimeout(() => {
        const current = armed.get(courseId)
        if (
          current?.packId === restriction.packId &&
          current.expiresAt === expiresAt
        ) {
          armed.delete(courseId)
        }
      }, ttlMs)
      timer.unref?.()
      armed.set(courseId, {
        packId: restriction.packId,
        allowed,
        expiresAt,
        timer
      })
    },

    clear,

    restrictionFor(courseId) {
      const current = armed.get(courseId)
      if (current === undefined) return null
      if (now() >= current.expiresAt) {
        clear(courseId)
        return null
      }
      return current.allowed
    }
  }
}
