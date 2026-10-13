import { screen, type BrowserWindow } from 'electron'
import { join } from 'node:path'
import type { PushChannel, PushPayload } from '../../shared/ipc/events'
import type {
  PipOpenRequest,
  PipRestorePayload,
  PipSource,
  PipState
} from '../../shared/types/pip'
import { clampToArea, type Rect } from './windowGeometry'
import {
  createLocalPipWindow,
  createWebPipWindow,
  loadLocalPipView,
  MINI_PLAYER_DEFAULT_SIZE,
  MINI_PLAYER_MIN_SIZE
} from './miniPlayerWindow'
import { createMiniPlayerToolbar } from './miniPlayerToolbar'
import { createWindowStateStore } from './windowBounds'
import {
  isWebPipIsolationResult,
  webPipIsolationSource
} from './webPipIsolation'

const STATE_FILE = 'mini-player-state.json'
const DEFAULT_MARGIN = 24
const WEB_POSITION_POLL_MS = 3_000
const DEFAULT_ASPECT = 16 / 9

export interface MiniPlayerDeps {
  preloadPath: string
  userDataPath: string
  windowBackground(): string
  broadcast<K extends PushChannel>(ch: K, p: PushPayload<K>): void
  openMaterial(payload: PushPayload<'ui:openMaterial'>): void
  openUrl(payload: PushPayload<'ui:openUrl'>): void
  openInTab(url: string): void
  now?: () => number
}

export interface MiniPlayerReport {
  positionSec: number
  playbackRate: number
  paused: boolean
  aspect?: number
}

export interface MiniPlayerController {
  open(req: PipOpenRequest): void
  close(): void
  restore(): void
  getState(): PipState
  report(p: MiniPlayerReport): void
  moveBy(dx: number, dy: number): void
  isAlive(): boolean
  markQuitting(value?: boolean): void
}

interface ActivePlayer {
  window: BrowserWindow
  toolbar: BrowserWindow | null
  source: PipSource
  allowClose: boolean
  webIsolated: boolean
}

function finiteNonNegative(value: number, fallback: number): number {
  return Number.isFinite(value) && value >= 0 ? value : fallback
}

function finitePlaybackRate(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback
}

function youtubeStartUrl(url: string, positionSec: number): string {
  try {
    const parsed = new URL(url)
    const host = parsed.hostname.toLowerCase()
    const youtube =
      host === 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host === 'youtu.be' ||
      host.endsWith('.youtu.be')
    if (!youtube) return url
    parsed.searchParams.set('t', String(Math.floor(positionSec)))
    return parsed.toString()
  } catch {
    return url
  }
}

/** Electron-free URL helper kept public for the controller's boundary tests. */
export function withYoutubeStartTime(
  url: string,
  positionSec: number
): string {
  return youtubeStartUrl(url, finiteNonNegative(positionSec, 0))
}

export function createMiniPlayerController(
  deps: MiniPlayerDeps
): MiniPlayerController {
  const boundsStore = createWindowStateStore({
    file: join(deps.userDataPath, STATE_FILE),
    minWidth: MINI_PLAYER_MIN_SIZE.width,
    minHeight: MINI_PLAYER_MIN_SIZE.height
  })

  let active: ActivePlayer | null = null
  let positionSec = 0
  let playbackRate = 1
  let paused = true
  let reportedAspect: number | null = null
  let pollTimer: NodeJS.Timeout | null = null
  let quitting = false

  const getState = (): PipState => ({
    open: active !== null,
    source: active?.source ?? null,
    positionSec,
    playbackRate,
    paused
  })

  const broadcastState = (): void => {
    deps.broadcast('pip:state', getState())
  }

  const stopPolling = (): void => {
    if (pollTimer === null) return
    clearInterval(pollTimer)
    pollTimer = null
  }

  const resetClosedState = (): void => {
    positionSec = 0
    playbackRate = 1
    paused = true
    reportedAspect = null
  }

  const destroyToolbar = (player: ActivePlayer): void => {
    const toolbar = player.toolbar
    player.toolbar = null
    if (toolbar !== null && !toolbar.isDestroyed()) toolbar.destroy()
  }

  const finishUnexpectedClose = (player: ActivePlayer): void => {
    if (active !== player) return
    stopPolling()
    destroyToolbar(player)
    active = null
    resetClosedState()
    broadcastState()
  }

  const closePlayer = (player: ActivePlayer): void => {
    player.allowClose = true
    if (active === player) {
      stopPolling()
      destroyToolbar(player)
      active = null
      resetClosedState()
      broadcastState()
    }
    if (!player.window.isDestroyed()) player.window.close()
  }

  const initialBounds = (): Rect => {
    const saved = boundsStore.read().bounds
    if (saved !== null) {
      return clampToArea(saved, screen.getDisplayMatching(saved).workArea)
    }
    const area = screen.getPrimaryDisplay().workArea
    return clampToArea(
      {
        x:
          area.x +
          area.width -
          MINI_PLAYER_DEFAULT_SIZE.width -
          DEFAULT_MARGIN,
        y:
          area.y +
          area.height -
          MINI_PLAYER_DEFAULT_SIZE.height -
          DEFAULT_MARGIN,
        ...MINI_PLAYER_DEFAULT_SIZE
      },
      area
    )
  }

  const sendInitialLocalSeek = (player: ActivePlayer): void => {
    player.window.webContents.once('did-finish-load', () => {
      if (active !== player || player.window.webContents.isDestroyed()) return
      deps.broadcast('pip:seek', {
        positionSec,
        playbackRate,
        play: !paused
      })
    })
  }

  const initializeWebVideo = (player: ActivePlayer): void => {
    const script = `(() => {
      const video = document.querySelector('[data-bandal-pip-video], video')
      if (!(video instanceof HTMLVideoElement)) return false
      video.currentTime = ${JSON.stringify(positionSec)}
      video.playbackRate = ${JSON.stringify(playbackRate)}
      if (${JSON.stringify(paused)}) video.pause()
      else void video.play()
      return true
    })()`
    try {
      void player.window.webContents.executeJavaScript(script, true).catch(() => {
        // Some sites replace their player during load. The polling loop still
        // captures a later video, and a navigation will run this hook again.
      })
    } catch {
      // The window may have been destroyed between did-finish-load and here.
    }
  }

  const pollWebPosition = (player: ActivePlayer): void => {
    if (active !== player || player.window.isDestroyed()) return
    try {
      void player.window.webContents
        .executeJavaScript(
          `(() => {
            const video = document.querySelector('[data-bandal-pip-video], video')
            return video instanceof HTMLVideoElement ? video.currentTime : null
          })()`
        )
        .then((value: unknown) => {
          if (active !== player) return
          if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
            return
          }
          positionSec = value
          broadcastState()
        })
        .catch(() => undefined)
    } catch {
      // A close racing the interval is expected and requires no recovery.
    }
  }

  const startWebPlaybackTracking = (player: ActivePlayer): void => {
    const failIsolation = (): void => {
      if (active !== player || player.webIsolated) return
      deps.broadcast('pip:error', {
        message: '이 사이트의 영상만 작은 창으로 분리하지 못했어요.'
      })
      restore()
    }
    player.window.webContents.on('did-finish-load', () => {
      if (active !== player) return
      const source = player.source
      if (source.kind !== 'web') return
      try {
        void player.window.webContents
          .executeJavaScript(
            webPipIsolationSource(source, positionSec, playbackRate, paused),
            true
          )
          .then((result: unknown) => {
            if (active !== player || player.window.isDestroyed()) return
            if (!isWebPipIsolationResult(result) || !result.ready) {
              failIsolation()
              return
            }
            player.webIsolated = true
            if (result.aspect !== undefined) {
              reportedAspect = result.aspect
              player.window.setAspectRatio(result.aspect)
            }
            player.window.show()
            const toolbar = player.toolbar
            if (toolbar !== null && !toolbar.isDestroyed()) {
              toolbar.showInactive()
            }
            initializeWebVideo(player)
            stopPolling()
            pollTimer = setInterval(
              () => pollWebPosition(player),
              WEB_POSITION_POLL_MS
            )
          })
          .catch(() => {
            failIsolation()
          })
      } catch {
        failIsolation()
      }
    })
  }

  const showWhenReady = (player: ActivePlayer): void => {
    player.window.once('ready-to-show', () => {
      if (active !== player || player.window.isDestroyed()) return
      player.window.show()
      const toolbar = player.toolbar
      if (toolbar !== null && !toolbar.isDestroyed()) toolbar.showInactive()
    })
  }

  const open = (request: PipOpenRequest): void => {
    if (active !== null) closePlayer(active)

    positionSec = finiteNonNegative(request.positionSec, 0)
    playbackRate = finitePlaybackRate(request.playbackRate, 1)
    paused = request.paused ?? false

    const bounds = initialBounds()
    const window =
      request.source.kind === 'local'
        ? createLocalPipWindow({
            bounds,
            preload: deps.preloadPath,
            backgroundColor: deps.windowBackground()
          })
        : createWebPipWindow({ bounds, openInTab: deps.openInTab })
    const player: ActivePlayer = {
      window,
      toolbar: null,
      source: request.source,
      allowClose: quitting,
      webIsolated: false
    }
    active = player

    window.on('close', (event) => {
      if (!player.allowClose && !quitting) event.preventDefault()
    })
    window.on('closed', () => finishUnexpectedClose(player))
    boundsStore.track(window)
    const requestedAspect =
      request.source.kind === 'web'
        ? request.source.videoHint?.aspect
        : undefined
    window.setAspectRatio(requestedAspect ?? DEFAULT_ASPECT)

    if (request.source.kind === 'local') {
      showWhenReady(player)
      sendInitialLocalSeek(player)
      loadLocalPipView(window, request.source)
    } else {
      player.toolbar = createMiniPlayerToolbar({
        pipWindow: window,
        preload: deps.preloadPath
      })
      startWebPlaybackTracking(player)
      void window.loadURL(
        withYoutubeStartTime(request.source.url, positionSec)
      )
    }

    broadcastState()
  }

  const close = (): void => {
    if (active !== null) closePlayer(active)
  }

  const restore = (): void => {
    const player = active
    if (player === null) return
    const payload: PipRestorePayload = {
      source: player.source,
      positionSec,
      playbackRate
    }
    if (payload.source.kind === 'local') {
      deps.openMaterial({
        courseId: payload.source.courseId,
        relPath: payload.source.relPath,
        positionSec: payload.positionSec,
        playbackRate: payload.playbackRate
      })
    } else {
      deps.openUrl({
        url: payload.source.url,
        positionSec: payload.positionSec,
        playbackRate: payload.playbackRate
      })
    }
    closePlayer(player)
  }

  const report = (reportPayload: MiniPlayerReport): void => {
    const player = active
    if (player === null || player.source.kind !== 'local') return
    positionSec = finiteNonNegative(reportPayload.positionSec, positionSec)
    playbackRate = finitePlaybackRate(reportPayload.playbackRate, playbackRate)
    paused = reportPayload.paused
    const aspect = reportPayload.aspect
    if (
      aspect !== undefined &&
      Number.isFinite(aspect) &&
      aspect > 0 &&
      aspect !== reportedAspect
    ) {
      reportedAspect = aspect
      player.window.setAspectRatio(aspect)
      const current = player.window.getBounds()
      const target = {
        ...current,
        height: Math.round(current.width / aspect)
      }
      const workArea = screen.getDisplayMatching(target).workArea
      const clamped = clampToArea(target, workArea)
      player.window.setSize(clamped.width, clamped.height)
      if (clamped.x !== current.x || clamped.y !== current.y) {
        player.window.setPosition(clamped.x, clamped.y)
      }
    }
    broadcastState()
  }

  const moveBy = (dx: number, dy: number): void => {
    const player = active
    if (
      player === null ||
      !Number.isFinite(dx) ||
      !Number.isFinite(dy) ||
      player.window.isDestroyed()
    ) {
      return
    }
    const bounds = player.window.getBounds()
    const target = {
      ...bounds,
      x: Math.round(bounds.x + dx),
      y: Math.round(bounds.y + dy)
    }
    const clamped = clampToArea(
      target,
      screen.getDisplayMatching(target).workArea
    )
    player.window.setPosition(clamped.x, clamped.y)
  }

  const isAlive = (): boolean =>
    active !== null && !active.window.isDestroyed()

  const markQuitting = (value = true): void => {
    quitting = value
    if (active !== null) active.allowClose = value
  }

  return {
    open,
    close,
    restore,
    getState,
    report,
    moveBy,
    isAlive,
    markQuitting
  }
}
