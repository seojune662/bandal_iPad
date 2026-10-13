import { guestProfile, inheritGuestProfile, forgetGuestProfile } from './profiles'
import { attachEmbeddedAuthFallback, inheritEmbeddedAuthSource } from './embeddedAuth'
import { isCleanBrowserAuthProbe } from './authProbe'
import { installGestureSession, navigateBySwipe } from './swipeNavigation'
import { isManagedBrowserPage } from './managedPages'
import {
  YOUTUBE_NAVIGATION_REQUEST_URLS,
  googleAccountRequestUrl,
  prepareGoogleAccountSiteNavigation
} from './googleAccountNavigation'
/**
 * [M3-F] Electron wiring for the hardened `<webview>` browser tabs.
 *
 * Call `hardenWindowWebviews(win)` on any window created with
 * `webviewTag: true` BEFORE loading its renderer. Policy decisions live in
 * ./webviewPolicy.ts; this module only attaches them to electron objects.
 */

import { BrowserWindow, dialog, session, shell, webContents } from 'electron'
import type { Event as ElectronEvent, WebContents } from 'electron'
import type {
  BrowserOpenUrl,
  BrowserAuthEvent,
  ShortcutPassthrough
} from '../../../shared/ipc/events'
import { resolveKeymap } from '../../../shared/keymap'
import {
  BROWSING_PARTITION,
  PRIVATE_BROWSING_PARTITION,
  decidePopup,
  isAllowedAttach,
  isNavigationAllowed,
  passthroughShortcut,
  popupWindowSize,
  sanitizeGuestWebPreferences
} from './webviewPolicy'
import { installDisplayMediaHandler } from './displayMedia'
import { askForCredentials, resolveAuthPrompt } from './httpAuth'
import { permissionLabel, permissionTier } from './permissionPolicy'
import type { PermissionsRepo } from './permissionsRepo'
import {
  classifyExternalScheme,
  externalSchemeDisplay,
  requestingOriginOf
} from './externalScheme'
import { createPopupLimiter } from './popupLimiter'
import {
  TRACKING_REQUEST_URLS,
  privacyRequestHeaders,
  shouldBlockTrackingRequest
} from './trackingProtection'
import { browsingContext, registerBrowsingContext, forgetBrowsingContext } from './browsingContext'
import { trackPopupDownload } from './popupLifecycle'
import { confirmPageUnload } from './pageClose'
import { getSettings } from '../../settingsStore'
import {
  attachPluginPanelGuest,
  preparePluginPanelWebview
} from '../plugins/pluginPanels'

const hardenedBrowsingSessions = new Set<string>()

export function forwardBrowserSwipe(
  host: WebContents,
  focused: WebContents | null,
  direction: string,
  platform: NodeJS.Platform = process.platform
): void {
  if (platform !== 'darwin' || !focused || (focused.getType() !== 'webview' && !isManagedBrowserPage(focused.id))) return
  const action = direction === 'right'
    ? 'browser-back'
    : direction === 'left'
      ? 'browser-forward'
      : null
  if (action === null || host.isDestroyed()) return
  if (isManagedBrowserPage(focused.id)) { navigateBySwipe(focused, action === 'browser-back' ? 'back' : 'forward'); return }
  host.send('shortcut:passthrough', {
    action,
    webContentsId: focused.id
  } satisfies ShortcutPassthrough)
}

/**
 * Harden the shared `persist:browsing` session (idempotent):
 *  - permissions deny-by-default (fullscreen only)
 *  - no file:// requests at all (navigation guards cover the main frame;
 *    this catches subresources/subframes as defense in depth)
 *  - inherit the application's browser identity, including its real Chrome token
 */
/**
 * Remembered site decisions. Injected once at startup so this module keeps
 * knowing nothing about SQLite.
 */
const profilePermissions = new Map<string, PermissionsRepo>()
export function useProfilePermissions(partition: string, repo: PermissionsRepo): void { profilePermissions.set(partition, repo) }
export function forgetProfilePermissions(partitions: readonly string[]): void {
  for (const partition of partitions) { profilePermissions.delete(partition); hardenedBrowsingSessions.delete(partition) }
}
function permissionsFor(partition: string): PermissionsRepo | null { return profilePermissions.get(partition) ?? (partition === BROWSING_PARTITION ? sitePermissions : null) }
let sitePermissions: PermissionsRepo | null = null

export function useSitePermissions(repo: PermissionsRepo): void {
  sitePermissions = repo
}

function originOf(url: string): string | null {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    return parsed.origin
  } catch {
    return null
  }
}

/**
 * Asks the student whether a site may do something.
 *
 * A native dialog for the same reason the external-scheme one is: a page can
 * draw a convincing copy of any in-app surface inside its own rect, and this
 * question is exactly the one worth spoofing. The answer is remembered per
 * origin and listed in 설정 → 브라우저.
 */
async function askSitePermission(
  origin: string,
  permission: string,
  remember: boolean,
  partition: string
): Promise<boolean> {
  const owner = BrowserWindow.getFocusedWindow()
  const options: Electron.MessageBoxOptions = {
    type: 'question',
    noLink: true,
    buttons: ['차단', '허용'],
    defaultId: 0,
    cancelId: 0,
    message: `${origin} 이(가) ${permissionLabel(permission)}을(를) 요청합니다.`,
    detail: '이 선택은 이 사이트에 대해 기억됩니다. 설정 → 브라우저에서 언제든 되돌릴 수 있습니다.'
  }
  const { response } =
    owner === null
      ? await dialog.showMessageBox(options)
      : await dialog.showMessageBox(owner, options)
  const granted = response === 1
  if (remember) {
    permissionsFor(partition)?.remember(origin, permission, granted ? 'granted' : 'denied')
  }
  return granted
}

export function hardenBrowsingSession(partition: string): void {
  if (hardenedBrowsingSessions.has(partition)) return
  hardenedBrowsingSessions.add(partition)

  const browsingSession = session.fromPartition(partition)
  installGestureSession(browsingSession)
  const persistent = partition.startsWith('persist:')
  // Inherit the identity configured once at app boot for every profile,
  // request and child window. Session UA overrides can diverge in popups.
  browsingSession.setPermissionRequestHandler(
    (webContents, permission, callback, details) => {
      const tier = permissionTier(permission)
      if (tier !== 'ask') {
        callback(tier === 'grant')
        return
      }
      const origin = originOf(
        details.requestingUrl !== '' && details.requestingUrl !== undefined
          ? details.requestingUrl
          : (webContents?.getURL() ?? '')
      )
      if (origin === null) {
        callback(false)
        return
      }
      const remembered = permissionsFor(partition)?.decisionFor(origin, permission) ?? null
      if (remembered !== null) {
        callback(remembered === 'granted')
        return
      }
      void askSitePermission(origin, permission, persistent, partition).then(callback)
    }
  )
  // SYNCHRONOUS — it cannot prompt. It answers from what the student already
  // decided and refuses the rest; the async request handler above is the only
  // place a question can be asked.
  browsingSession.setPermissionCheckHandler(
    (_webContents, permission, requestingOrigin) => {
      const tier = permissionTier(permission)
      if (tier === 'grant') return true
      if (tier === 'deny') return false
      const origin = originOf(requestingOrigin)
      if (origin === null) return false
      return permissionsFor(partition)?.decisionFor(origin, permission) === 'granted'
    }
  )
  // Physical devices are refused outright, so a page cannot even enumerate
  // them — the permission tiers alone would still let `requestDevice` show a
  // chooser that then denies.
  browsingSession.setDevicePermissionHandler(() => false)
  // Granting display-capture is necessary but NOT sufficient: without this,
  // getDisplayMedia() still rejects and the prompt the student just answered
  // means nothing.
  installDisplayMediaHandler(partition)
  // Native URL filtering keeps ordinary authentication, API and media requests
  // off this synchronous main-process round trip. The strict superset preserves
  // live setting changes; the callback still decides first-party exceptions.
  browsingSession.webRequest.onBeforeRequest(
    { urls: ['file://*/*', ...TRACKING_REQUEST_URLS, ...(isCleanBrowserAuthProbe() ? [] : YOUTUBE_NAVIGATION_REQUEST_URLS)] },
    (details, callback) => {
      const target = isCleanBrowserAuthProbe() ? details.url : googleAccountRequestUrl(browsingSession, details.webContents, details)
      if (target !== details.url) { callback({ redirectURL: target }); return }
      const cancel = details.url.startsWith('file:') || shouldBlockTrackingRequest({
        url: details.url,
        referrer: details.referrer,
        resourceType: details.resourceType
      }, getSettings().browser.trackingProtection)
      callback({ cancel })
    }
  )
  browsingSession.webRequest.onBeforeSendHeaders(
    { urls: ['http://*/*', 'https://*/*'] },
    (details, callback) => {
      callback({
        requestHeaders: privacyRequestHeaders(
          details.requestHeaders,
          getSettings().browser.doNotTrack
        )
      })
    }
  )
}

const popupLimiter = createPopupLimiter(() => Date.now())

/** One dialog per guest at a time — a page must not be able to spam them. */
const schemeAsksInFlight = new Set<number>()

/**
 * Tells the renderer, and the log, that something was refused.
 *
 * Every deny path used to be a bare `preventDefault()` with no output at all.
 * That is why diagnosing a broken portal meant reading this file: the app knew
 * exactly what it had blocked and told nobody.
 */
function noteBlocked(
  host: WebContents,
  kind: 'navigation' | 'popup' | 'scheme',
  url: string,
  reason: string
): void {
  console.warn(`[browser] blocked ${kind}: ${reason} — ${requestingOriginOf(url)}`)
  if (host.isDestroyed()) return
  host.send('browser:blocked', { kind, url, reason })
}

function notePopupBlocked(
  webContents: WebContents,
  url: string,
  reason: 'burst' | 'limit' | 'policy'
): void {
  const host = navigationHost(webContents)
  const origin = originOf(webContents.getURL()) ?? ''
  noteBlocked(host, 'popup', url, reason)
  if (!host.isDestroyed()) {
    host.send('browser:popup-blocked', {
    ...(isManagedBrowserPage(webContents.id) ? guestProfile(webContents.id) : {}), url, origin, reason })
  }
}

/** The hardened preferences every real popup window gets. */
export function popupWebPreferences(
  partition = BROWSING_PARTITION
): Electron.WebPreferences {
  return {
    partition,
    nodeIntegration: false,
    // Electron gates session frame preloads on this flag too. Keep Node out of
    // page worlds with the explicit sandbox and isolation below; only the
    // gesture preload is registered for this browsing session.
    nodeIntegrationInSubFrames: true,
    nodeIntegrationInWorker: false,
    contextIsolation: true,
    sandbox: true,
    webSecurity: true,
    webviewTag: false,
    backgroundThrottling: true,
    // A blob: PDF popup is a common 고지서 path; without this it downloads.
    plugins: true
  }
}

/**
 * Offers to hand a custom scheme to the operating system.
 *
 * A NATIVE dialog, not an in-app overlay, and deliberately so: a guest can
 * draw a pixel-perfect copy of any Bandal surface inside its own rect and
 * train the student to press 열기. A macOS sheet is one thing web content
 * cannot forge. It also serialises for free — a page cannot stack them.
 */
async function offerExternalScheme(
  host: WebContents,
  guest: WebContents,
  url: string
): Promise<void> {
  const verdict = classifyExternalScheme(url)
  if (verdict.kind === 'blocked') {
    noteBlocked(host, 'scheme', url, verdict.reason)
    return
  }
  if (schemeAsksInFlight.has(guest.id)) return
  schemeAsksInFlight.add(guest.id)
  try {
    const owner = BrowserWindow.fromWebContents(host)
    const origin = requestingOriginOf(guest.getURL())
    // mailto:/tel: get a quiet one-liner. Putting a 교수님 이메일 링크 behind
    // the same red-toned "모르는 프로그램이라면 취소하십시오" box as an
    // unknown installer is how a student learns to ignore that box.
    const everyday = verdict.kind === 'everyday'
    const options: Electron.MessageBoxOptions = everyday
      ? {
          type: 'question',
          noLink: true,
          buttons: ['취소', '열기'],
          defaultId: 1,
          cancelId: 0,
          message: `${externalSchemeDisplay(url)} 을(를) 여시겠습니까?`,
          detail: `${origin} 에서 요청했습니다.`
        }
      : {
          type: 'warning',
          noLink: true,
          buttons: ['취소', '열기'],
          defaultId: 0,
          cancelId: 0,
          message: '이 페이지가 다른 프로그램을 열려고 합니다.',
          detail:
            `요청한 사이트: ${origin}\n` +
            `실행할 주소: ${externalSchemeDisplay(url)}\n\n` +
            '모르는 프로그램이라면 취소하십시오.'
        }
    const { response } =
      owner === null
        ? await dialog.showMessageBox(options)
        : await dialog.showMessageBox(owner, options)
    if (response !== 1) return
    try {
      await shell.openExternal(url)
    } catch {
      // No registered handler — the usual case for an uninstalled Korean
      // plugin. Silence here is how you get "눌렀는데 아무 일도 없어요".
      if (!host.isDestroyed()) {
        host.send('browser:external-scheme', { url, origin, outcome: 'no-handler' })
      }
    }
  } finally {
    schemeAsksInFlight.delete(guest.id)
  }
}

function certificateLabel(certificate: Electron.Certificate): string {
  const name = certificate.subjectName !== '' ? certificate.subjectName : certificate.subject?.commonName
  const issuer = certificate.issuerName !== '' ? certificate.issuerName : certificate.issuer?.commonName
  return `${name ?? '이름 없음'} · 발급 ${issuer ?? '알 수 없음'}`
}

async function confirmCertificate(
  host: WebContents,
  url: string,
  certificate: Electron.Certificate | undefined
): Promise<boolean> {
  if (certificate === undefined) return false
  const owner = BrowserWindow.fromWebContents(host)
  const options: Electron.MessageBoxOptions = {
    type: 'question',
    noLink: true,
    buttons: ['취소', '보내기'],
    defaultId: 0,
    cancelId: 0,
    message: `${requestingOriginOf(url)} 이(가) 인증서를 요구합니다.`,
    detail: `${certificateLabel(certificate)}\n\n보내면 이 인증서로 신원이 확인됩니다.`
  }
  const { response } =
    owner === null
      ? await dialog.showMessageBox(options)
      : await dialog.showMessageBox(owner, options)
  return response === 1
}

async function chooseCertificate(
  host: WebContents,
  url: string,
  list: Electron.Certificate[]
): Promise<Electron.Certificate | null> {
  const owner = BrowserWindow.fromWebContents(host)
  // Cancel first, so the default is never "assert an identity".
  const options: Electron.MessageBoxOptions = {
    type: 'question',
    noLink: true,
    buttons: ['취소', ...list.map(certificateLabel)],
    defaultId: 0,
    cancelId: 0,
    message: `${requestingOriginOf(url)} 이(가) 인증서를 요구합니다.`,
    detail: '어떤 인증서를 보낼지 고르십시오.'
  }
  const { response } =
    owner === null
      ? await dialog.showMessageBox(options)
      : await dialog.showMessageBox(owner, options)
  if (response === 0) return null
  return list[response - 1] ?? null
}

const navigationHosts = new WeakMap<WebContents, WebContents>()
const navigationPartitions = new WeakMap<WebContents, string>()
const policyAttached = new WeakSet<WebContents>()

function navigationHost(webContents: WebContents): WebContents {
  const registered = navigationHosts.get(webContents)
  if (registered !== undefined) return registered
  return BrowserWindow.fromWebContents(webContents)?.webContents ?? webContents
}

/**
 * Navigation, popup and browser-native prompt policies shared by webviews and
 * standalone site windows. Keeping this independent from a webview host lets
 * the mini player use the exact same main-frame and window.open guards.
 */
export function attachNavigationPolicies(
  webContents: WebContents,
  opts: { openInTab: (url: string) => void; partition?: string; createTab?: (options: Electron.BrowserWindowConstructorOptions, details: Electron.HandlerDetails) => WebContents }
): void {
  if (policyAttached.has(webContents)) return
  policyAttached.add(webContents)
  if (!browsingContext(webContents.id)) registerBrowsingContext(webContents.id)
  const rootId = browsingContext(webContents.id)!.rootId
  if (!isCleanBrowserAuthProbe()) attachEmbeddedAuthFallback(webContents, (status) => {
    const host = navigationHost(webContents)
    const targetId = isManagedBrowserPage(webContents.id) ? webContents.id : rootId
    const tabId = browsingContext(targetId)?.tabId
    if (!host.isDestroyed()) host.send('browser:external-auth', {
      ...status, webContentsId: targetId, sourceWebContentsId: webContents.id, ...(tabId ? { tabId } : {})
    } satisfies BrowserAuthEvent)
  })
  const navigationGuard = (event: ElectronEvent, url: string): void => {
    if (isNavigationAllowed(url)) return
    event.preventDefault()
    // `will-navigate` is main-frame only, so a subframe or ad cannot reach
    // this — the dialog is only ever offered for a top-level attempt.
    void offerExternalScheme(navigationHost(webContents), webContents, url)
  }
  webContents.on('will-navigate', navigationGuard)
  webContents.on('will-redirect', navigationGuard)
  webContents.on('will-navigate', (_event, url) => {
    if (!isCleanBrowserAuthProbe()) prepareGoogleAccountSiteNavigation(webContents, webContents.getURL(), url)
  })

  webContents.setWindowOpenHandler((details) => {
    const decision = decidePopup({
      openerUrl: webContents.getURL(),
      targetUrl: details.url
    })

    if (decision.kind === 'window') {
      const origin = originOf(webContents.getURL())
      const remembered = origin === null
        ? null
        : permissionsFor(opts.partition ?? BROWSING_PARTITION)?.decisionFor(origin, 'popups') ?? null
      if (
        remembered === 'denied' ||
        (getSettings().browser.popupBehavior === 'strict' && remembered !== 'granted')
      ) {
        notePopupBlocked(webContents, details.url, 'policy')
        return { action: 'deny' }
      }
      const admission = popupLimiter.admit(rootId)
      if (!admission.ok) {
        notePopupBlocked(webContents, details.url, admission.reason)
        return { action: 'deny' }
      }
      const size = popupWindowSize(decision.scope, details.features)
      return {
        action: 'allow',
        ...(opts.createTab ? { createWindow: (options: Electron.BrowserWindowConstructorOptions) => {
          try {
            const child = opts.createTab!(options, details)
            if (!isCleanBrowserAuthProbe()) prepareGoogleAccountSiteNavigation(child, webContents.getURL(), details.url, true)
            child.once('destroyed', () => popupLimiter.release(rootId))
            return child
          } catch (error) { popupLimiter.release(rootId); throw error }
        } } : {}),
        overrideBrowserWindowOptions: {
          width: size.width,
          height: size.height,
          // Chromium owns the child and preserves its opener and request body.
          autoHideMenuBar: true,
          webPreferences: popupWebPreferences(
            opts.partition ?? navigationPartitions.get(webContents) ?? BROWSING_PARTITION
          )
        }
      }
    }

    if (decision.kind === 'scheme') {
      void offerExternalScheme(
        navigationHost(webContents),
        webContents,
        details.url
      )
      return { action: 'deny' }
    }

    noteBlocked(navigationHost(webContents), 'popup', details.url, 'not-allowed')
    return { action: 'deny' }
  })

  webContents.on('did-create-window', (window) => {
    const child = window.webContents
    const host = navigationHost(webContents)
    const partition = opts.partition ?? navigationPartitions.get(webContents) ?? BROWSING_PARTITION
    registerBrowsingContext(child.id, webContents.id)
    inheritGuestProfile(child.id, webContents.id)
    inheritEmbeddedAuthSource(child, webContents)
    navigationHosts.set(child, host)
    navigationPartitions.set(child, partition)
    window.once('closed', () => popupLimiter.release(rootId))
    attachNavigationPolicies(child, { ...opts, partition })
    trackPopupDownload(window, webContents, host)
    child.once('destroyed', () => forgetGuestProfile(child.id))
  })

  /**
   * Client certificates (mTLS).
   *
   * Electron's default when this event is UNHANDLED is to silently use the
   * FIRST certificate in the list. So a 정부/공공 mTLS endpoint got whichever
   * one the keychain happened to enumerate first — a stale dev cert, an
   * expired one, someone else's — and then failed with an opaque server error
   * or, worse, authenticated as the wrong identity. On macOS the keychain
   * unlock prompt is attributed to "bandal", not to the site, so the student
   * has no idea what consented to what.
   *
   * Note this is the narrow mTLS case. 공동인증서(구 공인인증서) files under
   * ~/NPKI are not TLS client certs and never reach here — those are driven by
   * a native helper over a custom scheme (externalScheme.ts).
   */
  webContents.on('select-client-certificate', (event, url, list, callback) => {
    event.preventDefault()
    if (list.length === 0) return
    if (list.length === 1) {
      // Still worth confirming: this is an identity being asserted.
      void confirmCertificate(navigationHost(webContents), url, list[0]).then((ok) => {
        if (ok && list[0] !== undefined) callback(list[0])
      })
      return
    }
    void chooseCertificate(navigationHost(webContents), url, list).then((chosen) => {
      if (chosen !== null) callback(chosen)
    })
  })

  // HTTP Basic / Digest / NTLM / Negotiate. With NO listener Electron
  // CANCELS the request — which is why 도서관 프록시 and older 학사 시스템
  // rendered a blank rect with no prompt and no way in.
  webContents.on('login', (event, _details, authInfo, callback) => {
    event.preventDefault()
    void resolveAuthPrompt(
      {
        isProxy: authInfo.isProxy,
        host: authInfo.host,
        port: authInfo.port,
        realm: authInfo.realm,
        scheme: authInfo.scheme
      },
      { ask: askForCredentials }
    ).then((result) => {
      if (result === null) callback()
      else callback(result.username, result.password)
    })
  })

  webContents.once('destroyed', () => {
    if (rootId === webContents.id) popupLimiter.forget(rootId)
    forgetBrowsingContext(webContents.id)
    navigationHosts.delete(webContents)
    navigationPartitions.delete(webContents)
  })

  /**
   * `beforeunload`.
   *
   * Electron's contract is inverted from the obvious reading: with NO
   * listener the unload is CANCELLED and no dialog is shown, so a 수강신청 or
   * 성적입력 page that sets `onbeforeunload` made every link and every ⌘R do
   * nothing at all. The page looked frozen and nothing was logged.
   */
  webContents.on('will-prevent-unload', (event) => {
    confirmPageUnload(webContents, event, navigationHost(webContents))
  })
}

/**
 * Policies that only make sense for an embedded webview: replay app/browser
 * shortcuts in its host and harden real popup children created by that guest.
 */
export function attachGuestInput(
  host: WebContents,
  guest: WebContents,
  partition = BROWSING_PARTITION
): void {
  navigationHosts.set(guest, host)
  navigationPartitions.set(guest, partition)

  // [M6-A] ⌘T/⌘W keep working while the guest has keyboard focus: intercept
  // them before the guest page sees the chord and replay them in the host.
  guest.on('before-input-event', (event, input) => {
    const settings = getSettings()
    const action = passthroughShortcut(
      input,
      resolveKeymap(settings.keybindings),
      settings.shortcutPriority
    )
    if (action !== null && !host.isDestroyed()) {
      event.preventDefault()
      const payload: ShortcutPassthrough = { action, webContentsId: guest.id }
      host.send('shortcut:passthrough', payload)
    }
  })
}

/**
 * Fail-closed webview hardening for one window:
 *  - `will-attach-webview` denies any guest outside the browsing-partition
 *    allowlist and forces sandboxed, isolated, preload-free webPreferences
 *  - `did-attach-webview` installs the navigation + popup policies
 */
export function hardenWindowWebviews(win: BrowserWindow): void {
  hardenBrowsingSession(BROWSING_PARTITION)
  hardenBrowsingSession(PRIVATE_BROWSING_PARTITION)

  const host = win.webContents
  if (process.platform === 'darwin') {
    win.on('swipe', (_event, direction) => {
      forwardBrowserSwipe(
        host,
        webContents.getFocusedWebContents(),
        direction
      )
    })
  }
  host.on('will-attach-webview', (event, webPreferences, params) => {
    if (
      preparePluginPanelWebview(
        params,
        webPreferences as Record<string, unknown>
      )
    ) {
      return
    }
    if (!isAllowedAttach(params)) {
      event.preventDefault()
      return
    }
    // The <webview> preload attribute arrives via params — strip it too.
    delete (params as Record<string, unknown>)['preload']
    sanitizeGuestWebPreferences(
      webPreferences as Record<string, unknown>,
      typeof params.partition === 'string' ? params.partition : BROWSING_PARTITION
    )
  })

  host.on('did-attach-webview', (_event, guest) => {
    if (attachPluginPanelGuest(guest)) return
    const partition = guest.session === session.fromPartition(PRIVATE_BROWSING_PARTITION)
      ? PRIVATE_BROWSING_PARTITION
      : BROWSING_PARTITION
    const openInTab = (url: string): void => {
      if (host.isDestroyed()) return
      const payload: BrowserOpenUrl = {
        url,
        ...(partition === PRIVATE_BROWSING_PARTITION ? { isPrivate: true } : {})
      }
      host.send('browser:open-url', payload)
    }
    attachNavigationPolicies(guest, { openInTab, partition })
    attachGuestInput(host, guest, partition)
  })
}
