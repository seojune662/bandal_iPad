interface WorkspaceSaveQueue {
  capture(): void
  flush(): void
  status(): { pending: boolean; failed: boolean }
}

let queue: WorkspaceSaveQueue | undefined

/** The original workspace store remains the only layout writer and retry queue. */
export function registerIPadWorkspaceSaveQueue(value: WorkspaceSaveQueue): void {
  queue = value
}

/** iPad can suspend without beforeunload. The host's existing background and
 * reload barrier must also wait for the current tab/layout's canonical ACK. */
export async function flushIPadWorkspaceLayout(): Promise<boolean> {
  if (!queue) return true // No workspace has mounted (for example startup recovery).
  const current = queue
  current.capture()
  current.flush()
  const deadline = performance.now() + 10_000
  for (;;) {
    const status = current.status()
    if (status.failed) return false
    if (!status.pending) return true
    if (performance.now() >= deadline) return false
    // Observe the original writer, including a newer snapshot queued while an
    // older one awaits IPC. Never write a second copy or remove failed saves.
    await new Promise<void>(resolve => setTimeout(resolve, 16))
  }
}
