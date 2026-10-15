import { useEffect, useRef, useState } from 'react'
import { BrowserIcon } from '../../upstream/src/renderer/src/features/browser/browserIcons'
import { useBrowserGuests } from '../../upstream/src/renderer/src/features/browser/browserGuestsStore'
import { guestActions } from '../../upstream/src/renderer/src/features/browser/guestActions'
import type { BrowserCrashOverlay } from '../../upstream/src/renderer/src/features/browser/loadError'
import { recoveryCopy, retryBrowserPage, returnToBrowserForm, reloadBrowserPage, type RecoveryOverlay } from './recoverySupport'

function useRecoveryAction(overlay: object): { pending: boolean; failure: string; run: (action: () => Promise<void>) => Promise<void> } {
  const [pending, setPending] = useState(false)
  const [failure, setFailure] = useState('')
  const current = useRef(overlay)
  current.current = overlay
  useEffect(() => { setPending(false); setFailure('') }, [overlay])
  const run = async (action: () => Promise<void>): Promise<void> => {
    const target = overlay
    setPending(true); setFailure('')
    try { await action() } catch (error) {
      if (current.current === target) setFailure(error instanceof Error ? error.message : '요청을 시작하지 못했어요. 다시 시도해 주세요.')
    } finally { if (current.current === target) setPending(false) }
  }
  return { pending, failure, run }
}

export function BrowserErrorPage({ tabId, overlay }: { tabId: string; overlay: RecoveryOverlay }): JSX.Element {
  const { pending, failure, run } = useRecoveryAction(overlay)
  const canGoBack = useBrowserGuests(state => state.nav[tabId]?.canGoBack ?? false)
  const copy = recoveryCopy(overlay)
  const safeToRetry = !overlay.requestMethod || ['GET', 'HEAD'].includes(overlay.requestMethod.toUpperCase())
  return <div className="browser-error ipad-browser-recovery" role="alert">
    <BrowserIcon name="globe" />
    <h2 className="browser-error__title">{copy.title}</h2>
    <p className="browser-error__detail">{copy.detail}</p>
    {overlay.url && <p className="browser-error__url" dir="ltr">{overlay.url}</p>}
    {!safeToRetry && <p className="browser-error__detail">입력한 내용은 자동으로 다시 보내지 않아요. 원래 페이지로 돌아가 다시 제출해 주세요.</p>}
    <div className="browser-error__actions">
      {safeToRetry && overlay.retryable !== false && <button type="button" disabled={pending} className="browser-error__action browser-error__action--primary"
        onClick={() => void run(() => retryBrowserPage(tabId, overlay))}>{pending ? '연결 중…' : '다시 시도'}</button>}
      {!safeToRetry && overlay.canReturnToForm && overlay.navigationId !== undefined && <button type="button" disabled={pending} className="browser-error__action browser-error__action--primary"
        onClick={() => void run(() => returnToBrowserForm(tabId, overlay.navigationId!))}>원래 페이지로 돌아가기</button>}
      <button type="button" className="browser-error__action" onClick={() => useBrowserGuests.getState().requestAddressFocus(tabId)}>주소 수정</button>
      {canGoBack && <button type="button" className="browser-error__action" onClick={() => guestActions.back(tabId)}>뒤로</button>}
    </div>
    {failure && <p className="browser-error__detail" role="status">{failure}</p>}
    <details className="browser-error__diagnostics"><summary>오류 세부 정보</summary><code className="browser-error__code">{overlay.errorDescription} ({overlay.errorDomain ? `${overlay.errorDomain} · ` : ''}{overlay.errorCode})</code></details>
  </div>
}

export function BrowserCrashPage({ tabId, overlay }: { tabId: string; overlay: BrowserCrashOverlay }): JSX.Element {
  const { pending, failure, run } = useRecoveryAction(overlay)
  return <div className="browser-error ipad-browser-recovery" role="alert">
    <BrowserIcon name="globe" />
    <h2 className="browser-error__title">이 페이지가 멈췄어요</h2>
    <p className="browser-error__detail">페이지를 표시하는 과정이 중단됐어요. 다시 불러오면 이 탭에서 계속할 수 있어요.</p>
    {overlay.url && <p className="browser-error__url" dir="ltr">{overlay.url}</p>}
    <div className="browser-error__actions">
      <button type="button" disabled={pending} className="browser-error__action browser-error__action--primary" onClick={() => void run(() => reloadBrowserPage(tabId))}>{pending ? '연결 중…' : '다시 불러오기'}</button>
      <button type="button" className="browser-error__action" onClick={() => useBrowserGuests.getState().requestAddressFocus(tabId)}>주소 수정</button>
    </div>
    {failure && <p className="browser-error__detail" role="status">{failure}</p>}
    <code className="browser-error__code">{overlay.reason}</code>
  </div>
}
