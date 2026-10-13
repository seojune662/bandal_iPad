import { ipcMain, nativeTheme, type Session, type WebContents, type WebFrameMain } from 'electron'
import { join } from 'node:path'
import { getSettings } from '../../settingsStore'
import { isManagedBrowserPage } from './managedPages'
import { resolveThemeId } from '../../../shared/theme'
import { isCleanBrowserAuthProbe } from './authProbe'

const targets = new WeakMap<WebContents, () => boolean>()
let registered = false

function availablePage(wc: WebContents): boolean {
  return !wc.isDestroyed() && isManagedBrowserPage(wc.id) && (targets.get(wc)?.() ?? false)
}

function liveFrame(frame: WebFrameMain | null): boolean {
  // A queued message can outlive its document during navigation or tab closure.
  return frame !== null && !frame.isDestroyed() && !frame.detached
}

export function installGestureSession(session: Session): void {
  if (isCleanBrowserAuthProbe()) return
  session.registerPreloadScript({ id: 'bandal-browser-gestures', type: 'frame', filePath: join(__dirname, '../preload/browserGesture.js') })
  if (registered) return
  registered = true
  ipcMain.handle('browser-gesture:state', event => {
    const wc = event.sender
    if (!liveFrame(event.senderFrame) || !availablePage(wc)) return { canBack: false, canForward: false, enabled: false }
    const settings = getSettings()
    return {
      canBack: wc.navigationHistory.canGoBack(),
      canForward: wc.navigationHistory.canGoForward(),
      enabled: settings.browser.swipeNavigation,
      theme: resolveThemeId(settings.theme, nativeTheme.shouldUseDarkColors)
    }
  })
  ipcMain.on('browser-gesture:navigate', (event, action: unknown) => {
    if (liveFrame(event.senderFrame)) navigateBySwipe(event.sender, action)
  })
}

export function installSwipeNavigation(wc: WebContents, isVisible: () => boolean): void {
  targets.set(wc, isVisible)
  wc.once('destroyed', () => targets.delete(wc))
}

export function navigateBySwipe(wc: WebContents, action: unknown): void {
  if (!availablePage(wc) || !getSettings().browser.swipeNavigation) return
  // The preload commits once at the end of each gesture. A fixed cooldown here
  // also discarded separate, deliberate swipes made in quick succession.
  if (action === 'back' && wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack()
  if (action === 'forward' && wc.navigationHistory.canGoForward()) wc.navigationHistory.goForward()
}
