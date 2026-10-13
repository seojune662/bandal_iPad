/**
 * 창 크기·위치 영속. settings.json 과 분리한 이유:
 * bounds 는 resize/move 마다 갱신되는 고빈도 값이라 settings:changed
 * 브로드캐스트를 타면 렌더러가 불필요하게 깨어난다.
 */

import { screen, type BrowserWindow, type Rectangle } from 'electron'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

const SAVE_DEBOUNCE_MS = 500

export interface WindowState {
  bounds: Rectangle | null
  maximized: boolean
}

export interface WindowStateStoreOptions {
  file: string
  minWidth: number
  minHeight: number
}

export interface WindowStateStore {
  read(): WindowState
  track(win: BrowserWindow): void
  save(state: WindowState): void
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

/** Electron-free validation core, exported so malformed files stay unit-testable. */
export function sanitizeWindowBounds(
  raw: unknown,
  minWidth: number,
  minHeight: number
): Rectangle | null {
  if (typeof raw !== 'object' || raw === null) return null
  const { x, y, width, height } = raw as Record<string, unknown>
  if (
    !isFiniteNumber(x) ||
    !isFiniteNumber(y) ||
    !isFiniteNumber(width) ||
    !isFiniteNumber(height)
  ) {
    return null
  }
  if (width < minWidth || height < minHeight) return null
  return {
    x: Math.round(x),
    y: Math.round(y),
    width: Math.round(width),
    height: Math.round(height)
  }
}

/** Electron-free display-overlap check used by the store's screen adapter. */
export function isWindowBoundsVisible(
  bounds: Rectangle,
  areas: Rectangle[],
  minVisiblePx: number
): boolean {
  return areas.some((area) => {
    const overlapX =
      Math.min(bounds.x + bounds.width, area.x + area.width) -
      Math.max(bounds.x, area.x)
    const overlapY =
      Math.min(bounds.y + bounds.height, area.y + area.height) -
      Math.max(bounds.y, area.y)
    return overlapX >= minVisiblePx && overlapY >= minVisiblePx
  })
}

export function createWindowStateStore(
  opts: WindowStateStoreOptions
): WindowStateStore {
  // Small fixed overlays cannot expose the old main-window threshold of 100px.
  const minVisiblePx = Math.min(100, opts.minWidth)

  const save = (state: WindowState): void => {
    try {
      mkdirSync(dirname(opts.file), { recursive: true })
      writeFileSync(opts.file, JSON.stringify(state, null, 2), 'utf8')
    } catch (error) {
      console.error('[window] failed to persist window state:', error)
    }
  }

  const read = (): WindowState => {
    try {
      const raw: unknown = JSON.parse(readFileSync(opts.file, 'utf8'))
      const record =
        typeof raw === 'object' && raw !== null
          ? (raw as Record<string, unknown>)
          : {}
      const bounds = sanitizeWindowBounds(
        record['bounds'],
        opts.minWidth,
        opts.minHeight
      )
      const areas = screen.getAllDisplays().map((display) => display.workArea)
      return {
        bounds:
          bounds !== null &&
          isWindowBoundsVisible(bounds, areas, minVisiblePx)
            ? bounds
            : null,
        maximized: record['maximized'] === true
      }
    } catch {
      return { bounds: null, maximized: false }
    }
  }

  const track = (win: BrowserWindow): void => {
    let timer: NodeJS.Timeout | null = null

    const snapshot = (): WindowState => ({
      // getNormalBounds remembers the restorable size while maximized.
      bounds: win.getNormalBounds(),
      maximized: win.isMaximized()
    })

    const scheduleSave = (): void => {
      if (timer !== null) clearTimeout(timer)
      timer = setTimeout(() => {
        timer = null
        if (!win.isDestroyed()) save(snapshot())
      }, SAVE_DEBOUNCE_MS)
    }

    win.on('resize', scheduleSave)
    win.on('move', scheduleSave)
    win.on('close', () => {
      if (timer !== null) {
        clearTimeout(timer)
        timer = null
      }
      if (!win.isDestroyed()) save(snapshot())
    })
  }

  return { read, track, save }
}
