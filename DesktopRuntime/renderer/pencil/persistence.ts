type Flush = () => Promise<void>
export interface InkOwner { key: string; courseId: string; relPath: string }
interface Entry { owner: InkOwner; flush: Flush; retired: boolean }
export interface InkFlushReport {
  ok: boolean
  pending: Array<InkOwner & { status: string; error?: string }>
}

/** Owns references to the original queues, including a tab which unmounted
 * while its last write was waiting for IPC. The adapter never writes ink. */
export function createInkFlushRegistry() {
  const entries = new Set<Entry>()
  let revision = 0
  const changed = (): void => { revision++ }
  const register = (owner: InkOwner, flush: Flush): (() => void) => {
    const entry: Entry = { owner, flush, retired: false }
    entries.add(entry); changed()
    return () => {
      entry.retired = true
      // Failed saves stay registered so process release/sync cannot silently
      // treat the closed editor as saved. Original queues remain retry owners.
      void entry.flush().then(() => {
        if (entries.delete(entry)) changed()
      }, () => undefined)
    }
  }
  const flush = async (): Promise<InkFlushReport> => {
    for (let attempt = 0; attempt < 8; attempt++) {
      const before = revision
      const pending: InkFlushReport['pending'] = []
      await Promise.all([...entries].map(async entry => {
        try {
          await entry.flush()
          if (entry.retired && entries.delete(entry)) changed()
        } catch (error) {
          pending.push({ ...entry.owner, status: 'error', error: error instanceof Error ? error.message : String(error) })
        }
      }))
      if (pending.length) return { ok: false, pending }
      // A second editor may enqueue after its own flush resolved while we
      // awaited another editor. Require a globally stable revision as well.
      if (before === revision) return { ok: true, pending: [] }
    }
    return { ok: false, pending: [...entries].map(entry => ({ ...entry.owner, status: 'editing' })) }
  }
  return { register, changed, flush, revision: () => revision }
}

const registry = createInkFlushRegistry()
export const registerNativeInk = registry.register
export const markNativeInkDirty = registry.changed
export const flushNativeInk = registry.flush
export const nativeInkRevision = registry.revision

declare global {
  interface Window { __bandalFlushNativeInk?: () => Promise<InkFlushReport> }
}
if (typeof window !== 'undefined') window.__bandalFlushNativeInk = flushNativeInk
