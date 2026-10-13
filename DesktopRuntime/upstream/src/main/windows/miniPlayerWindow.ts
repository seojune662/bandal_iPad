import { BrowserWindow } from 'electron'
import { join } from 'node:path'
import type { PipSource } from '../../shared/types/pip'
import {
  attachNavigationPolicies,
  popupWebPreferences
} from '../features/browser/hardenWebviews'
import type { Rect } from './windowGeometry'
import { macPanelOptions } from './panelOptions'

export const MINI_PLAYER_MIN_SIZE = { width: 240, height: 135 }
export const MINI_PLAYER_DEFAULT_SIZE = { width: 480, height: 270 }

interface CommonWindowOptions {
  bounds: Rect
  backgroundColor?: string
  webPreferences: Electron.WebPreferences
}

function createMiniPlayerWindow(options: CommonWindowOptions): BrowserWindow {
  const win = new BrowserWindow({
    ...options.bounds,
    show: false,
    ...(options.backgroundColor === undefined
      ? {}
      : { backgroundColor: options.backgroundColor }),
    frame: false,
    roundedCorners: true,
    resizable: true,
    minWidth: MINI_PLAYER_MIN_SIZE.width,
    minHeight: MINI_PLAYER_MIN_SIZE.height,
    alwaysOnTop: true,
    skipTaskbar: false,
    ...macPanelOptions(),
    webPreferences: options.webPreferences
  })

  win.setAlwaysOnTop(true, 'floating')
  win.setVisibleOnAllWorkspaces(true, {
    visibleOnFullScreen: true,
    // Electron otherwise flips the whole process between
    // UIElementApplication and ForegroundApplication. On macOS that removes
    // Bandal from the Dock and ⌘Tab while PiP is being created, and the
    // reverse transition is not reliable when an NSPanel closes quickly.
    skipTransformProcessType: true
  })
  return win
}

export function createLocalPipWindow(opts: {
  bounds: Rect
  preload: string
  backgroundColor: string
}): BrowserWindow {
  const win = createMiniPlayerWindow({
    bounds: opts.bounds,
    backgroundColor: opts.backgroundColor,
    webPreferences: {
      preload: opts.preload,
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false
    }
  })

  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  return win
}

export function createWebPipWindow(opts: {
  bounds: Rect
  openInTab?: (url: string) => void
}): BrowserWindow {
  const win = createMiniPlayerWindow({
    bounds: opts.bounds,
    webPreferences: {
      ...popupWebPreferences(),
      backgroundThrottling: false
    }
  })

  attachNavigationPolicies(win.webContents, {
    openInTab: opts.openInTab ?? (() => undefined)
  })
  return win
}

/** Loads the local renderer entry without letting path values shape a URL. */
export function loadLocalPipView(
  win: BrowserWindow,
  source: Extract<PipSource, { kind: 'local' }>
): void {
  const query = {
    view: 'player',
    course: source.courseId,
    rel: source.relPath,
    title: source.title
  }
  const rendererUrl = process.env['ELECTRON_RENDERER_URL']
  if (rendererUrl !== undefined) {
    const params = new URLSearchParams(query)
    void win.loadURL(`${rendererUrl}/pip.html?${params.toString()}`)
  } else {
    void win.loadFile(join(__dirname, '../renderer/pip.html'), { query })
  }
}
