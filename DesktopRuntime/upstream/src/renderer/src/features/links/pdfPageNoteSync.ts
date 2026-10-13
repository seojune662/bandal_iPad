import { useCallback, useEffect, useState } from 'react'

export interface PageSyncAnchor {
  connectionId: string
  pairId: string
  page: number
  pageOffset: number
  originPanelId: string
  sequence: number
}

const ANCHOR_EVENT = 'bandal:pdf-page-note-anchor'
const SETTING_EVENT = 'bandal:pdf-page-note-sync-setting'
const settings = new Map<string, boolean>()
const pendingAnchors = new Map<
  string,
  Omit<PageSyncAnchor, 'sequence'>
>()
let anchorFrame: number | null = null
let sequence = 0

/** A new gesture in the other pane supersedes a position queued last frame. */
export function claimPageSyncInput(pairId: string, panelId: string): void {
  const pending = pendingAnchors.get(pairId)
  if (pending && pending.originPanelId !== panelId) pendingAnchors.delete(pairId)
}

export function publishPageSyncAnchor(
  anchor: Omit<PageSyncAnchor, 'sequence'>
): void {
  if (settings.get(anchor.pairId) === false) return
  // Both panes publish from scroll handlers. Keep only the latest semantic
  // position for a pair in this frame so a trackpad burst never builds an
  // event backlog behind the user's finger.
  pendingAnchors.set(anchor.pairId, anchor)
  if (anchorFrame !== null) return
  anchorFrame = window.requestAnimationFrame(() => {
    anchorFrame = null
    const queued = [...pendingAnchors.values()]
    pendingAnchors.clear()
    for (const pending of queued) {
      if (settings.get(pending.pairId) === false) continue
      window.dispatchEvent(
        new CustomEvent<PageSyncAnchor>(ANCHOR_EVENT, {
          detail: { ...pending, sequence: ++sequence }
        })
      )
    }
  })
}

export function subscribePageSyncAnchor(
  pairId: string,
  listener: (anchor: PageSyncAnchor) => void
): () => void {
  const handle = (event: Event): void => {
    if (!(event instanceof CustomEvent)) return
    const detail = event.detail as PageSyncAnchor
    if (detail.pairId === pairId) listener(detail)
  }
  window.addEventListener(ANCHOR_EVENT, handle)
  return () => window.removeEventListener(ANCHOR_EVENT, handle)
}

export function setPageNoteSyncEnabled(pairId: string, enabled: boolean): void {
  // Both panes refresh persisted metadata asynchronously. Reapplying `true`
  // must not erase a user's scroll queued for the next animation frame.
  if (!enabled) pendingAnchors.delete(pairId)
  settings.set(pairId, enabled)
  window.dispatchEvent(
    new CustomEvent(SETTING_EVENT, { detail: { pairId, enabled } })
  )
}

export function pageNoteSyncEnabled(
  pairId: string,
  defaultEnabled = true
): boolean {
  return settings.get(pairId) ?? defaultEnabled
}

export function usePageNoteSync(
  pairId: string | null,
  defaultEnabled = true
): [boolean, (enabled: boolean) => void] {
  const [enabled, setEnabled] = useState(() =>
    pairId === null ? false : pageNoteSyncEnabled(pairId, defaultEnabled)
  )

  useEffect(() => {
    if (pairId === null) {
      setEnabled(false)
      return
    }
    if (!settings.has(pairId)) settings.set(pairId, defaultEnabled)
    setEnabled(pageNoteSyncEnabled(pairId, defaultEnabled))
    const handle = (event: Event): void => {
      if (!(event instanceof CustomEvent)) return
      const detail = event.detail as { pairId?: unknown; enabled?: unknown }
      if (detail.pairId === pairId && typeof detail.enabled === 'boolean') {
        setEnabled(detail.enabled)
      }
    }
    window.addEventListener(SETTING_EVENT, handle)
    return () => window.removeEventListener(SETTING_EVENT, handle)
  }, [defaultEnabled, pairId])

  const update = useCallback(
    (next: boolean): void => {
      if (pairId !== null) setPageNoteSyncEnabled(pairId, next)
    },
    [pairId]
  )
  return [enabled, update]
}
