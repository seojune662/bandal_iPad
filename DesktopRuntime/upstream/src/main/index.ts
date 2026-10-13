import { assertAppRendererSender } from './ipc/appRendererSender'
import { onBrowserQuitCancelled } from './features/browser/nativeTabs'
import { registerEarlyMediaProtocol } from './features/materials/mediaRegistration'
import { markStartup } from './performanceTrace'
import { createBackgroundClient } from './background/client'
import path, { join } from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { app, BrowserWindow, ipcMain, nativeTheme, protocol } from 'electron'
import type { IpcResponse } from '../shared/ipc/contract'
import type { PushPayload } from '../shared/ipc/events'
import { resolveKeymap } from '../shared/keymap'
import type { Settings, SettingsPatch } from '../shared/types/settings'
import { initDatabase, closeDatabase } from './db/database'
import { createDeepLinkQueue } from './deepLinkQueue'
import { findDeepLinkArg } from './features/account/authCallbackUrl'
import { registerHandlers } from './ipc/registerHandlers'
import { installApplicationMenu } from './menu'
import { getSettings, setSettings as persistSettings } from './settingsStore'
import {
  createMainWindow,
  ensureRegularAppPresence,
  getMainWindow,
  onMainWindowClosed,
  revealMainWindow,
  refreshTitleBarOverlay,
  resolveWindowBackground
} from './windows/mainWindow'
import { openSettingsInApp } from './windows/settingsWindow'
import { installTray } from './windows/tray'
import { createAppIconApplier } from './windows/appIcon'
import {
  createFinderIconApplier,
  resolveAppBundlePath
} from './windows/macFinderIcon'
import { reportFatalStartupError } from './startupError'
import { PLUGIN_SCHEME } from './features/plugins/pluginProtocol'
import { resolveAppVersion } from './features/updater/appVersion'
import { configureBrowserIdentity } from './features/browser/browserIdentity'
import { BROWSER_AUTH_PROBE_NATIVE_IDENTITY_CAPABILITY, BROWSER_AUTH_PROBE_PROTOCOL, initializeBrowserAuthProbe } from './features/browser/authProbe'
import { writeFileSync } from 'node:fs'

const execFileAsync = promisify(execFile)

const settingsChangedListeners = new Set<(settings: Settings) => void>()

function onSettingsChanged(cb: (settings: Settings) => void): () => void {
  settingsChangedListeners.add(cb)
  return () => settingsChangedListeners.delete(cb)
}

function setSettings(patch: SettingsPatch): Settings {
  const settings = persistSettings(patch)
  for (const listener of settingsChangedListeners) listener(settings)
  return settings
}

// [M6-B testability] E2E runs (Playwright _electron) point the app at a
// throwaway profile so tests never touch the real userData. Must run before
// requestSingleInstanceLock — the lock is scoped to the userData path.
const authProbe = initializeBrowserAuthProbe(process.env, app.getPath('userData'), process.execPath, process.argv)
configureBrowserIdentity(app, {
  name: app.isPackaged ? app.getName() : 'bandal',
  version: resolveAppVersion(app.isPackaged, app.getVersion(), __APP_VERSION__)
}, authProbe?.identity)
const testUserDataDir = authProbe?.userDataDir ?? process.env['BANDAL_USER_DATA_DIR']
if (testUserDataDir !== undefined && testUserDataDir !== '') {
  app.setPath('userData', testUserDataDir)
}

// [bandal-media] 자료 동영상 스트리밍 스킴. 특권 등록은 반드시 whenReady 전에
// 해야 한다 (Electron 제약). stream: true 가 Range 기반 <video> 탐색의 핵심.
// 실제 핸들러는 registerHandlers.ts 가 whenReady 후 protocol.handle 로 단다.
protocol.registerSchemesAsPrivileged([
  {
    scheme: 'bandal-media',
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      // pdf.js 가 fetch 로 range 요청한다 — corsEnabled 없이는 렌더러
      // 오리진에서의 cross-origin fetch 가 CORS 로 조용히 죽는다.
      corsEnabled: true,
      stream: true
    }
  },
  {
    scheme: PLUGIN_SCHEME,
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true
    }
  }
])

// Single-instance guard.
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  // [P2-D] OAuth deep links. Buffered because macOS can deliver the callback
  // before whenReady() — see deepLinkQueue.ts for why dropping it is the
  // "login only works on the second try" bug.
  const deepLinks = createDeepLinkQueue()

  /**
   * Registers this build as the handler for `bandal://`.
   *
   * The `defaultApp` branch is for `electron-vite dev`, where the running
   * binary is Electron itself: the OS has to be told to relaunch
   * `Electron <project path>` rather than bare Electron, or the callback opens
   * a second, project-less app. Note that in dev macOS registers the *Electron*
   * bundle for the scheme — see docs/oauth-setup.md for how to verify.
   */
  function registerProtocolClient(): void {
    const entry = process.argv[1]
    if (process.defaultApp && entry !== undefined) {
      app.setAsDefaultProtocolClient('bandal', process.execPath, [
        path.resolve(entry)
      ])
      return
    }
    app.setAsDefaultProtocolClient('bandal')
  }
  if (!authProbe) registerProtocolClient()

  // ⚠ MUST be registered before whenReady(). A cold start from a deep link
  // emits `open-url` during startup; a listener attached inside whenReady()
  // misses it entirely and the URL is gone for good.
  app.on('open-url', (event, url) => {
    event.preventDefault()
    if (authProbe) return
    deepLinks.push(url)
  })

  // Windows/Linux deliver the URL in argv instead; harmless no-op on macOS.
  const argvDeepLink = findDeepLinkArg(process.argv)
  if (!authProbe && argvDeepLink !== null) deepLinks.push(argvDeepLink)

  app.on('second-instance', (_event, argv) => {
    // The relaunch that carries the callback is killed by the single-instance
    // lock, so its argv is the only place the URL exists.
    const url = findDeepLinkArg(argv)
    if (!authProbe && url !== null) deepLinks.push(url)
    createMainWindow()
  })

  let resolveStartup!: () => void
  let rejectStartup!: (error: unknown) => void
  const startup = new Promise<void>((resolve, reject) => { resolveStartup = resolve; rejectStartup = reject })
  void startup.catch(() => undefined)
  // Preload asks before its document URL is committed. This read-only barrier
  // grants no capabilities; every later app request checks its sender.
  ipcMain.handle('startup:ready', () => startup)

  void app.whenReady().then(async () => {
    app.setAppUserModelId('com.bandal.app')
    if (authProbe) writeFileSync(join(authProbe.root, 'runtime.json'), JSON.stringify({
      protocol: BROWSER_AUTH_PROBE_PROTOCOL, version: 1, mode: authProbe.mode,
      identity: authProbe.identity, capabilities: [BROWSER_AUTH_PROBE_NATIVE_IDENTITY_CAPABILITY],
      launchId: authProbe.launchId, pid: process.pid, startedAt: new Date().toISOString(),
      appVersion: app.getVersion(), platform: process.platform, arch: process.arch,
      electron: process.versions.electron, chromium: process.versions.chrome,
      packaged: app.isPackaged, pageInstrumentation: authProbe.mode !== 'clean',
      manualAuthenticationRequired: true, debuggingFlags: 'absent'
    }, null, 2), { mode: 0o600 })
    ensureRegularAppPresence()

    // [M6-A] Custom menu: keeps ⌘W free for "close tab" in the renderer.
    // Rebuild only when accelerator settings change; rebuilding for unrelated
    // settings would drop an open submenu and re-register every accelerator.
    const initialSettings = getSettings()
    let menuKeybindings = JSON.stringify(initialSettings.keybindings)
    installApplicationMenu(resolveKeymap(initialSettings.keybindings))

    // Paint the shell before migration/recovery, keeping the main loop free.
    // The preload readiness barrier prevents data access until services exist.
    try {
      registerEarlyMediaProtocol()
      const shellWindow = createMainWindow()
      markStartup('window-created')
      shellWindow.webContents.once('did-finish-load', () => markStartup('renderer-loaded'))
      const initializer = createBackgroundClient()
      try { await initializer.request('migrate', { dbPath: join(app.getPath('userData'), 'bandal.db') }, 0) }
      finally { initializer.dispose() }
      initDatabase(false)
      markStartup('database-ready')
    } catch (error: unknown) {
      rejectStartup(error)
      reportFatalStartupError('데이터베이스 초기화', error)
      return
    }

    const openMain = (): void => {
      const existing = getMainWindow()
      const main = existing ?? createMainWindow()
      if (existing !== null) {
        revealMainWindow(main)
      }
    }

    type OpenTarget =
      | {
          channel: 'ui:openMaterial'
          payload: PushPayload<'ui:openMaterial'>
        }
      | { channel: 'ui:openUrl'; payload: PushPayload<'ui:openUrl'> }
    type PendingOpen = NonNullable<
      IpcResponse<'ui:consumePendingOpen'>
    >
    let pendingOpen: PendingOpen | null = null

    const pushToMain = (target: OpenTarget): void => {
      const existing = getMainWindow()
      if (existing === null) {
        // Like deepLinkQueue, do not send at did-finish-load: React has not
        // mounted AppShell's onPush listeners yet, so that push is lossy. The
        // renderer consumes this one-slot handoff after its effects mount.
        createMainWindow()
        pendingOpen =
          target.channel === 'ui:openMaterial'
            ? { ...(pendingOpen ?? {}), material: target.payload }
            : { ...(pendingOpen ?? {}), url: target.payload }
        return
      }
      revealMainWindow(existing)
      if (!existing.webContents.isDestroyed()) {
        existing.webContents.send(target.channel, target.payload)
      }
    }
    const openMaterial = (
      payload: PushPayload<'ui:openMaterial'>
    ): void => pushToMain({ channel: 'ui:openMaterial', payload })
    const openUrl = (payload: PushPayload<'ui:openUrl'>): void =>
      pushToMain({ channel: 'ui:openUrl', payload })
    const openUrlInTab = (url: string): void => {
      openUrl({ url, positionSec: 0, playbackRate: 1 })
    }

    let miniPlayerOpen = false
    let syncMiniPlayerTray = (): void => undefined
    const router = registerHandlers({
      setSettings,
      preloadPath: join(__dirname, '../preload/index.js'),
      pluginPanelPreloadPath: join(__dirname, '../preload/pluginPanel.js'),
      userDataPath: app.getPath('userData'),
      windowBackground: resolveWindowBackground,
      openMaterial,
      openUrl,
      openInTab: openUrlInTab,
      consumePendingOpen: () => {
        const pending = pendingOpen
        pendingOpen = null
        return pending
      },
      onMiniPlayerStateChanged: (open) => {
        miniPlayerOpen = open
        if (!open) ensureRegularAppPresence()
        syncMiniPlayerTray()
      }
    })

    const trayDeps = {
      shouldShow: () => process.platform === 'darwin' || miniPlayerOpen,
      openMain,
      quit: () => app.quit()
    }
    const tray = installTray(trayDeps)
    syncMiniPlayerTray = (): void => tray.refresh()
    const trayIconTarget = { setIconVariant: (dir: string): void => tray.setIconVariant(dir) }

    const appBundlePath = resolveAppBundlePath(app.getPath('exe'))
    const finder =
      process.platform === 'darwin' &&
      app.isPackaged &&
      !authProbe &&
      appBundlePath !== null
        ? createFinderIconApplier({
            appBundlePath,
            async exec(command, args) {
              const result = await execFileAsync(command, args, {
                encoding: 'utf8'
              })
              return {
                code: 0,
                stdout: result.stdout,
                stderr: result.stderr
              }
            }
          })
        : undefined
    const appIcon = createAppIconApplier({
      getSettings,
      prefersDark: () => nativeTheme.shouldUseDarkColors,
      platform: process.platform,
      isPackaged: app.isPackaged,
      resourcesPath: process.resourcesPath,
      bundleDir: __dirname,
      ...(app.dock === undefined ? {} : { dock: app.dock }),
      windows: () => BrowserWindow.getAllWindows(),
      tray: trayIconTarget,
      ...(finder === undefined ? {} : { finder })
    })

    const refreshAppearance = (): void => {
      void appIcon.apply()
      // Capture windows and embedded websites own their backgrounds.
      for (const win of BrowserWindow.getAllWindows()) {
        const url = win.webContents.getURL()
        if (/\/(?:index|settings)\.html(?:$|[?#])|\/pip\.html\?view=player/.test(url)) {
          win.setBackgroundColor(resolveWindowBackground())
        }
      }
      const main = getMainWindow()
      if (main !== null && !main.isDestroyed()) {
        refreshTitleBarOverlay(
          main,
          getSettings(),
          nativeTheme.shouldUseDarkColors
        )
      }
    }
    onSettingsChanged((settings) => {
      const nextMenuKeybindings = JSON.stringify(settings.keybindings)
      if (nextMenuKeybindings !== menuKeybindings) {
        menuKeybindings = nextMenuKeybindings
        installApplicationMenu(resolveKeymap(settings.keybindings))
      }
      tray.refresh()
      syncMiniPlayerTray()
      refreshAppearance()
    })
    nativeTheme.on('updated', refreshAppearance)

    // Temporary M0 channel to open the settings window from the renderer.
    // Replaced by an app menu entry in a later milestone.
    ipcMain.handle('window:openSettings', event => {
      assertAppRendererSender(event)
      openSettingsInApp()
      return { ok: true }
    })

    markStartup('services-ready')
    resolveStartup()
    const window = createMainWindow()
    tray.refresh()
    refreshAppearance()

    onMainWindowClosed(() => {
      if (
        process.platform !== 'darwin' &&
        !router.miniPlayer.isAlive()
      ) {
        app.quit()
      }
    })

    app.on('before-quit', () => {
      router.miniPlayer.markQuitting()
    })
    onBrowserQuitCancelled(() => {
      router.miniPlayer.markQuitting(false)
    })

    app.on('window-all-closed', () => {
      if (
        process.platform !== 'darwin' &&
        !router.miniPlayer.isAlive()
      ) {
        app.quit()
      }
    })

    // Replay only once the renderer is listening: the auth result travels back
    // as an `auth:changed` push, and a push sent to a window that has not
    // finished loading is dropped on the floor. `did-fail-load` is here so a
    // failed renderer load cannot strand a queued callback forever — attach()
    // is idempotent, so whichever fires first wins.
    const attachDeepLinks = (): void => {
      deepLinks.attach((url) => router.handleDeepLink(url))
    }
    window.webContents.once('did-finish-load', attachDeepLinks)
    window.webContents.once('did-fail-load', attachDeepLinks)
    if (!window.webContents.isLoadingMainFrame()) attachDeepLinks()

    app.on('activate', () => {
      const existing = getMainWindow()
      if (existing === null) {
        createMainWindow()
      } else {
        revealMainWindow(existing)
      }
    })
  }).catch((error: unknown) => {
    // whenReady 체인의 나머지(메뉴 설치, 핸들러 등록, 창 생성)에서 던진 경우.
    // catch가 없으면 unhandled rejection으로 조용히 사라진다.
    rejectStartup(error)
    reportFatalStartupError('앱 초기화', error)
  })

  // Service teardown runs on will-quit and can still use the database.
  // Close it only after that phase, regardless of listener registration order.
  app.on('quit', () => {
    closeDatabase()
  })
}
