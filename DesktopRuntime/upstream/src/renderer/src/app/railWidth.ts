/**
 * 좌/우 사이드바 폭의 클램프·저장. 폭의 원천은 tokens.css 의 전역 CSS 변수
 * (--rail-left-width / --rail-right-width)라, 적용은 documentElement 인라인
 * 변수 덮어쓰기로 한다 — 그 변수를 소비하는 10여 곳(chat/pdf/workspace…)이
 * 전부 함께 따라온다.
 */

export type RailSide = 'left' | 'right'

interface RailLimit {
  min: number
  max: number
  default: number
}

export const RAIL_WIDTH_LIMITS: Record<RailSide, RailLimit> = {
  left: { min: 176, max: 400, default: 240 },
  right: { min: 220, max: 520, default: 288 }
}

const STORAGE_KEY = 'bandal:rail-widths:v1'

export const RAIL_WIDTH_VARIABLES: Record<RailSide, string> = {
  left: '--rail-left-width',
  right: '--rail-right-width'
}

export function clampRailWidth(side: RailSide, px: number): number {
  const limit = RAIL_WIDTH_LIMITS[side]
  if (!Number.isFinite(px)) return limit.default
  return Math.min(limit.max, Math.max(limit.min, Math.round(px)))
}

export function readRailWidths(
  storage: Pick<Storage, 'getItem'> = window.localStorage
): Partial<Record<RailSide, number>> {
  try {
    const raw = storage.getItem(STORAGE_KEY)
    if (raw === null) return {}
    const parsed: unknown = JSON.parse(raw)
    if (parsed === null || typeof parsed !== 'object') return {}
    const result: Partial<Record<RailSide, number>> = {}
    for (const side of ['left', 'right'] as const) {
      const value = (parsed as Record<string, unknown>)[side]
      if (typeof value === 'number' && Number.isFinite(value)) {
        result[side] = clampRailWidth(side, value)
      }
    }
    return result
  } catch {
    return {}
  }
}

export function persistRailWidth(
  side: RailSide,
  px: number,
  storage: Pick<Storage, 'getItem' | 'setItem'> = window.localStorage
): void {
  try {
    const current = readRailWidths(storage)
    storage.setItem(
      STORAGE_KEY,
      JSON.stringify({ ...current, [side]: clampRailWidth(side, px) })
    )
  } catch {
    // 저장 실패는 편의 기능 상실일 뿐 — 조용히 넘어간다.
  }
}

/** 저장된 폭(없으면 아무것도 안 함)을 문서 루트 변수에 적용한다. */
export function applyStoredRailWidths(
  storage: Pick<Storage, 'getItem'> = window.localStorage
): void {
  const widths = readRailWidths(storage)
  for (const side of ['left', 'right'] as const) {
    const width = widths[side]
    if (width !== undefined) {
      document.documentElement.style.setProperty(
        RAIL_WIDTH_VARIABLES[side],
        `${width}px`
      )
    }
  }
}
