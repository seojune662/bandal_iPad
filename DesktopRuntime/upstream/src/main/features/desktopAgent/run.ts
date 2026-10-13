export type DesktopRunStatus = 'idle' | 'capturing' | 'reading'

export function createDesktopRunRegistry(deps: {
  emit(payload: {
    conversationId: string
    status: DesktopRunStatus
    action: string | null
  }): void
}): {
  set(
    conversationId: string,
    status: DesktopRunStatus,
    action?: string | null
  ): void
  clear(conversationId: string): void
} {
  const runs = new Map<
    string,
    { conversationId: string; status: DesktopRunStatus; action: string | null }
  >()

  return {
    set(conversationId, status, action = null) {
      const payload = { conversationId, status, action }
      runs.set(conversationId, payload)
      deps.emit(payload)
    },

    clear(conversationId) {
      runs.delete(conversationId)
      deps.emit({ conversationId, status: 'idle', action: null })
    }
  }
}
