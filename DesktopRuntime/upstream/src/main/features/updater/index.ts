/**
 * Auto-update runtime.
 *
 * Wraps electron-updater's `autoUpdater` behind the `UpdateStatus` union so the
 * renderer never sees electron-updater types, and so every state transition
 * reaches every window through one push channel.
 *
 * Three deliberate choices:
 *
 * 1. **`autoDownload = false`.** A macOS update is a ~95 MB zip. Students on
 *    metered phone tethering should not discover that after the fact — the
 *    download starts when they press the button.
 * 2. **Silent when there is nothing to say.** "No update available" and
 *    "offline" are the normal case on almost every check. They resolve to
 *    `idle`, never to `error`, so the toast stays quiet.
 * 3. **Disabled unless packaged.** In `electron-vite dev` there is no
 *    `app-update.yml`, and asking anyway throws on every check. The phase is
 *    `unsupported` and the UI hides itself.
 */

import { app } from 'electron'
import electronUpdater from 'electron-updater'
import type { UpdateStatus } from '../../../shared/types/update'
import { killAllClaudeProcessesSync } from '../agent'
import { resolveAppVersion } from './appVersion'
import { describeError, isNoFeed, isOfflineish } from './errorMessages'
import { getBrowserAuthProbeMode } from '../browser/authProbe'

export { resolveAppVersion } from './appVersion'

// electron-updater is CommonJS; the named export is not reachable via ESM
// destructuring in the electron-vite bundle.
const { autoUpdater } = electronUpdater

/** First check runs after startup settles — window paint wins the race. */
const INITIAL_CHECK_DELAY_MS = 10_000
/** Then every 6 hours, for the student who never quits the app. */
const RECHECK_INTERVAL_MS = 6 * 60 * 60 * 1000

export interface UpdaterRuntime {
  /** Latest known state. Cheap; never hits the network. */
  status(): UpdateStatus
  /** Explicit user-initiated check. */
  check(): Promise<UpdateStatus>
  /** Begin downloading an available update. */
  download(): Promise<UpdateStatus>
  /** Quit and install. Returns false if there was nothing staged. */
  install(): boolean
  /** A browser unload veto cancelled the explicitly requested restart. */
  cancelInstall(): void
  /** Stops the periodic timer. */
  dispose(): void
}

export interface UpdaterDeps {
  /** Broadcasts a state change to every renderer window. */
  broadcast: (status: UpdateStatus) => void
  /** Injectable for tests. Defaults to `app.isPackaged`. */
  isPackaged?: boolean
  /** Injectable for tests. Defaults to the installed or build app version. */
  currentVersion?: string
  /** Injectable for platform-specific installer cancellation tests. */
  platform?: NodeJS.Platform
}

export function createUpdaterRuntime(deps: UpdaterDeps): UpdaterRuntime {
  const isPackaged = deps.isPackaged ?? app.isPackaged
  const updatesEnabled = isPackaged && getBrowserAuthProbeMode() === null
  const currentVersion =
    deps.currentVersion ??
    resolveAppVersion(isPackaged, app.getVersion(), __APP_VERSION__)

  let status: UpdateStatus = updatesEnabled
    ? { phase: 'idle', currentVersion, lastCheckedAt: null }
    : { phase: 'unsupported', currentVersion }
  let timer: NodeJS.Timeout | null = null
  let initialTimer: NodeJS.Timeout | null = null
  let availableVersion: string | null = null
  let installRequested = false

  function setStatus(next: UpdateStatus): void {
    status = next
    deps.broadcast(next)
  }

  if (!updatesEnabled) {
    // Nothing else in this module should run: no feed, no timers, no listeners.
    return {
      status: () => status,
      check: async () => status,
      download: async () => status,
      install: () => false,
      cancelInstall: () => undefined,
      dispose: () => undefined
    }
  }

  function dispose(): void {
    if (timer !== null) clearInterval(timer)
    if (initialTimer !== null) clearTimeout(initialTimer)
    timer = null
    initialTimer = null
    autoUpdater.removeListener('update-available', onAvailable)
    autoUpdater.removeListener('update-not-available', onNotAvailable)
    autoUpdater.removeListener('download-progress', onProgress)
    autoUpdater.removeListener('update-downloaded', onDownloaded)
    autoUpdater.removeListener('error', onError)
  }

  autoUpdater.autoDownload = false
  // Applying on quit would swap the app out from under a student who just
  // closed the window mid-session. The restart is always explicit.
  autoUpdater.autoInstallOnAppQuit = false
  autoUpdater.logger = null

  function onAvailable(info: { version: string; releaseNotes?: unknown }): void {
    availableVersion = info.version
    setStatus({
      phase: 'available',
      currentVersion,
      version: info.version,
      notes: typeof info.releaseNotes === 'string' ? info.releaseNotes : null
    })
  }

  function onNotAvailable(): void {
    availableVersion = null
    setStatus({ phase: 'idle', currentVersion, lastCheckedAt: Date.now() })
  }

  function onProgress(progress: { percent: number }): void {
    const version = status.phase === 'available' || status.phase === 'downloading'
      ? status.version
      : currentVersion
    setStatus({
      phase: 'downloading',
      currentVersion,
      version,
      percent: Math.round(progress.percent)
    })
  }

  function onDownloaded(info: { version: string }): void {
    setStatus({ phase: 'ready', currentVersion, version: info.version })
  }

  function onError(error: Error): void {
    installRequested = false
    console.error('[updater]', error)
    // No app-update.yml: this build was never wired to a release feed. Stop
    // checking rather than retry every 6 hours forever.
    if (isNoFeed(error.message)) {
      dispose()
      setStatus({ phase: 'unsupported', currentVersion })
      return
    }
    // Offline is the normal state of a laptop in a lecture hall, not a failure
    // worth a red toast.
    if (status.phase !== 'downloading' && isOfflineish(error.message)) {
      setStatus({ phase: 'idle', currentVersion, lastCheckedAt: Date.now() })
      return
    }
    setStatus({
      phase: 'error',
      currentVersion,
      message: describeError(error.message)
    })
  }
  autoUpdater.on('update-available', onAvailable)
  autoUpdater.on('update-not-available', onNotAvailable)
  autoUpdater.on('download-progress', onProgress)
  autoUpdater.on('update-downloaded', onDownloaded)
  autoUpdater.on('error', onError)

  async function check(): Promise<UpdateStatus> {
    if (
      status.phase === 'downloading' ||
      status.phase === 'checking' ||
      status.phase === 'ready' ||
      // Feed already proven absent — retrying only re-logs the same ENOENT.
      status.phase === 'unsupported'
    ) {
      return status
    }
    setStatus({ phase: 'checking', currentVersion })
    try {
      await autoUpdater.checkForUpdates()
    } catch (error) {
      // The 'error' listener above already set the status; this catch only
      // stops the rejection from escaping.
      if (!(error instanceof Error)) {
        setStatus({ phase: 'idle', currentVersion, lastCheckedAt: Date.now() })
      }
    }
    return status
  }

  async function download(): Promise<UpdateStatus> {
    if ((status.phase !== 'available' && status.phase !== 'error') || availableVersion === null) {
      return status
    }
    // Reserve the download before its first progress event so repeated clicks
    // and periodic checks cannot start a second operation during connection.
    setStatus({ phase: 'downloading', currentVersion, version: availableVersion, percent: 0 })
    try {
      await autoUpdater.downloadUpdate()
    } catch {
      // Reported through the 'error' listener.
    }
    return status
  }

  function install(): boolean {
    if (status.phase !== 'ready' || installRequested) {
      return false
    }
    installRequested = true
    if (status.restartCancelled) setStatus({ phase: 'ready', currentVersion, version: status.version })
    // The CLI holds file handles under the install dir on Windows; a survivor
    // makes the NSIS updater fail to replace the app. Harmless on macOS.
    // isSilent=false so the student sees the NSIS progress; isForceRunAfter so
    // the app comes back up instead of just vanishing.
    try {
      killAllClaudeProcessesSync()
      autoUpdater.quitAndInstall(false, true)
    }
    catch (error) { onError(error instanceof Error ? error : new Error(String(error))); return false }
    return true
  }

  function cancelInstall(): void {
    if (!installRequested) return
    installRequested = false
    if ((deps.platform ?? process.platform) !== 'darwin') {
      // electron-updater 6.8 BaseUpdater retains this own boolean after a quit
      // veto. Clear only that known flag so an explicit retry is not ignored.
      const requested = Object.getOwnPropertyDescriptor(autoUpdater, 'quitAndInstallCalled')
      if (requested && 'value' in requested && typeof requested.value === 'boolean' && requested.writable) {
        try { Reflect.set(autoUpdater, 'quitAndInstallCalled', false) } catch { /* No writable compatibility field. */ }
      }
    }
    if (status.phase === 'ready') setStatus({ ...status, restartCancelled: true })
  }

  initialTimer = setTimeout(() => {
    void check()
  }, INITIAL_CHECK_DELAY_MS)
  initialTimer.unref()

  timer = setInterval(() => {
    void check()
  }, RECHECK_INTERVAL_MS)
  timer.unref()

  return { status: () => status, check, download, install, cancelInstall, dispose }
}
