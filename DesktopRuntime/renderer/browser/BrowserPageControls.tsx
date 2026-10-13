import { useState } from 'react'
import { Icon } from '../../upstream/src/renderer/src/app/icons'
import { showToast } from '../../upstream/src/renderer/src/app/toast'
import { settingsSnapshot } from '../../upstream/src/renderer/src/stores/settingsSnapshot'
import { useBrowserGuests } from '../../upstream/src/renderer/src/features/browser/browserGuestsStore'
import { zoomIn, zoomOut, zoomPercent } from '../../upstream/src/renderer/src/features/browser/zoom'
import { usePrintStore } from '../../upstream/src/renderer/src/features/print/printStore'
import { browserRequest } from './BrowserSiteControls'

/** Touch equivalents of the original keyboard/context-menu page actions. */
export function BrowserPageControls({ tabId, title }: { tabId: string; title: string }): JSX.Element {
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
    <button type="button" className="browser-nav-button" aria-label="페이지 공유" onClick={() => {
      void browserRequest('browser:sharePage', { tabId }).catch(() => showToast('공유 창을 열지 못했어요. 다른 창을 닫고 다시 시도해 주세요.', 'danger'))
    }}><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.75" aria-hidden="true"><path d="M12 15V3m-4 4 4-4 4 4M7 10H4v11h16V10h-3" /></svg></button>
    <button type="button" className="browser-nav-button" aria-label="페이지 인쇄 또는 PDF 저장" onClick={() => usePrintStore.getState().open({ kind: 'browser', tabId }, title)}><svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.75" aria-hidden="true"><path d="M7 8V3h10v5M7 17H3V9h18v8h-4M7 14h10v7H7Z" /></svg></button>
  </>
}
