import { useNativePageOcclusion } from './useNativePageOcclusion'
/**
 * Fixed layer hosting native browser page anchors outside the dockview DOM.
 * Mounted once at shell level (AppShell).
 *
 * Also owns the cross-cutting wiring:
 *  - guest destruction when the workspace closes a browser tab
 *  - `browser:open-url` pushes → adopted popup or new Bandal browser tab
 *  - `browser:external-auth` pushes → short-lived in-panel notice
 *  - pointer passthrough while dockview drags / the new-tab menu / any
 *    external overlay (webviewPassthrough tokens) are active
 */

import { useEffect, useLayoutEffect, useState, useSyncExternalStore } from 'react'
import { setNativeHostBlocked } from './nativeHostVisibility'
import { installWorkspaceNativePassthrough } from './workspaceNativePassthrough'
import { tabDragSession } from '../workspace/tabDragSession'
import { registerTabCloseGuard } from '../workspace/tabCloseGuard'
import { v4 as uuidv4 } from 'uuid'
import { invoke, onPush } from '../../lib/ipc'
import { showToast, showToastWithAction } from '../../app/toast'
import { useWorkspaceStore, retainedTabDescriptors, openBrowserTabInCourse } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { useNewTabMenu } from '../workspace/newTabMenuController'
import { BrowserGuestView } from './BrowserGuestView'
import { useBrowserGuests } from './browserGuestsStore'
import {
  useActivateTabRequests,
  useAgentTabSync,
  useCloseTabRequests
} from './agentTabSync'
import { rememberOpenRequest } from './guestActions'
import { installAgentLoginTabLifecycle, prepareAgentLoginTab } from './agentLoginTabs'
import { installBrowserAuthForwarding } from './browserAuthForwarding'
import {
  isPointerPassthroughActive,
  onPointerPassthrough
} from './webviewPassthrough'
import './browser.css'

/** Release pages whose tabs have closed; cached courses keep their pages. */
function useGuestReaper(): void {
  useEffect(
    () =>
      useWorkspaceStore.subscribe((state) => {
        // While a course hydration is in flight openTabs is transiently
        // empty; only reap against a settled workspace.
        if (state.hydration !== 'ready') return
        const openBrowserTabs = new Set<string>()
        for (const descriptor of retainedTabDescriptors()) {
          if (descriptor.kind === 'browser') {
            openBrowserTabs.add(descriptor.payload.tabId)
          }
        }
        const { nav, recent, overlay, removeGuest } =
          useBrowserGuests.getState()
        const sessionTabIds = new Set([
          ...Object.keys(nav),
          ...Object.keys(recent),
          ...Object.keys(overlay)
        ])
        for (const tabId of sessionTabIds) {
          if (!openBrowserTabs.has(tabId)) removeGuest(tabId)
        }
      }),
    []
  )
}

/** Adopt native popups and route requested URLs into workspace tabs. */
function useOpenUrlForwarding(): void {
  useEffect(
    () =>
      onPush('browser:open-url', (payload) => {
        const { url, background, requestId, isPrivate, profileId, tabId: adoptedTabId } = payload
        const { tabId, courseId } = prepareAgentLoginTab(payload, adoptedTabId ?? uuidv4())
        // Main matched the new tab to the agent's request by URL prefix, which
        // a redirect breaks. Remember which request this tab belongs to so the
        // guest can say so when it registers.
        if (requestId !== undefined) rememberOpenRequest(tabId, requestId)
        const retained = openBrowserTabInCourse(
            descriptorFor('browser', {
              tabId,
              initialUrl: url,
              profileId: profileId ?? 'default',
              ...(isPrivate === true ? { isPrivate: true } : {})
            }),
            courseId, background === true
          )
        if (!retained && adoptedTabId) {
          void invoke('browser:destroyPage', { tabId: adoptedTabId }).catch(() => undefined)
        } else if (retained && adoptedTabId) {
          // Chromium already created this page. Track its lifetime and events
          // even when its owning course no longer has a mounted Dockview.
          useBrowserGuests.getState().ensureGuest(tabId, url, isPrivate === true,
            profileId ?? 'default', courseId === undefined ? useWorkspaceStore.getState().activeCourseId : courseId)
        }
      }),
    []
  )
}

/** Main detects explicit embedded-login refusals in tabs and site windows. */
function useAuthFallbackForwarding(): void {
  useEffect(() => installBrowserAuthForwarding(), [])
}

/**
 * Say when the browser refuses something the page asked for.
 *
 * Silence here is what made a broken portal indistinguishable from a page
 * with nothing to do — the app knew exactly what it had blocked and told
 * nobody.
 */
function useBlockedNotices(): void {
  useEffect(() => {
    const unsubscribePopup = onPush('browser:popup-blocked', ({ origin, reason, profileId = 'default', isPrivate }) => {
      if (isPrivate && reason === 'policy') { showToast('시크릿 탭의 팝업이 차단됐어요. 브라우저 설정에서 팝업 차단 수준을 확인해 주세요.'); return }
      if (reason === 'policy' && origin !== '') {
        showToastWithAction('이 사이트의 팝업을 막았어요. 허용한 뒤 다시 눌러 주세요.', {
          label: '이 사이트 허용',
          run: () => {
            void invoke('browser:setPopupPermission', {
              profileId,
              origin,
              decision: 'granted'
            }).then(() => showToast('이 사이트의 팝업을 허용했어요.'))
          }
        })
        return
      }
      // Burst/concurrent limits stay non-overridable: they are the last line
      // of defence against a page filling the desktop with windows.
      showToast('반복 팝업을 막았어요.')
    })
    // Main emits this on every deny. Nobody was listening, so a page that
    // navigated to a hard-blocked scheme produced a console.warn and nothing
    // else — the 보안 프로그램 설치 link just did nothing, forever.
    const unsubscribeBlocked = onPush('browser:blocked', ({ kind }) => {
      if (kind !== 'navigation') return
      showToast('이 주소는 반달에서 열 수 없어요.')
    })
    const unsubscribeScheme = onPush('browser:external-scheme', ({ outcome }) => {
      if (outcome !== 'no-handler') return
      showToast('이 프로그램이 설치되어 있지 않아요.')
    })
    return () => {
      unsubscribePopup()
      unsubscribeBlocked()
      unsubscribeScheme()
    }
  }, [])
}

export function BrowserWebviewLayer(): JSX.Element {
  const liveGuests = useBrowserGuests((state) => state.liveGuests)
  const isMenuOpen = useNewTabMenu((state) => state.isOpen)
  const isDragActive = useSyncExternalStore(tabDragSession.subscribe, tabDragSession.getSnapshot) !== null
  useLayoutEffect(() => {
    setNativeHostBlocked('workspace', isMenuOpen)
  }, [isMenuOpen])
  useLayoutEffect(() => installWorkspaceNativePassthrough(), [])
  useLayoutEffect(() => () => setNativeHostBlocked('workspace', false), [])
  useEffect(() => registerTabCloseGuard(async descriptor => {
    if (descriptor.kind !== 'browser') return true
    try { return (await invoke('browser:prepareClose', { tabId: descriptor.payload.tabId })).allowed }
    catch { showToast('페이지를 닫지 못했어요. 다시 시도해 주세요.'); return false }
  }), [])
  const [hasExternalToken, setExternalToken] = useState(
    isPointerPassthroughActive
  )
  useEffect(() => onPointerPassthrough(setExternalToken), [])
  useGuestReaper()
  useEffect(() => onPush('browser:page-event', event => {
    if (event.name === 'did-navigate' || event.name === 'did-navigate-in-page' || event.name === 'page-title-updated') {
      useWorkspaceStore.getState().rememberDetachedBrowserPage(event.tabId, event.state.url, event.state.title)
    }
  }), [])
  useOpenUrlForwarding()
  useEffect(() => installAgentLoginTabLifecycle(), [])
  useAuthFallbackForwarding()
  useBlockedNotices()
  useAgentTabSync()
  useActivateTabRequests()
  useCloseTabRequests()

  const occlusions = useNativePageOcclusion()
  const isPassthrough = isDragActive || isMenuOpen || hasExternalToken

  return (
    <div
      className="browser-webview-layer"
      data-passthrough={isPassthrough ? 'true' : undefined}
    >
      {liveGuests.map((guest) => (
        <BrowserGuestView
          key={`${guest.tabId}:${guest.isPrivate ? 'private' : 'normal'}:${guest.profileId}`}
          tabId={guest.tabId}
          src={guest.src}
          isPrivate={guest.isPrivate}
          profileId={guest.profileId}
          suppressed={isPassthrough}
          occlusions={occlusions}
        />
      ))}
    </div>
  )
}
