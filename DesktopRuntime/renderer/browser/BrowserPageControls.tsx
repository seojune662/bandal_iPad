import { useState } from 'react'
import { Icon } from '../../upstream/src/renderer/src/app/icons'
import { showToast } from '../../upstream/src/renderer/src/app/toast'
import { settingsSnapshot } from '../../upstream/src/renderer/src/stores/settingsSnapshot'
import { useBrowserGuests } from '../../upstream/src/renderer/src/features/browser/browserGuestsStore'
import { zoomIn, zoomOut, zoomPercent } from '../../upstream/src/renderer/src/features/browser/zoom'
import { browserRequest } from './BrowserSiteControls'

/** Touch equivalents of the original keyboard/context-menu page actions. */
export function BrowserPageControls({ tabId }: { tabId: string }): JSX.Element {
  const base = settingsSnapshot().browser.defaultZoomLevel
  const level = useBrowserGuests(state => state.zoom[tabId] ?? base)
  const [busy, setBusy] = useState(false)
  const zoom = (next: number): void => {
    setBusy(true)
    void browserRequest('browser:pageAction', { tabId, action: 'setZoomLevel', args: [next] }).then(() =>
      useBrowserGuests.getState().setZoom(tabId, next)).catch(() => showToast('페이지 크기를 바꾸지 못했어요.', 'danger')).finally(() => setBusy(false))
  }
  return <>
    <div className="ipad-browser-zoom" data-keep-browser-menu role="group" aria-label="페이지 크기">
      <button type="button" aria-label="페이지 축소" disabled={busy || zoomOut(level) === level} onClick={() => zoom(zoomOut(level))}>A<span aria-hidden="true">−</span></button>
      <button type="button" aria-label={`기본 페이지 크기로 (${zoomPercent(level)}%)`} disabled={busy} onClick={() => zoom(base)}>{zoomPercent(level)}%</button>
      <button type="button" aria-label="페이지 확대" disabled={busy || zoomIn(level) === level} onClick={() => zoom(zoomIn(level))}>A<span aria-hidden="true">+</span></button>
    </div>
    <button type="button" className="browser-nav-button" aria-label="페이지에서 찾기" onClick={() => useBrowserGuests.getState().openFind(tabId)}><Icon name="search" /></button>
  </>
}
