import type { DockviewApi } from 'dockview'

/** Native page input does not bubble through the workspace's DOM focus handler. */
export function focusVisibleBrowserPanel(api: DockviewApi | null, tabId: string): boolean {
  const panel = api?.panels.find(candidate => {
    const descriptor = candidate.params?.descriptor
    return descriptor?.kind === 'browser' && descriptor.payload?.tabId === tabId && candidate.api.isVisible
  })
  if (!panel) return false
  if (!panel.api.isActive) panel.api.setActive()
  return true
}

/** Navigation and newer icon events invalidate older asynchronous icon requests. */
export function createTabFaviconController(
  fetchIcon: (url: string) => Promise<string | null>,
  publish: (dataUrl: string | null) => void
): { navigation(): void; update(url: string | undefined): void; dispose(): void } {
  let revision = 0, disposed = false
  return {
    navigation() { revision++; publish(null) },
    update(url) {
      const request = ++revision
      if (!url) { publish(null); return }
      void fetchIcon(url).then(data => {
        if (!disposed && request === revision) publish(data)
      }).catch(() => {
        if (!disposed && request === revision) publish(null)
      })
    },
    dispose() { disposed = true; revision++ }
  }
}
