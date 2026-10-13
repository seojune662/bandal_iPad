/**
 * Shown in the tab's anchor when a main-frame load fails. The guest is still
 * alive underneath — only its rect is withheld — so 다시 시도 is a reload, not
 * a fresh navigation.
 *
 * There is deliberately no "그래도 진행" for certificate errors: the app
 * registers no `certificate-error` handler, so Chromium's verdict is final and
 * the only way past is the system browser, which owns that trust decision.
 */

import { invoke } from '../../lib/ipc'
import { BrowserIcon } from './browserIcons'
import { useBrowserGuests } from './browserGuestsStore'
import { guestActions } from './guestActions'
import {
  errorCopy,
  type BrowserCrashOverlay,
  type BrowserLoadErrorOverlay
} from './loadError'
import { hostnameForUrl } from './browserStartPageModel'

export function BrowserErrorPage({
  tabId,
  overlay
}: {
  tabId: string
  overlay: BrowserLoadErrorOverlay
}): JSX.Element | null {
  const copy = errorCopy(overlay.errorCode, hostnameForUrl(overlay.url))
  if (copy === null) return null

  return (
    <div className="browser-error" role="alert">
      <BrowserIcon name="globe" />
      <h2 className="browser-error__title">{copy.title}</h2>
      <p className="browser-error__detail">{copy.detail}</p>
      <div className="browser-error__actions">
        {copy.canRetry && (
          <button
            type="button"
            className="browser-error__action browser-error__action--primary"
            onClick={() => {
              useBrowserGuests.getState().setOverlay(tabId, null)
              guestActions.reload(tabId)
            }}
          >
            다시 시도
          </button>
        )}
        {copy.offerExternal && (
          <button
            type="button"
            className="browser-error__action"
            onClick={() => {
              void invoke('shell:openExternal', { url: overlay.url })
            }}
          >
            기본 브라우저에서 열기
          </button>
        )}
      </div>
      <code className="browser-error__code">
        {overlay.errorDescription} ({overlay.errorCode})
      </code>
    </div>
  )
}

/**
 * A guest whose renderer process died.
 *
 * Separate from the load-error page because the recovery is different: there
 * is no error code to explain and nothing to hand to the system browser — the
 * page was fine, the process was not. 다시 불러오기 rebuilds it in place.
 */
export function BrowserCrashPage({
  tabId,
  overlay
}: {
  tabId: string
  overlay: BrowserCrashOverlay
}): JSX.Element {
  return (
    <div className="browser-error" role="alert">
      <BrowserIcon name="globe" />
      <h2 className="browser-error__title">이 페이지가 멈췄어요</h2>
      <p className="browser-error__detail">
        {hostnameForUrl(overlay.url)} 을(를) 보여주던 과정이 중단됐어요. 다시
        불러오면 대부분 해결돼요.
      </p>
      <div className="browser-error__actions">
        <button
          type="button"
          className="browser-error__action browser-error__action--primary"
          onClick={() => {
            useBrowserGuests.getState().setOverlay(tabId, null)
            guestActions.reload(tabId)
          }}
        >
          다시 불러오기
        </button>
      </div>
      <code className="browser-error__code">{overlay.reason}</code>
    </div>
  )
}
