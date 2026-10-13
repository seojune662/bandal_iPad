import type { BrowserWindow, MessageBoxOptions, MessageBoxReturnValue } from 'electron'

/** Study approvals must remain asynchronous on macOS and expire with their owner. */
export function createLearningApprovalDialogs(deps: {
  getOwner: () => BrowserWindow | null
  show: (owner: BrowserWindow, options: MessageBoxOptions) => Promise<MessageBoxReturnValue>
}) {
  const pending = new Map<string, { controller: AbortController; promise: Promise<MessageBoxReturnValue | null> }>()
  let disposed = false
  const live = (owner: BrowserWindow): boolean => !owner.isDestroyed() && !owner.webContents.isDestroyed() && owner.isVisible()
  return {
    request(id: string, options: MessageBoxOptions): Promise<MessageBoxReturnValue | null> {
      const existing = pending.get(id)
      if (existing) return existing.promise
      const owner = deps.getOwner()
      if (disposed || !owner || !live(owner)) return Promise.resolve(null)
      const controller = new AbortController()
      const closed = (): void => controller.abort()
      const item = { controller, promise: Promise.resolve<MessageBoxReturnValue | null>(null) }
      pending.set(id, item)
      owner.once('closed', closed)
      const cleanup = (): void => {
        owner.removeListener('closed', closed)
        if (pending.get(id) === item) pending.delete(id)
      }
      try {
        item.promise = deps.show(owner, { ...options, signal: controller.signal })
          .then(answer => !controller.signal.aborted && live(owner) ? answer : null)
          .catch(() => null)
          .finally(cleanup)
      } catch {
        cleanup()
      }
      return item.promise
    },
    cancel(id: string): void { pending.get(id)?.controller.abort() },
    dispose(): void {
      disposed = true
      for (const item of pending.values()) item.controller.abort()
    }
  }
}
