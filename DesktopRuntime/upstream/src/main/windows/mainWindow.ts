import { registerBrowserHost } from '../features/browser/nativeTabs'
import { app, BrowserWindow, nativeTheme, shell } from 'electron'
import { join } from 'node:path'
import {
  resolveWindowBackground as resolveThemeWindowBackground,
  resolveWindowSymbolColor
} from '../../shared/theme'
import type { Settings } from '../../shared/types/settings'
import { hardenWindowWebviews } from '../features/browser'
import { getSettings } from '../settingsStore'
import {
  externalUrlScheme,
  normalizeAllowedExternalUrl
} from './externalUrlPolicy'
import { createWindowStateStore } from './windowBounds'
import { browserAuthProbeArguments, getBrowserAuthProbeIdentity, getBrowserAuthProbeMode } from '../features/browser/authProbe'

let mainWindow: BrowserWindow | null = null
const mainWindowClosedListeners = new Set<() => void>()
const MIN_WIDTH = 1024
const MIN_HEIGHT = 640

/**
 * Repairs macOS app presence after a floating panel and reveals the main
 * window. `setVisibleOnAllWorkspaces` used to let Electron change the whole
 * process into a UIElement application, which has no Dock or ⌘Tab entry.
 */
export function ensureRegularAppPresence(): void {
  if (process.platform !== 'darwin') return
  const dock = app.dock
  if (!dock) return

  app.setActivationPolicy('regular')
  if (!dock.isVisible()) {
    void dock.show().catch((error: unknown) => {
      console.warn('[window] Dock 아이콘을 복구하지 못했습니다.', error)
    })
  }
}

export function revealMainWindow(win: BrowserWindow): void {
  if (win.isDestroyed()) return
  ensureRegularAppPresence()
  if (win.isMinimized()) win.restore()
  win.show()
  if (process.platform === 'darwin') app.focus({ steal: true })
  win.focus()
}

/** Painted before any CSS loads, so it must track the theme's --bg-app
 * exactly (src/shared/theme.ts) or launch flashes the wrong color. */
export function resolveWindowBackground(): string {
  const { theme, palette } = getSettings()
  return resolveThemeWindowBackground(
    theme,
    palette,
    nativeTheme.shouldUseDarkColors
  )
}

function resolveTitleBarOverlayColors(
  settings: Pick<Settings, 'theme' | 'palette'>,
  prefersDark: boolean
): { color: string; symbolColor: string } {
  return {
    color: resolveThemeWindowBackground(
      settings.theme,
      settings.palette,
      prefersDark
    ),
    symbolColor: resolveWindowSymbolColor(settings.theme, prefersDark)
  }
}

export function refreshTitleBarOverlay(
  win: BrowserWindow,
  settings: Pick<Settings, 'theme' | 'palette'>,
  prefersDark: boolean
): void {
  if (process.platform !== 'win32') return
  win.setTitleBarOverlay(resolveTitleBarOverlayColors(settings, prefersDark))
}

/** Subscribes to the main window lifetime without taking ownership of it. */
export function onMainWindowClosed(cb: () => void): () => void {
  mainWindowClosedListeners.add(cb)
  return () => mainWindowClosedListeners.delete(cb)
}

export function createMainWindow(): BrowserWindow {
  if (mainWindow !== null && !mainWindow.isDestroyed()) {
    revealMainWindow(mainWindow)
    return mainWindow
  }

  const windowStateStore = createWindowStateStore({
    file: join(app.getPath('userData'), 'window-state.json'),
    minWidth: MIN_WIDTH,
    minHeight: MIN_HEIGHT
  })
  const windowState = windowStateStore.read()

  mainWindow = new BrowserWindow({
    width: windowState.bounds?.width ?? 1280,
    height: windowState.bounds?.height ?? 800,
    ...(windowState.bounds !== null
      ? { x: windowState.bounds.x, y: windowState.bounds.y }
      : {}),
    minWidth: MIN_WIDTH,
    minHeight: MIN_HEIGHT,
    show: false,
    // macOS: traffic lights inset into our chrome. Windows: frameless + native
    // caption buttons via titleBarOverlay — without it there are NO window
    // controls at all (min/max/close), which shipped broken through v0.12.x.
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'hidden',
    ...(process.platform === 'win32'
      ? {
          titleBarOverlay: {
            ...resolveTitleBarOverlayColors(
              getSettings(),
              nativeTheme.shouldUseDarkColors
            ),
            // Matches --chrome-height (2.75rem) so the caption buttons align
            // with the tab strip row.
            height: 44
          }
        }
      : {}),
    backgroundColor: resolveWindowBackground(),
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      additionalArguments: browserAuthProbeArguments(),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // M3-F embedded browser tabs. Guests are locked down fail-closed by
      // hardenWindowWebviews (partition allowlist, forced sandbox, no preload).
      webviewTag: true
    }
  })

  // Must be attached before the renderer loads so no webview can slip past.
  hardenWindowWebviews(mainWindow)
  registerBrowserHost(mainWindow)
  const win = mainWindow
  const probeMode = getBrowserAuthProbeMode()
  if (probeMode) {
    const identity = getBrowserAuthProbeIdentity()
    const title = `Bandal 인증 비교 — ${probeMode}${identity === 'native' ? ' / native identity' : ''}`
    win.setTitle(title)
    win.on('page-title-updated', event => { event.preventDefault(); win.setTitle(title) })
  }
  const publishWindowState = (fullscreen: boolean): void => {
    if (!win.isDestroyed() && !win.webContents.isDestroyed()) {
      win.webContents.send('window:stateChanged', { fullscreen })
    }
  }
  // Windows emits these events before isFullScreen() reflects the change.
  win.on('enter-full-screen', () => publishWindowState(true))
  win.on('leave-full-screen', () => publishWindowState(false))
  windowStateStore.track(mainWindow)

  if (windowState.maximized) mainWindow.maximize()

  mainWindow.on('ready-to-show', () => {
    ensureRegularAppPresence()
    mainWindow?.show()
  })

  mainWindow.on('closed', () => {
    mainWindow = null
    for (const listener of mainWindowClosedListeners) listener()
  })

  // Open target=_blank links in the external browser, never in-app.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    const externalUrl = normalizeAllowedExternalUrl(url)
    if (externalUrl === null) {
      console.warn(`[window-open] 차단: ${externalUrlScheme(url)}`)
      return { action: 'deny' }
    }

    void shell.openExternal(externalUrl).catch((error: unknown) => {
      console.error(`[window-open] 열기 실패: ${externalUrl}`, error)
    })
    return { action: 'deny' }
  })

  // 렌더러는 로컬 앱 문서다 — 어떤 최상위 내비게이션도 정상 경로가 아니다
  // (버그이거나 처리되지 않은 링크 클릭). 허용 목록 없이 전부 막는다.
  // <webview> 게스트의 내비게이션은 별개 webContents 라 영향받지 않는다.
  mainWindow.webContents.on('will-navigate', (event) => {
    event.preventDefault()
  })

  if (process.env['ELECTRON_RENDERER_URL'] !== undefined) {
    void mainWindow.loadURL(`${process.env['ELECTRON_RENDERER_URL']}/index.html`)
  } else {
    void mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }

  return mainWindow
}

export function getMainWindow(): BrowserWindow | null {
  return mainWindow
}
