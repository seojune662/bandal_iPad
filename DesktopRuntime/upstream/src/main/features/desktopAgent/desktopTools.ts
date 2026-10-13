import type {
  AgentConfirmRequest,
  AgentConfirmScope
} from '../../../shared/types/agentTools'
import { redactText } from '../browserAgent/redact'
import { RawToolResult } from '../agentTools/toolHandlers/context'
import type { createDesktopAuditRepo } from './audit'
import type { DesktopSurface } from './desktopSurface'
import {
  DESKTOP_GRANT_DAYS,
  type DesktopCapability,
  type DesktopGrantsRepo
} from './grants'

export interface DesktopToolsDeps {
  courseId: string
  conversationId: string
  getTurnId(): string | number
  surface: DesktopSurface
  grants: DesktopGrantsRepo
  audit: ReturnType<typeof createDesktopAuditRepo>
  confirm(
    input: Omit<
      AgentConfirmRequest,
      'requestId' | 'conversationId' | 'courseId'
    >
  ): Promise<AgentConfirmScope | false>
  run: {
    set(
      conversationId: string,
      status: 'idle' | 'capturing' | 'reading',
      action?: string | null
    ): void
    clear(conversationId: string): void
  }
  onPermission?(payload: {
    state: 'unknown' | 'granted' | 'denied' | 'unsupported'
    message: string | null
  }): void
}

export const DESKTOP_TURN_LIMITS = { screenshots: 6, reads: 20 } as const

export interface DesktopToolsPort {
  desktop_screenshot(
    input: unknown
  ): Promise<RawToolResult | { error: string }>
  desktop_windows(input: unknown): Promise<unknown>
  desktop_frontmost(input: unknown): Promise<unknown>
  desktop_clipboard_read(input: unknown): Promise<unknown>
}

type ScreenGate = { ok: true } | { ok: false; result: { error: string } }
type LimitKind = keyof typeof DESKTOP_TURN_LIMITS

const conversationScreenGrants = new Set<string>()

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message.trim() !== ''
    ? error.message
    : fallback
}

function objectInput(input: unknown): Record<string, unknown> | null {
  if (input === undefined) return {}
  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    return null
  }
  return input as Record<string, unknown>
}

function emptyInput(input: unknown): boolean {
  const parsed = objectInput(input)
  return parsed !== null && Object.keys(parsed).length === 0
}

function screenshotInput(
  input: unknown
): { display?: string; window?: string } | null {
  const parsed = objectInput(input)
  if (parsed === null) return null
  if (Object.keys(parsed).some((key) => key !== 'display' && key !== 'window')) {
    return null
  }

  const target: { display?: string; window?: string } = {}
  for (const key of ['display', 'window'] as const) {
    const value = parsed[key]
    if (value === undefined) continue
    if (typeof value !== 'string' || value.trim() === '') return null
    target[key] = value
  }
  return target
}

export function createDesktopTools(deps: DesktopToolsDeps): DesktopToolsPort {
  let activeTurnId: string | number | undefined
  let used: Record<LimitKind, number> = { screenshots: 0, reads: 0 }

  function record(
    action: Parameters<DesktopToolsDeps['audit']['record']>[0]['action'],
    target: string,
    detail: string
  ): void {
    deps.audit.record({
      courseId: deps.courseId,
      conversationId: deps.conversationId,
      action,
      target,
      detail
    })
  }

  function reserve(kind: LimitKind): { error: string } | null {
    const turnId = deps.getTurnId()
    if (activeTurnId !== turnId) {
      activeTurnId = turnId
      used = { screenshots: 0, reads: 0 }
    }

    if (used[kind] >= DESKTOP_TURN_LIMITS[kind]) {
      const error =
        kind === 'screenshots'
          ? '이번 턴에 화면은 6장까지만 볼 수 있어요'
          : '이번 턴에 화면 정보는 20번까지만 읽을 수 있어요'
      record('denied', 'display', error)
      return { error }
    }
    used[kind] += 1
    return null
  }

  async function gate(capability: DesktopCapability): Promise<ScreenGate> {
    if (capability === 'screen') {
      const held = deps.grants.find(deps.courseId, 'screen')
      if (held !== null) {
        deps.grants.touch(held.id)
        return { ok: true }
      }
      if (conversationScreenGrants.has(deps.conversationId)) {
        return { ok: true }
      }

      const scope = await deps.confirm({
        tool: 'desktop_screenshot',
        summary: '화면을 봐도 될까요?',
        details: [
          '지금 보이는 화면을 한 장 찍어 읽어요',
          '비밀번호 칸이 보일 수도 있어요'
        ],
        scopes: ['once', 'conversation', 'always']
      })
      if (scope === false) {
        const error = '학생이 화면 보기를 허락하지 않았어요'
        record('denied', 'display', '학생이 화면 보기를 거부함')
        return { ok: false, result: { error } }
      }
      if (scope === 'conversation') {
        conversationScreenGrants.add(deps.conversationId)
        record('grant', 'display', '이 대화에서 화면 보기 허용')
      } else if (scope === 'always') {
        deps.grants.grant(deps.courseId, 'screen')
        record(
          'grant',
          'display',
          `이 과목에서 화면 보기 ${DESKTOP_GRANT_DAYS}일 허용`
        )
      } else {
        record('grant', 'display', '이번 한 번 화면 보기 허용')
      }
      return { ok: true }
    }

    const scope = await deps.confirm({
      tool: 'desktop_clipboard_read',
      summary: '클립보드를 읽어도 될까요?',
      details: ['지금 복사해 둔 텍스트를 한 번 읽어요'],
      scopes: ['once']
    })
    if (scope === false) {
      const error = '학생이 클립보드 읽기를 허락하지 않았어요'
      record('denied', 'clipboard', '학생이 클립보드 읽기를 거부함')
      return { ok: false, result: { error } }
    }
    return { ok: true }
  }

  return {
    async desktop_screenshot(input) {
      const target = screenshotInput(input)
      if (target === null) {
        const error = 'display와 window에는 문자열 ID만 넣을 수 있어요'
        record('denied', 'display', error)
        return { error }
      }

      const permitted = await gate('screen')
      if (!permitted.ok) return permitted.result
      const limited = reserve('screenshots')
      if (limited !== null) return limited

      deps.run.set(deps.conversationId, 'capturing', '화면을 보는 중')
      try {
        const result = await deps.surface.screenshot(target)
        if (result.kind === 'problem') {
          deps.onPermission?.({ state: 'denied', message: result.problem })
          record('screenshot', 'display', '화면 캡처 실패')
          return { error: result.problem }
        }

        const display = result.display as null | {
          id?: unknown
          scaleFactor?: unknown
          bounds?: unknown
        }
        const window = result.window as null | { bounds?: unknown }
        const displayId = typeof display?.id === 'string' ? display.id : null
        const windowInfo = result.window as null | { appName?: unknown }
        const auditTarget =
          displayId ??
          (typeof windowInfo?.appName === 'string'
            ? windowInfo.appName
            : 'display')
        const metadata = {
          displayId,
          scaleFactor: display?.scaleFactor ?? null,
          bounds: window?.bounds ?? display?.bounds ?? null,
          imageWidth: result.width,
          imageHeight: result.height,
          window: result.window,
          capturedAt: result.capturedAt
        }
        record('screenshot', auditTarget, '화면 캡처 완료')
        return new RawToolResult({
          content: [
            {
              type: 'image',
              data: result.jpeg.toString('base64'),
              mimeType: 'image/jpeg'
            },
            { type: 'text', text: JSON.stringify(metadata) }
          ]
        })
      } catch (error) {
        record('screenshot', 'display', '화면 캡처 실패')
        return { error: errorMessage(error, '화면을 보지 못했어요') }
      } finally {
        deps.run.set(deps.conversationId, 'idle')
      }
    },

    async desktop_windows(input) {
      if (!emptyInput(input)) {
        const error = 'desktop_windows에는 입력이 없어요'
        record('denied', 'display', error)
        return { error }
      }
      const permitted = await gate('screen')
      if (!permitted.ok) return permitted.result
      const limited = reserve('reads')
      if (limited !== null) return limited

      deps.run.set(deps.conversationId, 'reading', '창 목록을 읽는 중')
      try {
        const result = await deps.surface.windows()
        const firstDisplay = result.displays[0] as { id?: unknown } | undefined
        const target =
          typeof firstDisplay?.id === 'string' ? firstDisplay.id : 'display'
        record(
          'windows',
          target,
          `디스플레이 ${result.displays.length}개와 창 ${result.windows.length}개 확인`
        )
        return result
      } catch (error) {
        record('windows', 'display', '창 목록 읽기 실패')
        return { error: errorMessage(error, '창 목록을 읽지 못했어요') }
      } finally {
        deps.run.set(deps.conversationId, 'idle')
      }
    },

    async desktop_frontmost(input) {
      if (!emptyInput(input)) {
        const error = 'desktop_frontmost에는 입력이 없어요'
        record('denied', 'display', error)
        return { error }
      }
      const permitted = await gate('screen')
      if (!permitted.ok) return permitted.result
      const limited = reserve('reads')
      if (limited !== null) return limited

      deps.run.set(deps.conversationId, 'reading', '앞에 있는 창을 읽는 중')
      try {
        const result = await deps.surface.frontmost()
        record(
          'frontmost',
          result?.appName ?? 'display',
          result === null ? '앞에 있는 앱 없음' : '앞에 있는 앱 확인'
        )
        return result
      } catch (error) {
        record('frontmost', 'display', '앞에 있는 앱 확인 실패')
        return { error: errorMessage(error, '앞에 있는 앱을 확인하지 못했어요') }
      } finally {
        deps.run.set(deps.conversationId, 'idle')
      }
    },

    async desktop_clipboard_read(input) {
      if (!emptyInput(input)) {
        const error = 'desktop_clipboard_read에는 입력이 없어요'
        record('denied', 'clipboard', error)
        return { error }
      }
      const permitted = await gate('clipboard')
      if (!permitted.ok) return permitted.result
      const limited = reserve('reads')
      if (limited !== null) return limited

      deps.run.set(deps.conversationId, 'reading', '클립보드를 읽는 중')
      try {
        const text = redactText(deps.surface.clipboardText()).slice(0, 4_000)
        record('clipboard', 'clipboard', '클립보드 텍스트 읽기 완료')
        return { text }
      } catch (error) {
        record('clipboard', 'clipboard', '클립보드 읽기 실패')
        return { error: errorMessage(error, '클립보드를 읽지 못했어요') }
      } finally {
        deps.run.set(deps.conversationId, 'idle')
      }
    }
  }
}
