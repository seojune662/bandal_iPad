import { installSwipeNavigation } from './swipeNavigation'
import { ensureProfileSession, prepareProfileSession, profilePartition, registerGuestProfile, forgetGuestProfile, resetBrowserProfileQuit } from './profiles'
import { randomUUID } from 'node:crypto'
import { app, BrowserWindow, WebContentsView, dialog } from 'electron'
import type { WebContents, IpcMainInvokeEvent } from 'electron'
import type { BrowserPageAction, BrowserPageState, BrowserPageEvent } from '../../../shared/types/browserNative'
import { attachGuestInput, attachNavigationPolicies, popupWebPreferences } from './hardenWebviews'
import { isNavigationAllowed } from './webviewPolicy'
import { browsingContext, registerBrowsingContext, setBrowsingCourse } from './browsingContext'
import { registerManagedPage, forgetManagedPage } from './managedPages'
import { trackTabDownload } from './popupLifecycle'
import { closePage } from './pageClose'
import { browserAuthDocumentId, inheritEmbeddedAuthSource } from './embeddedAuth'
import { isCleanBrowserAuthProbe } from './authProbe'
import { applyDeferredGoogleAccountNavigation, rememberGoogleAccountNavigation, googleAccountNavigationUrl } from './googleAccountNavigation'

interface Tab {
  tabId: string
  host: BrowserWindow
  view: WebContentsView
  switching?: boolean
  parentId?: string
  adopted: boolean
  partition: string
  profileId: string
  isPrivate: boolean
  ownershipRevision?: number
  bounds?: Electron.Rectangle | null
  preview?: Promise<string | null>
  pendingAccountNavigation?: { url: string; generation: number }
}
const hosts = new Set<WebContents>()
const occludedHosts = new Set<WebContents>()
const tabs = new Map<string, Tab>()
const responseCodes = new WeakMap<WebContents, number>()
const stateRevisions = new WeakMap<WebContents, number>()
const closedSiteTabs = new Set<string>()
const quitCancelledListeners = new Set<() => void>()
let quitRequested = false
app.on('before-quit', () => { quitRequested = true })

export function onBrowserQuitCancelled(listener: () => void): () => void {
  quitCancelledListeners.add(listener)
  return () => quitCancelledListeners.delete(listener)
}

export function registerBrowserHost(host: BrowserWindow): void {
  const hostContents = host.webContents
  hosts.add(hostContents)
  let closing = false
  host.on('close', event => {
    const pages = [...tabs.values()].filter(tab => tab.host === host)
    if (!pages.length) return
    event.preventDefault()
    if (closing) return
    closing = true
    // Closing the application keeps workspace descriptors for next launch.
    // Only an interrupted close should remove pages that already accepted.
    for (const tab of pages) tab.switching = true
    void (async () => {
      for (const tab of pages) {
        if (!await closePage(tab.view.webContents, 'tab')) {
          quitRequested = false
          resetBrowserProfileQuit()
          for (const listener of quitCancelledListeners) listener()
          for (const page of pages) {
            if (!page.view.webContents.isDestroyed()) page.switching = false
            else if (!hostContents.isDestroyed()) hostContents.send('browser:close-tab', { tabId: page.tabId })
          }
          return
        }
      }
      // preventDefault also cancels app.quit(), which must be resumed on macOS
      // after the browser pages have accepted their unload requests.
      if (quitRequested) app.quit()
      else if (!host.isDestroyed()) host.close()
    })().finally(() => { closing = false })
  })
  host.once('closed', () => {
    hosts.delete(hostContents)
    occludedHosts.delete(hostContents)
    for (const tab of [...tabs.values()]) if (tab.host === host) destroy(tab)
  })
  host.webContents.on('render-process-gone', () => {
    occludedHosts.delete(hostContents)
    for (const tab of [...tabs.values()]) if (tab.host === host) destroy(tab)
  })
}
function owner(event: IpcMainInvokeEvent): BrowserWindow {
  if (!hosts.has(event.sender) || event.senderFrame !== event.sender.mainFrame) throw new Error('Invalid browser host')
  const host = BrowserWindow.fromWebContents(event.sender)
  if (!host) throw new Error('Browser host closed')
  return host
}
function owned(event: IpcMainInvokeEvent, id: string): Tab {
  const host = owner(event), tab = tabs.get(id)
  if (!tab || tab.host !== host || tab.view.webContents.isDestroyed()) throw new Error('Browser tab closed')
  return tab
}
function state(wc: WebContents): BrowserPageState {
  const stateRevision = (stateRevisions.get(wc) ?? 0) + 1
  stateRevisions.set(wc, stateRevision)
  return { id: wc.id, stateRevision, authDocumentId: browserAuthDocumentId(wc), url: wc.getURL(), title: wc.getTitle(), loading: wc.isLoadingMainFrame(), httpStatus: responseCodes.get(wc) ?? 0,
    canGoBack: wc.navigationHistory.canGoBack(), canGoForward: wc.navigationHistory.canGoForward() }
}
function destroy(tab: Tab): void {
  tabs.delete(tab.tabId)
  if (!tab.host.isDestroyed()) tab.host.contentView.removeChildView(tab.view)
  if (!tab.view.webContents.isDestroyed()) tab.view.webContents.close()
}
function accountPageVisible(tab: Tab): boolean {
  return tab.view.getVisible() && !tab.host.isDestroyed() && tab.host.isVisible() && !tab.host.isMinimized()
}
function applyPendingAccountNavigation(tab: Tab): void {
  const pending = tab.pendingAccountNavigation
  if (!pending) return
  const wc = tab.view.webContents
  if (isCleanBrowserAuthProbe() || wc.isDestroyed() || wc.getURL() !== pending.url) {
    delete tab.pendingAccountNavigation
    return
  }
  if (!accountPageVisible(tab)) return
  delete tab.pendingAccountNavigation
  applyDeferredGoogleAccountNavigation(wc.session, pending.url, pending.generation)
}
function install(tab: Tab, parent?: Tab): void {
  const wc = tab.view.webContents, host = tab.host.webContents
  if (parent) tab.parentId = parent.tabId
  tabs.set(tab.tabId, tab)
  registerManagedPage(wc.id)
  registerGuestProfile(wc.id, tab.profileId, tab.isPrivate)
  if (parent) inheritEmbeddedAuthSource(wc, parent.view.webContents)
  registerBrowsingContext(wc.id, parent?.view.webContents.id)
  setBrowsingCourse(wc.id, tab.tabId, parent ? browsingContext(parent.view.webContents.id)?.courseId ?? null : null)
  tab.view.setVisible(false)
  tab.host.contentView.addChildView(tab.view)
  attachGuestInput(host, wc, tab.partition)
  installSwipeNavigation(wc, () => !tab.host.isDestroyed() && tab.host.isVisible() && !tab.host.isMinimized() && tab.view.getVisible())
  attachNavigationPolicies(wc, {
    partition: tab.partition,
    openInTab: (url) => host.send('browser:open-url', { url }),
    createTab: (options, details) => {
      // Returning this WebContents lets Chromium perform its ORIGINAL request,
      // including POST/referrer/opener/frame name. Never loadURL(details.url).
      // Deferred background links may pass a null webContents option. The
      // WebContentsView constructor accepts the key only for an actual page.
      const original = (options as { webContents?: WebContents }).webContents
      const child: Tab = { tabId: randomUUID(), host: tab.host, partition: tab.partition, profileId: tab.profileId, isPrivate: tab.isPrivate,
        adopted: true, view: new WebContentsView({ ...(original ? { webContents: original } : {}), webPreferences: {
          ...options.webPreferences, ...popupWebPreferences(tab.partition)
        } }) }
      install(child, tab)
      if (!original && details.disposition === 'background-tab') {
        const body = details.postBody
        void child.view.webContents.loadURL(details.url, {
          httpReferrer: details.referrer,
          ...(body ? { postData: body.data, extraHeaders: `Content-Type: ${body.contentType}${body.boundary ? `; boundary=${body.boundary}` : ''}` } : {})
        }).catch(() => undefined)
      }
      host.send('browser:open-url', { tabId: child.tabId, url: details.url,
        courseId: browsingContext(wc.id)?.courseId ?? null, openerTabId: tab.tabId,
        isPrivate: tab.isPrivate, profileId: tab.profileId,
        background: details.disposition === 'background-tab' })
      return child.view.webContents
    }
  })
  const send = (name: string, detail: Record<string, unknown> = {}): void => {
    if (!host.isDestroyed() && !wc.isDestroyed()) host.send('browser:page-event', {
      tabId: tab.tabId, name, detail, state: state(wc)
    } satisfies BrowserPageEvent)
  }
  wc.on('dom-ready', () => { applyPendingAccountNavigation(tab); send('dom-ready') })
  wc.on('focus', () => {
    if (tab.view.getVisible()) send('focus', { webContentsId: wc.id })
  })
  // Clicking an already-focused native page does not emit another focus event.
  // Pointer input still selects its workspace pane, without consuming the click.
  wc.on('before-mouse-event', (_event, mouse) => {
    if (mouse.type === 'mouseDown' && tab.view.getVisible()) send('focus', { webContentsId: wc.id })
  })
  wc.on('did-start-loading', () => send('did-start-loading'))
  wc.on('did-stop-loading', () => { applyPendingAccountNavigation(tab); send('did-stop-loading') })
  wc.on('did-finish-load', () => send('did-finish-load'))
  const rememberAccount = (url: string, successful = true): void => {
    delete tab.pendingAccountNavigation
    if (isCleanBrowserAuthProbe()) return
    const visible = accountPageVisible(tab)
    const generation = rememberGoogleAccountNavigation(wc.session, url, successful && visible)
    if (successful && !visible && generation !== null) tab.pendingAccountNavigation = { url, generation }
  }
  wc.on('did-start-navigation', (details, _url, isInPlace, isMainFrame) => {
    if ((details.isMainFrame ?? isMainFrame) && !(details.isSameDocument ?? isInPlace)) delete tab.pendingAccountNavigation
  })
  wc.on('did-navigate', (_event, url, httpResponseCode) => {
    rememberAccount(url, httpResponseCode >= 200 && httpResponseCode < 400)
    responseCodes.set(wc, httpResponseCode); send('did-navigate', { url, httpResponseCode })
  })
  wc.on('did-navigate-in-page', (_event, url, isMainFrame) => {
    if (isMainFrame) rememberAccount(url, (responseCodes.get(wc) ?? 0) < 400)
    send('did-navigate-in-page', { url, isMainFrame })
  })
  wc.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
    if (isMainFrame) delete tab.pendingAccountNavigation
    send('did-fail-load', { errorCode, errorDescription, validatedURL, isMainFrame })
  })
  wc.on('page-title-updated', (_event, title) => send('page-title-updated', { title }))
  wc.on('page-favicon-updated', (_event, favicons) => send('page-favicon-updated', { favicons }))
  wc.on('found-in-page', (_event, result) => send('found-in-page', { result }))
  wc.on('render-process-gone', (_event, details) => send('render-process-gone', { reason: details.reason }))
  wc.on('console-message', (_event, _level, message) => {
    // Only our opt-in bridge messages cross IPC; page logs may include secrets.
    if (message.startsWith('__bandal')) send('console-message', { message: message })
  })
  wc.on('context-menu', (_event, p) => send('context-menu', { params: {
    x: p.x, y: p.y, linkURL: p.linkURL, srcURL: p.srcURL, mediaType: p.mediaType,
    selectionText: p.selectionText, isEditable: p.isEditable, pageURL: p.pageURL
  } }))
  wc.on('content-bounds-updated', (event) => event.preventDefault())
  wc.once('destroyed', () => {
    const requestedByPage = tabs.get(tab.tabId) === tab
    forgetManagedPage(wc.id)
    forgetGuestProfile(wc.id)
    if (requestedByPage) {
      tabs.delete(tab.tabId)
      if (tab.adopted && !tab.switching) {
        closedSiteTabs.add(tab.tabId)
        if (closedSiteTabs.size > 500) closedSiteTabs.delete(closedSiteTabs.values().next().value!)
      }
    }
    if (!tab.host.isDestroyed()) tab.host.contentView.removeChildView(tab.view)
    if (requestedByPage && !tab.switching && !host.isDestroyed()) host.send('browser:close-tab', { tabId: tab.tabId })
  })
  if (parent) trackTabDownload(wc, () => wc.close())
}
export async function createBrowserPage(event: IpcMainInvokeEvent, req: { tabId: string; isPrivate: boolean; courseId: string | null; profileId?: string }) {
  const host = owner(event)
  const profileId = req.profileId ?? 'default'
  await prepareProfileSession(profileId, req.isPrivate)
  if (host.isDestroyed()) throw new Error('Browser host closed')
  if (closedSiteTabs.has(req.tabId)) throw new Error('Browser tab already closed')
  const existing = tabs.get(req.tabId)
  if (existing) {
    if (existing.host !== host || existing.isPrivate !== req.isPrivate || existing.profileId !== profileId) throw new Error('Invalid browser tab owner')
    return { state: state(existing.view.webContents), adopted: true }
  }
  const partition = profilePartition(profileId, req.isPrivate)
  const tab: Tab = { tabId: req.tabId, host, partition, profileId, isPrivate: req.isPrivate, adopted: false,
    view: new WebContentsView({ webPreferences: popupWebPreferences(partition) }) }
  install(tab)
  setBrowsingCourse(tab.view.webContents.id, tab.tabId, req.courseId)
  return { state: state(tab.view.webContents), adopted: false }
}
/** Placement changes never recreate a page or navigate it. */
export function setBrowserPageCourse(event: IpcMainInvokeEvent, req: {
  tabId: string; courseId: string | null; expectedWebContentsId: number; revision: number
}): { ok: boolean } {
  const tab = owned(event, req.tabId)
  if (!Number.isSafeInteger(req.revision) || req.revision < 1) throw new Error('Invalid browser ownership revision')
  if (tab.view.webContents.id !== req.expectedWebContentsId || req.revision <= (tab.ownershipRevision ?? 0)) return { ok: false }
  tab.ownershipRevision = req.revision
  setBrowsingCourse(tab.view.webContents.id, tab.tabId, req.courseId)
  return { ok: true }
}
export async function setBrowserPageBounds(event: IpcMainInvokeEvent, req: { tabId: string; bounds: Electron.Rectangle | null; preview?: boolean }): Promise<{ snapshot: string | null }> {
  const tab = owned(event, req.tabId)
  const b = req.bounds, factor = event.sender.getZoomFactor()
  if (!b || Object.values(b).some(v => !Number.isFinite(v)) || b.width <= 0 || b.height <= 0) {
    tab.bounds = null
    if (req.preview) capturePreview(tab, true)
    tab.view.setVisible(false)
    return { snapshot: req.preview ? await (tab.preview ?? null) : null }
  }
  const [hostWidth = 0, hostHeight = 0] = tab.host.getContentSize()
  const x = Math.max(0, Math.round(b.x * factor)), y = Math.max(0, Math.round(b.y * factor))
  tab.bounds = { x, y, width: Math.max(0, Math.min(hostWidth - x, Math.round(b.width * factor))),
    height: Math.max(0, Math.min(hostHeight - y, Math.round(b.height * factor))) }
  applyPageVisibility(tab)
  return { snapshot: null }
}

function applyPageVisibility(tab: Tab): void {
  const bounds = tab.bounds
  if (!bounds || bounds.width <= 0 || bounds.height <= 0 || occludedHosts.has(tab.host.webContents)) {
    if (occludedHosts.has(tab.host.webContents)) capturePreview(tab)
    tab.view.setVisible(false)
    return
  }
  delete tab.preview
  tab.view.setBounds(bounds)
  tab.view.setVisible(true)
  applyPendingAccountNavigation(tab)
}

function capturePreview(tab: Tab, allowHidden = false): void {
  const page = tab.view.webContents
  if (page.isDestroyed() || (!tab.view.getVisible() && (!allowHidden || tab.preview))) return
  let captured: Promise<Electron.NativeImage>
  try { captured = page.capturePage(undefined, { stayHidden: true }) }
  catch { delete tab.preview; return }
  const preview = captured.then(image => image.isEmpty() ? null : image.toDataURL())
    .catch(() => null).then(snapshot => {
      // A failed hidden capture can be retried on the next request. Do not clear
      // a newer preview that started after this page was shown again.
      if (snapshot === null && tab.preview === preview) delete tab.preview
      return snapshot
    })
  tab.preview = preview
}

export function setBrowserHostOccluded(event: IpcMainInvokeEvent, occluded: boolean): { ok: true } {
  const host = owner(event)
  const hadPageFocus = occluded && [...tabs.values()].some(tab => tab.host === host && !tab.view.webContents.isDestroyed() && tab.view.webContents.isFocused())
  if (occluded) occludedHosts.add(host.webContents)
  else occludedHosts.delete(host.webContents)
  for (const tab of tabs.values()) if (tab.host === host && !tab.view.webContents.isDestroyed()) applyPageVisibility(tab)
  if (hadPageFocus) host.webContents.focus()
  return { ok: true }
}
export function destroyBrowserPage(event: IpcMainInvokeEvent, tabId: string, expectedWebContentsId?: number): void {
  const host = owner(event), tab = tabs.get(tabId)
  if (tab?.host === host && (expectedWebContentsId === undefined || tab.view.webContents.id === expectedWebContentsId)) destroy(tab)
}
export async function browserPageAction(event: IpcMainInvokeEvent, req: { tabId: string; action: BrowserPageAction; args: unknown[] }): Promise<unknown> {
  const wc = owned(event, req.tabId).view.webContents, a = req.args
  switch (req.action) {
    case 'loadURL':
      if (typeof a[0] !== 'string' || !isNavigationAllowed(a[0])) throw new Error('Invalid navigation')
      return wc.loadURL(isCleanBrowserAuthProbe() ? a[0] : googleAccountNavigationUrl(wc.session, a[0]))
    case 'goBack': if (wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack(); return
    case 'goForward': if (wc.navigationHistory.canGoForward()) wc.navigationHistory.goForward(); return
    case 'reload': return wc.reload()
    case 'reloadIgnoringCache': return wc.reloadIgnoringCache()
    case 'stop': return wc.stop()
    case 'setZoomLevel': return wc.setZoomLevel(Number(a[0]))
    case 'findInPage': return wc.findInPage(String(a[0]), (a[1] ?? {}) as Electron.FindInPageOptions)
    case 'stopFindInPage': return wc.stopFindInPage(a[0] as 'clearSelection')
    case 'executeJavaScript':
      if (isCleanBrowserAuthProbe()) throw new Error('Page scripts are disabled in the clean authentication probe')
      return wc.executeJavaScript(String(a[0]), a[1] === true)
    case 'downloadURL': if (!isNavigationAllowed(String(a[0]))) throw new Error('Invalid download'); return wc.downloadURL(String(a[0]))
    case 'copy': return wc.copy()
    case 'cut': return wc.cut()
    case 'paste': return wc.paste()
    case 'selectAll': return wc.selectAll()
    case 'undo': return wc.undo()
    case 'redo': return wc.redo()
    case 'copyImageAt': return wc.copyImageAt(Number(a[0]), Number(a[1]))
    case 'openDevTools': return wc.openDevTools({ mode: 'detach' })
    case 'printToPDF': return wc.printToPDF((a[0] ?? {}) as Electron.PrintToPDFOptions)
    case 'focus': return wc.focus()
    default: throw new Error('Unsupported browser action')
  }
}

/** A close request is completed before the renderer removes the corresponding tab. */
export async function prepareBrowserPageClose(event: IpcMainInvokeEvent, tabId: string): Promise<{ allowed: boolean }> {
  owner(event)
  if (!tabs.has(tabId)) return { allowed: true }
  const tab = owned(event, tabId)
  tab.switching = true
  const allowed = await closePage(tab.view.webContents, 'tab')
  if (!allowed) tab.switching = false
  return { allowed }
}

/** The original page survives a cancelled profile switch. */
export async function prepareProfileSwitch(event: IpcMainInvokeEvent, tabId: string): Promise<{ allowed: boolean }> {
  owner(event)
  if (!tabs.has(tabId)) return { allowed: true }
  const tab = owned(event, tabId)
  const descendants = (id: string): Tab[] => [...tabs.values()].filter(t => t.parentId === id).flatMap(t => [...descendants(t.tabId), t])
  const children = descendants(tabId)
  if (children.length && dialog.showMessageBoxSync(tab.host, { type: 'question', message: '연결된 로그인·팝업 탭을 닫고 프로필을 전환할까요?', detail: '작성 중인 내용과 로그인 진행 상태는 새 프로필로 옮겨지지 않습니다.', buttons: ['취소', '전환'], defaultId: 0, cancelId: 0 }) !== 1) return { allowed: false }
  // Descendants close first so their cancellation never destroys the original page.
  for (const child of children) if (!await closePage(child.view.webContents, 'profile')) return { allowed: false }
  tab.switching = true
  const allowed = await closePage(tab.view.webContents, 'profile')
  if (!allowed) tab.switching = false
  return { allowed }
}

export function browserSessionForTab(event: IpcMainInvokeEvent, tabId?: string): Electron.Session {
  return tabId ? owned(event, tabId).view.webContents.session : ensureProfileSession()
}
