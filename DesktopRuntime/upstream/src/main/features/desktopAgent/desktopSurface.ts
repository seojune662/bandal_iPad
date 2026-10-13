import {
  encodeForVision,
  FALLBACK_LONG_EDGE,
  MAX_LONG_EDGE
} from './image'

export interface DisplayInfo {
  id: string
  label: string
  bounds: { x: number; y: number; width: number; height: number }
  scaleFactor: number
  primary: boolean
}

export interface WindowInfo {
  id: string
  title: string
  appName: string | null
  frontmost: boolean
  bounds?: DisplayInfo['bounds']
}

export interface RawCapture {
  width: number
  height: number
  toJPEG(quality: number): Buffer
}

export type ScreenAccess =
  | 'granted'
  | 'denied'
  | 'not-determined'
  | 'restricted'
  | 'unknown'

export interface DesktopSurfaceDeps {
  listDisplays(): DisplayInfo[]
  cursorDisplayId(): string | null
  captureDisplay(
    displayId: string,
    maxLongEdgePx: number
  ): Promise<RawCapture | null>
  captureWindow(
    windowId: string,
    maxLongEdgePx: number
  ): Promise<RawCapture | null>
  listWindows(): Promise<WindowInfo[]>
  frontmostApp(): Promise<{
    appName: string
    windowTitle: string | null
    pid: number | null
  } | null>
  readClipboardText(): string
  screenAccess(): ScreenAccess
  /** 2단계 슬롯. 지금은 구현하지 않는다. */
  axTree?: never
}

export interface ScreenshotOk {
  kind: 'ok'
  jpeg: Buffer
  mimeType: 'image/jpeg'
  width: number
  height: number
  display: DisplayInfo | null
  window: WindowInfo | null
  bytes: number
  capturedAt: string
}

export interface ScreenshotProblem {
  kind: 'problem'
  problem: string
  access: ScreenAccess
}

export interface DesktopSurface {
  screenshot(target: {
    display?: string
    window?: string
  }): Promise<ScreenshotOk | ScreenshotProblem>
  windows(): Promise<{ displays: DisplayInfo[]; windows: WindowInfo[] }>
  frontmost(): Promise<{ appName: string; windowTitle: string | null } | null>
  clipboardText(): string
  access(): ScreenAccess
}

const SCREEN_PERMISSION_PROBLEM =
  '시스템 설정 → 개인정보 보호 및 보안 → 화면 기록에서 반달을 켠 뒤, 반달을 다시 실행해 주세요'
const CAPTURE_PROBLEM = '화면을 캡처하지 못했습니다. 다시 시도해 주세요.'

export function createDesktopSurface(
  deps: DesktopSurfaceDeps,
  opts: { now?: () => Date } = {}
): DesktopSurface {
  const now = opts.now ?? (() => new Date())

  function problem(
    message: string,
    access = deps.screenAccess()
  ): ScreenshotProblem {
    return { kind: 'problem', problem: message, access }
  }

  function captureProblem(): ScreenshotProblem {
    const currentAccess = deps.screenAccess()
    return problem(
      currentAccess === 'denied' || currentAccess === 'restricted'
        ? SCREEN_PERMISSION_PROBLEM
        : CAPTURE_PROBLEM,
      currentAccess
    )
  }

  return {
    async screenshot(target) {
      const initialAccess = deps.screenAccess()
      if (initialAccess === 'denied' || initialAccess === 'restricted') {
        return problem(SCREEN_PERMISSION_PROBLEM, initialAccess)
      }

      let display: DisplayInfo | null = null
      let window: WindowInfo | null = null
      let captureAt: (maxLongEdgePx: number) => Promise<RawCapture | null>

      if (target.window !== undefined) {
        const windowId = target.window
        const listedWindows = await deps.listWindows()
        window = listedWindows.find((entry) => entry.id === windowId) ?? null
        captureAt = (maxLongEdgePx) =>
          deps.captureWindow(windowId, maxLongEdgePx)
      } else {
        const displays = deps.listDisplays()
        if (target.display !== undefined) {
          display =
            displays.find((entry) => entry.id === target.display) ?? null
        } else {
          const cursorId = deps.cursorDisplayId()
          display =
            (cursorId === null
              ? undefined
              : displays.find((entry) => entry.id === cursorId)) ??
            displays.find((entry) => entry.primary) ??
            displays[0] ??
            null
        }

        if (display === null) return problem(CAPTURE_PROBLEM, initialAccess)
        const displayId = display.id
        captureAt = (maxLongEdgePx) =>
          deps.captureDisplay(displayId, maxLongEdgePx)
      }

      let capture = await captureAt(MAX_LONG_EDGE)
      if (capture === null) return captureProblem()

      let encoded = encodeForVision(capture)
      if (encoded.needsSmaller) {
        const smaller = await captureAt(FALLBACK_LONG_EDGE)
        if (smaller === null) return captureProblem()
        capture = smaller
        encoded = encodeForVision(smaller)
        if (encoded.needsSmaller) return captureProblem()
      }

      return {
        kind: 'ok',
        jpeg: encoded.jpeg,
        mimeType: 'image/jpeg',
        width: capture.width,
        height: capture.height,
        display,
        window,
        bytes: encoded.jpeg.byteLength,
        capturedAt: now().toISOString()
      }
    },

    async windows() {
      const windows = await deps.listWindows()
      return { displays: deps.listDisplays(), windows }
    },

    async frontmost() {
      const foreground = await deps.frontmostApp()
      if (foreground === null) return null
      return {
        appName: foreground.appName,
        windowTitle: foreground.windowTitle
      }
    },

    clipboardText() {
      return deps.readClipboardText()
    },

    access() {
      return deps.screenAccess()
    }
  }
}
