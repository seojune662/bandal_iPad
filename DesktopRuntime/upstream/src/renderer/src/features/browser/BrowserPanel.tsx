import { getAgentLoginForTab } from './agentLoginTabs'
import { openDiagnostics } from './diagnosticsBridge'
import { usePanelVisible } from '../workspace/usePanelVisible'
import { AssistantPanelToggle } from '../assistantPanel/AssistantPanelToggle'
/**
 * [M3-F] Browser tab panel — dockview drop-in replacing the M2 placeholder.
 *
 * Owns only the chrome (nav buttons, URL bar, progress) and the anchor the
 * real <webview> guest is positioned over. The guest itself lives in
 * BrowserWebviewLayer; unmounting this panel hides it, never destroys it
 * (see browserAnchor.ts for the contract).
 */

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState
} from 'react'
import type { IDockviewPanelProps } from 'dockview'
import type { BrowserTabPayload } from '../../../../shared/tabs'
import { browserProfileStartUrl } from '../../../../shared/browserAuth'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { DEFAULT_BROWSER_URL } from '../../app/tabCommands'
import { Tooltip } from '../../components/Tooltip'
import { useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { favoriteScopeKey, useFavoritesStore } from '../../stores/favoritesStore'
import { settingsSnapshot } from '../../stores/settingsSnapshot'
import { browserTabCourseId, useWorkspaceStore } from '../../stores/workspaceStore'
import { useWorkspacePlacement } from '../workspace/placementContext'
import { isTabDescriptor } from '../workspace/tabIdentity'
import { useBrowserAnchorRect } from '../workspace/panels/browserAnchor'
import { BrowserIcon } from './browserIcons'
import {
  initialNavState,
  useBrowserGuests,
  type BrowserNavState
} from './browserGuestsStore'
import { BrowserCrashPage, BrowserErrorPage } from './BrowserErrorPage'
import { BrowserDownloadPage } from './BrowserDownloadPage'
import { BrowserDownloadsPanel } from './BrowserDownloadsPanel'
import { BrowserDiagnosticsPanel } from './BrowserDiagnosticsPanel'
import { OPEN_DIAGNOSTICS_EVENT } from './diagnosticsBridge'
import { isDefaultZoom, zoomPercent } from './zoom'
import { useDownloads } from './downloadsStore'
import { toggleFavorite, useBrowserFavorite } from './browserFavorite'
import { BrowserFindBar } from './BrowserFindBar'
import { AgentRunBanner } from './AgentRunBanner'
import {
  browserFavoriteShortcuts,
  hostnameForUrl,
  initialForUrl,
  toneForUrl,
  type BrowserShortcut
} from './browserStartPageModel'
import { guestActions } from './guestActions'
import { scheduleBrowserAutofocus } from './browserAutofocus'
import {
  discardStagedLoginForTab,
  fillLoginForTab,
  saveStagedLoginForTab
} from './loginBridge'
import { BrowserLoginPrompt } from './BrowserLoginPrompt'
import { BrowserProfilePicker } from './BrowserProfilePicker'
import { BrowserToolbarOverflow } from './BrowserToolbarOverflow'
import { BrowserImportBanner } from './BrowserImportDialog'
import { BrowserAddressInput } from './BrowserAddressInput'
import { scheduleProgressVisibility } from './loadingIndicator'
import { openWebVideoInPip, useWebVideoReport } from './videoBridge'
import './browser.css'

function browserPayloadFromParams(params: unknown): BrowserTabPayload | null {
  if (typeof params !== 'object' || params === null) return null
  const descriptor = (params as Record<string, unknown>)['descriptor']
  if (!isTabDescriptor(descriptor) || descriptor.kind !== 'browser') return null
  return descriptor.payload
}

function hostnameOf(url: string): string {
  try {
    return new URL(url).hostname
  } catch {
    return url
  }
}

interface ToolbarProps {
  tabId: string
  ownerCourse: string | null
  nav: BrowserNavState
  onNavigate: (url: string) => void
  isPrivate: boolean
  onTogglePrivate: () => void
  profileId: string
  onProfileChange: (id: string) => Promise<boolean>
  sessionChanging: boolean
  isPanelVisible: boolean
}

function useBrowserFavoriteShortcuts(profileId: string, courseId: string | null): BrowserShortcut[] {
  const key = favoriteScopeKey(courseId)
  const stored = useFavoritesStore((state) => state.byCourse[key])
  const global = useFavoritesStore((state) => state.byCourse[favoriteScopeKey(null)])
  const load = useFavoritesStore((state) => state.load)

  useEffect(() => {
    for (const scope of courseId === null ? [null] : [courseId, null]) {
      const state = useFavoritesStore.getState()
      const scopeKey = favoriteScopeKey(scope)
      if (state.byCourse[scopeKey] === undefined && !state.loadingByCourse[scopeKey]) void load(scope)
    }
  }, [courseId, load])

  return useMemo(() => browserFavoriteShortcuts([...(stored ?? []), ...(courseId === null ? [] : global ?? [])], profileId), [stored, global, courseId, profileId])
}

function BrowserSiteMark({ url }: { url: string }): JSX.Element {
  return (
    <span
      className="browser-site-mark"
      data-tone={toneForUrl(url)}
      aria-hidden="true"
    >
      {initialForUrl(url)}
    </span>
  )
}

function BrowserBookmarksBar({
  favorites,
  onNavigate
}: {
  favorites: readonly BrowserShortcut[]
  onNavigate: (url: string) => void
}): JSX.Element | null {
  if (favorites.length === 0) return null

  return (
    <nav className="browser-bookmarks" aria-label="즐겨찾기 바로가기">
      {favorites.map((favorite) => (
        <Tooltip
          key={favorite.id}
          label={`${favorite.label} — ${hostnameForUrl(favorite.url)}`}
          placement="bottom"
        >
          <button
            type="button"
            className="browser-bookmark"
            onClick={() => onNavigate(favorite.url)}
          >
            <BrowserSiteMark url={favorite.url} />
            <span>{favorite.label}</span>
          </button>
        </Tooltip>
      ))}
    </nav>
  )
}

export function BrowserFavoriteButton({
  starred,
  onToggle
}: {
  starred: boolean
  onToggle: () => void
}): JSX.Element {
  const ariaLabel = starred ? '즐겨찾기에서 제거' : '즐겨찾기에 추가'
  return (
    <Tooltip
      label={starred ? '즐겨찾기에서 빼기' : '즐겨찾기에 추가 (⌘D)'}
      placement="bottom"
    >
      <button
        type="button"
        className="browser-nav-button"
        aria-label={ariaLabel}
        aria-pressed={starred}
        onClick={onToggle}
      >
        <BrowserIcon name={starred ? 'starFilled' : 'star'} />
      </button>
    </Tooltip>
  )
}

export function BrowserPipChip({
  hasPlayingVideo,
  onOpen
}: {
  hasPlayingVideo: boolean
  onOpen: () => void
}): JSX.Element | null {
  if (!hasPlayingVideo) return null
  return (
    <button
      type="button"
      className="browser-login-button"
      aria-label="작은 창으로 보기"
      onClick={onOpen}
    >
      <BrowserIcon name="pip" />
      PiP
    </button>
  )
}

export { BrowserLoginPrompt } from './BrowserLoginPrompt'

function BrowserToolbar({
  tabId,
  ownerCourse,
  nav,
  onNavigate,
  isPrivate,
  onTogglePrivate,
  profileId,
  onProfileChange,
  sessionChanging,
  isPanelVisible
}: ToolbarProps): JSX.Element {
  const video = useWebVideoReport(tabId)
  const login = useBrowserGuests((state) => state.login[tabId])
  const zoomLevel = useBrowserGuests(
    (state) =>
      state.zoom[tabId] ?? settingsSnapshot().browser.defaultZoomLevel
  )
  const addressFocusSeq = useBrowserGuests(
    (state) => state.addressFocusSeq[tabId] ?? 0
  )
  const activeDownloads = useDownloads((state) => state.activeCount)
  const anyDownloads = useDownloads((state) => state.downloads.length > 0)
  const [downloadsAnchor, setDownloadsAnchor] = useState<DOMRect | null>(null)
  const [diagnosticsAnchor, setDiagnosticsAnchor] = useState<DOMRect | null>(null)
  const [progressVisible, setProgressVisible] = useState(false)
  const toolbarActionsRef = useRef<HTMLDivElement>(null)

  useEffect(
    () => scheduleProgressVisibility(nav.loading, setProgressVisible),
    [nav.loading]
  )

  // The context menu lives outside this subtree, so it asks by event rather
  // than by threading a callback through four components.
  useEffect(() => {
    const onOpen = (event: Event): void => {
      if ((event as CustomEvent<string>).detail === tabId) {
        const anchor = toolbarActionsRef.current?.getBoundingClientRect()
        if (anchor !== undefined) setDiagnosticsAnchor(anchor)
      }
    }
    window.addEventListener(OPEN_DIAGNOSTICS_EVENT, onOpen)
    return () => window.removeEventListener(OPEN_DIAGNOSTICS_EVENT, onOpen)
  }, [tabId])
  const starred = useBrowserFavorite(nav.url, profileId, ownerCourse)
  const favicon = useBrowserGuests((state) => state.favicon[tabId])
  const findState = useBrowserGuests((state) => state.find[tabId])
  const loginTooltip =
    `${login?.savedLogin?.username ?? ''} 계정으로 안전하게 채웁니다.`

  const goBack = (): void => {
    if (nav.canGoBack) guestActions.back(tabId)
  }

  return (
    <div className="browser-chrome">
      <header className="browser-toolbar" aria-label="브라우저 도구 모음">
        <div className="browser-toolbar__nav">
          <Tooltip label="뒤로" placement="bottom">
            <button
              type="button"
              className="browser-nav-button"
              aria-label="뒤로"
              disabled={!nav.canGoBack}
              onClick={goBack}
            >
              <BrowserIcon name="arrowLeft" />
            </button>
          </Tooltip>
          <Tooltip label="앞으로" placement="bottom">
            <button
              type="button"
              className="browser-nav-button browser-nav-button--forward"
              aria-label="앞으로"
              disabled={!nav.canGoForward}
              onClick={() => guestActions.forward(tabId)}
            >
              <BrowserIcon name="arrowRight" />
            </button>
          </Tooltip>
          <Tooltip label={nav.loading ? '중지' : '새로고침'} placement="bottom">
            <button
              type="button"
              className="browser-nav-button"
              aria-label={nav.loading ? '중지' : '새로고침'}
              onClick={() =>
                nav.loading
                  ? guestActions.stop(tabId)
                  : guestActions.reload(tabId)
              }
            >
              <Icon name={nav.loading ? 'x' : 'refresh'} />
            </button>
          </Tooltip>
          <Tooltip label="홈" placement="bottom">
            <button
              type="button"
              className="browser-nav-button browser-nav-button--home"
              aria-label="홈페이지로 이동"
              onClick={() => {
                const homePage = settingsSnapshot().browser.homePage
                onNavigate(homePage !== '' ? homePage : DEFAULT_BROWSER_URL)
              }}
            >
              <BrowserIcon name="home" />
            </button>
          </Tooltip>
        </div>

        <BrowserAddressInput
          value={nav.url}
          onNavigate={onNavigate}
          focusSeq={addressFocusSeq}
          favicon={favicon}
          isPrivate={isPrivate}
          profileId={profileId}
          courseId={ownerCourse}
        />

        <div ref={toolbarActionsRef} className="browser-toolbar__actions">
          <BrowserProfilePicker profileId={profileId} onChange={onProfileChange} />
          {isPanelVisible && !isPrivate && login?.savePrompt && (
            <BrowserLoginPrompt
              key={`${login.savePrompt.origin}:${login.savePrompt.username}:${login.savePrompt.kind}`}
              kind={login.savePrompt.kind}
              origin={login.savePrompt.origin}
              username={login.savePrompt.username}
              pending={login.pending}
              onSave={() => void saveStagedLoginForTab(tabId).then(result => {
                if (result === 'saved') showToast('비밀번호를 저장했어요.')
                else if (result === 'expired') showToast('저장할 로그인 정보가 만료됐어요. 다음 로그인 때 다시 저장해 주세요.', 'danger')
                else showToast('비밀번호를 저장하지 못했어요. 다시 시도해 주세요.', 'danger')
              })}
              onDecline={() => void discardStagedLoginForTab(tabId, false)}
              onSuppress={() => void discardStagedLoginForTab(tabId, true)}
            />
          )}
          <BrowserToolbarOverflow isPrivate={isPrivate} active={isPanelVisible}>
          <button type="button" className="browser-nav-button browser-toolbar-menu__navigation" aria-label="앞으로"
            disabled={!nav.canGoForward} onClick={() => guestActions.forward(tabId)}><BrowserIcon name="arrowRight" /></button>
          <button type="button" className="browser-nav-button browser-toolbar-menu__navigation" aria-label="홈페이지로 이동"
            onClick={() => onNavigate(settingsSnapshot().browser.homePage || DEFAULT_BROWSER_URL)}><BrowserIcon name="home" /></button>
          <Tooltip
            label={isPrivate ? '시크릿 모드 끄기' : '이 탭을 시크릿 모드로 전환'}
            placement="bottom"
          >
            <button
              type="button"
              className="browser-nav-button browser-private-button"
              aria-label={isPrivate ? '시크릿 모드 끄기' : '시크릿 모드 켜기'}
              aria-pressed={isPrivate}
              disabled={sessionChanging}
              onClick={onTogglePrivate}
            >
              <BrowserIcon name="private" />
            </button>
          </Tooltip>
          <BrowserPipChip
            hasPlayingVideo={video?.hasPlayingVideo === true}
            onOpen={() => {
              void openWebVideoInPip(tabId, {
                url: nav.url,
                title: nav.title
              }).catch(() => {
                showToast('작은 창을 열지 못했어요.', 'danger')
              })
            }}
          />
          {!isPrivate && (
            <BrowserFavoriteButton
              starred={starred !== null}
              onToggle={() => toggleFavorite(tabId, nav)}
            />
          )}
          {(activeDownloads > 0 || anyDownloads) && (
            <Tooltip
              label={
                activeDownloads > 0
                  ? `${activeDownloads}개 내려받는 중`
                  : '받은 파일'
              }
              placement="bottom"
            >
              {/* Was a non-interactive <span>: the count was visible and the
                  transfer was not stoppable. */}
              <button
                type="button"
                className="browser-download-badge"
                aria-expanded={downloadsAnchor !== null}
                aria-label="다운로드"
                onClick={(event) => {
                  if (downloadsAnchor !== null) {
                    setDownloadsAnchor(null)
                    return
                  }
                  setDiagnosticsAnchor(null)
                  setDownloadsAnchor(event.currentTarget.getBoundingClientRect())
                }}
              >
                <BrowserIcon name="download" />
                {activeDownloads > 0 ? activeDownloads : null}
              </button>
            </Tooltip>
          )}
          {!isDefaultZoom(
            zoomLevel,
            settingsSnapshot().browser.defaultZoomLevel
          ) && (
            <Tooltip label="기본 크기로 (⌘0)" placement="bottom">
              <button
                type="button"
                className="browser-zoom-pill"
                aria-label={`기본 크기로 (${zoomPercent(zoomLevel)}%)`}
                onClick={() => {
                  const defaultZoomLevel =
                    settingsSnapshot().browser.defaultZoomLevel
                  useBrowserGuests.getState().setZoom(tabId, defaultZoomLevel)
                  guestActions.setZoom(tabId, defaultZoomLevel)
                }}
              >
                {zoomPercent(zoomLevel)}%
              </button>
            </Tooltip>
          )}
          </BrowserToolbarOverflow>
          {downloadsAnchor !== null && <BrowserDownloadsPanel anchor={downloadsAnchor} onClose={() => setDownloadsAnchor(null)} />}
          {diagnosticsAnchor !== null && <BrowserDiagnosticsPanel tabId={tabId} anchor={diagnosticsAnchor} onClose={() => setDiagnosticsAnchor(null)} />}
          {login?.hasLoginForm === true &&
            login.usernameFocused &&
            login.origin !== null &&
            login.savedLogins.length > 0 && (
            <div className="browser-login-action">
              {login.savedLogins.length > 1 ? (
                <label className="browser-login-account-control">
                <BrowserIcon name="key" className="browser-login-account-control__icon" />
                <select
                  aria-label="저장된 로그인 계정 선택"
                  className="browser-login-account"
                  value=""
                  disabled={login.pending}
                  onChange={(event) => {
                    if (event.target.value) void fillLoginForTab(tabId, event.target.value)
                  }}
                >
                  <option value="">계정을 선택해 채우기</option>
                  {login.savedLogins.map((account) => (
                    <option key={account.id} value={account.id}>{account.username || account.origin}</option>
                  ))}
                </select>
                </label>
              ) : (
              <Tooltip label={loginTooltip} placement="bottom">
                <button
                  type="button"
                  className="browser-login-button"
                  disabled={login.pending}
                  onClick={() => void fillLoginForTab(tabId)}
                >
                  <BrowserIcon name="key" />
                  {login.pending
                    ? '처리 중…'
                    : '저장된 로그인 채우기'}
                </button>
              </Tooltip>
              )}
              {login.message !== null && (
                <span className="browser-login-message" role="status">
                  {login.message === 'saved'
                    ? '저장됨'
                    : login.message === 'filled'
                      ? '채움'
                      : login.message === 'needs-input'
                        ? '비밀번호를 직접 입력한 뒤 저장하세요.'
                        : '처리하지 못했어요.'}
                </span>
              )}
            </div>
          )}
          <AssistantPanelToggle className="browser-assistant-toggle" />
        </div>
      </header>
      <AgentRunBanner tabId={tabId} />
      {findState !== undefined && (
        <BrowserFindBar tabId={tabId} state={findState} />
      )}
      <div
        className="browser-progress"
        data-active={progressVisible ? 'true' : undefined}
        aria-hidden="true"
      >
        <div className="browser-progress__bar" />
      </div>
    </div>
  )
}

export function BrowserPanel(props: IDockviewPanelProps): JSX.Element {
  const payload = browserPayloadFromParams(props.params)
  const tabId = payload?.tabId ?? ''
  const placement = useWorkspacePlacement()
  const fallbackCourse = useWorkspaceStore(() => browserTabCourseId(tabId))
  const ownerCourse = placement ? placement.courseId : fallbackCourse
  const initialUrl = payload?.initialUrl ?? ''
  const initialPrivate = payload?.isPrivate === true
  const [isPrivate, setPrivate] = useState(initialPrivate)
  const [profileId, setProfileId] = useState(payload?.profileId ?? 'default')
  const sessionChangingRef = useRef(false)
  const [sessionChanging, setSessionChanging] = useState(false)
  const sessionTargetRef = useRef({ profileId, isPrivate })

  const anchorRef = useRef<HTMLDivElement>(null)
  useBrowserAnchorRect(tabId, anchorRef)
  const t = useT()
  const isPanelVisible = usePanelVisible(props.api)
  const visibleRef = useRef(isPanelVisible)
  visibleRef.current = isPanelVisible

  const nav = useBrowserGuests((state) =>
    tabId !== '' ? state.nav[tabId] : undefined
  )
  const overlay = useBrowserGuests((state) => state.overlay[tabId] ?? null)
  const managedLogin = getAgentLoginForTab(tabId)
  const authFallback = useBrowserGuests((state) => state.authFallback[tabId])
  const navState = nav ?? initialNavState(initialUrl)
  const favorites = useBrowserFavoriteShortcuts(profileId, ownerCourse)

  const navigate = useCallback(
    (url: string): void => {
      if (tabId === '') return
      const state = useBrowserGuests.getState()
      if (state.liveGuests.some((guest) => guest.tabId === tabId)) {
        guestActions.navigate(tabId, url)
      } else {
        state.ensureGuest(tabId, url, isPrivate, profileId, ownerCourse)
      }
      // A fresh address dismisses whatever the last load left on screen.
      state.setOverlay(tabId, null)
    },
    [isPrivate, tabId, profileId, ownerCourse]
  )

  // Unvisited background tabs stay cheap; a visited page remains alive when hidden.
  useEffect(() => {
    // Dockview parameter changes can flush a previous render's passive effect.
    // Never let that stale profile recreate a page during/after a session switch.
    if (sessionChangingRef.current || profileId !== sessionTargetRef.current.profileId ||
      isPrivate !== sessionTargetRef.current.isPrivate) return
    if (tabId !== '' && isPanelVisible) {
      useBrowserGuests.getState().ensureGuest(tabId, initialUrl, isPrivate, profileId, ownerCourse)
    }
  }, [isPrivate, tabId, initialUrl, profileId, isPanelVisible, ownerCourse, sessionChanging])

  const togglePrivate = useCallback((): void => {
    if (tabId === '' || sessionChangingRef.current) return
    sessionChangingRef.current = true
    setSessionChanging(true)
    void (async () => {
      const { allowed } = await invoke('browser:prepareProfileSwitch', { tabId })
      if (!allowed) return
      const next = !isPrivate
      const url = browserProfileStartUrl(navState.url || initialUrl, authFallback?.restartUrl ?? initialUrl)
      sessionTargetRef.current = { profileId, isPrivate: next }
      setPrivate(next)
      props.api.updateParameters({
        descriptor: {
          kind: 'browser',
          payload: {
            tabId,
            initialUrl: url,
            profileId,
            ...(next ? { isPrivate: true } : {})
          }
        }
      })
      useBrowserGuests.getState().ensureGuest(tabId, url, next, profileId, ownerCourse)
      useWorkspaceStore.getState().notifyLayoutChanged()
    })().catch(() => showToast('시크릿 모드를 전환하지 못했어요. 다시 시도해 주세요.', 'danger')).finally(() => {
      sessionChangingRef.current = false
      setSessionChanging(false)
    })
  }, [initialUrl, isPrivate, navState.url, props.api, tabId, profileId, ownerCourse, authFallback])

  const changeProfile = useCallback(async (id: string): Promise<boolean> => {
    if (id === profileId) return true
    if (tabId === '' || sessionChangingRef.current) return false
    sessionChangingRef.current = true
    setSessionChanging(true)
    try {
      const { allowed } = await invoke('browser:prepareProfileSwitch', { tabId })
      if (!allowed) return false
      const url = browserProfileStartUrl(navState.url || initialUrl, authFallback?.restartUrl ?? initialUrl)
      sessionTargetRef.current = { profileId: id, isPrivate }
      setProfileId(id)
      props.api.updateParameters({ descriptor: { kind: 'browser', payload: { tabId, initialUrl: url, isPrivate, profileId: id } } })
      useBrowserGuests.getState().ensureGuest(tabId, url, isPrivate, id, ownerCourse)
      useWorkspaceStore.getState().notifyLayoutChanged()
      return true
    } finally {
      sessionChangingRef.current = false
      setSessionChanging(false)
    }
  }, [profileId, tabId, navState.url, initialUrl, props.api, isPrivate, ownerCourse, authFallback])

  // Reflect the page title into the dockview tab.
  const { api } = props
  useEffect(() => {
    const title = navState.title || hostnameOf(navState.url) || '브라우저'
    if (title !== api.title) api.setTitle(title)
  }, [api, navState.title, navState.url])

  // Remember where the tab actually is, so restarting does not throw the
  // student back to the URL the tab was opened with. `initialUrl` is excluded
  // from the structural key (layoutPersistence), so this costs no extra write:
  // the parked snapshot carries it on quit and on course switch.
  /**
   * Hand keyboard focus to the page when its tab becomes active.
   *
   * Chrome focuses the document. Without this, activating a browser tab left
   * focus in the host chrome: ↓ and PageDown did nothing, Tab did not move
   * between form fields, and typing went nowhere until the student clicked
   * into the page.
   */
  useEffect(() => {
    if (!isPanelVisible || tabId === '') return undefined
    return scheduleBrowserAutofocus(tabId, () => visibleRef.current && api.isVisible && api.isActive)
  }, [api, isPanelVisible, tabId])

  useEffect(() => {
    if (sessionChangingRef.current || profileId !== sessionTargetRef.current.profileId ||
      isPrivate !== sessionTargetRef.current.isPrivate) return
    const liveNav = useBrowserGuests.getState().nav[tabId]
    if (liveNav && liveNav.url !== navState.url) return
    if (tabId === '' || navState.url === '' || navState.url === initialUrl) {
      return
    }
    api.updateParameters({
      descriptor: {
        kind: 'browser',
        payload: {
          tabId,
          initialUrl: navState.url,
          profileId,
          ...(isPrivate ? { isPrivate: true } : {})
        }
      }
    })
    useWorkspaceStore.getState().notifyLayoutChanged()
  }, [api, initialUrl, isPrivate, navState.url, tabId, profileId, sessionChanging])

  if (payload === null) {
    return <div className="workspace-panel" data-kind="unknown" />
  }

  return (
    <div
      className="browser-panel"
      data-kind="browser"
      data-private={isPrivate ? 'true' : undefined}
    >
      <BrowserToolbar
        tabId={tabId}
        ownerCourse={ownerCourse}
        nav={navState}
        onNavigate={navigate}
        isPrivate={isPrivate}
        onTogglePrivate={togglePrivate}
        profileId={profileId}
        onProfileChange={changeProfile}
        sessionChanging={sessionChanging}
        isPanelVisible={isPanelVisible}
      />
      <BrowserBookmarksBar favorites={favorites} onNavigate={navigate} />
      {isPanelVisible && !isPrivate && (navState.url === DEFAULT_BROWSER_URL || navState.url === `${DEFAULT_BROWSER_URL}/` || navState.url === 'about:blank') && <BrowserImportBanner key={profileId} profileId={profileId} />}
      {isPanelVisible && (navState.httpStatus ?? 0) >= 400 && (
        <div className="browser-external-auth" role="status">
          <span className="browser-external-auth__message">{`사이트에서 HTTP ${navState.httpStatus} 응답을 보냈어요. 로그인 요청은 자동으로 다시 보내지 않습니다.`}</span>
          <button type="button" className="browser-login-prompt__action" onClick={() => openDiagnostics(tabId)}>진단 보기</button>
        </div>
      )}
      {isPanelVisible && authFallback !== undefined && (
        <div
          className="browser-external-auth"
          role="status"
          aria-live="polite"
        >
          <BrowserIcon name="globe" />
          <span className="browser-external-auth__message">
            {t(managedLogin ? authFallback.reason === 'supervised-account' ? 'browser.authFallback.agentSupervised' : 'browser.authFallback.agentMessage' : authFallback.reason === 'supervised-account' ? 'browser.authFallback.supervised' : 'browser.authFallback.message')}
          </span>
          {authFallback.reason === 'supervised-account' && !managedLogin && (
            <button type="button" className="browser-login-prompt__action"
              onClick={() => {
                navigate(authFallback.restartUrl)
                useBrowserGuests.getState().setAuthFallback(tabId, null)
              }}
            >{t('browser.authFallback.retry')}</button>
          )}
          <button
            type="button"
            className="browser-login-prompt__action browser-login-prompt__action--primary"
            onClick={() => {
              const opening = managedLogin
                ? invoke('agent:reopenLogin', { ...managedLogin, external: true }).then(result => { if (!result.ok) throw new Error(result.message) })
                : invoke('shell:openExternal', { url: authFallback.restartUrl })
              void opening.catch(() => showToast('기본 브라우저를 열지 못했어요. 다시 시도해 주세요.', 'danger'))
            }}
          >
            {t(managedLogin ? 'browser.authFallback.agentAction' : 'browser.authFallback.action')}
          </button>
          <button
            type="button"
            className="browser-external-auth__dismiss"
            aria-label={t('browser.authFallback.dismiss')}
            onClick={() =>
              useBrowserGuests.getState().setAuthFallback(tabId, null)
            }
          >
            <Icon name="x" />
          </button>
        </div>
      )}
      <div
        ref={anchorRef}
        className="browser-anchor"
        data-browser-anchor={tabId}
      >
        {overlay !== null ? (
          overlay.kind === 'download' ? (
            <BrowserDownloadPage id={overlay.downloadId} />
          ) : overlay.kind === 'crashed' ? (
            <BrowserCrashPage tabId={tabId} overlay={overlay} />
          ) : (
            <BrowserErrorPage tabId={tabId} overlay={overlay} />
          )
        ) : (
          /* Shown before first paint / if the guest renderer ever goes away. */
          <div className="browser-anchor__fallback">
            <BrowserIcon name="globe" />
            <span>{hostnameOf(navState.url)}</span>
          </div>
        )}
      </div>
    </div>
  )
}
