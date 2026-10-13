import { access, stat } from 'node:fs/promises'
import { constants } from 'node:fs'

/** Course metadata must never synchronously touch a disconnected drive. */
export function createFolderAvailability(onChange: () => void): (folder: string) => boolean {
  const cache = new Map<string, { missing: boolean; checkedAt: number }>()
  const pending = new Set<string>()
  return folder => {
    const previous = cache.get(folder)
    if (!pending.has(folder) && (!previous || Date.now() - previous.checkedAt > 5000)) {
      pending.add(folder)
      void (async () => {
        let missing = true
        try { missing = !(await stat(folder)).isDirectory(); if (!missing) await access(folder, constants.R_OK | constants.X_OK) }
        catch { missing = true }
        cache.set(folder, { missing, checkedAt: Date.now() })
        pending.delete(folder)
        if (missing !== (previous?.missing ?? false)) onChange()
      })()
    }
    return previous?.missing ?? false
  }
}
