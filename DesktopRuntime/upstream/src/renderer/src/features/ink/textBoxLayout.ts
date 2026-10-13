/**
 * 텍스트박스 배치·스케일의 순수 로직.
 *
 * 좌표계 주의: InkLayer 의 정규화 좌표는 x=폭 기준, y=높이 기준이라
 * "화면에서 같은 높이"는 aspect(세로/가로)에 반비례하는 정규화 높이다.
 * 예전 TEXT_BOX_HEIGHT=0.08 고정값은 16:9 슬라이드에서 한 줄 높이밖에
 * 안 됐다 — 화면 높이가 표면 비율과 무관하게 일정하도록 계산한다.
 */

import type { DrawingBox, DrawingPoint } from '../../../../shared/types/drawing'
import {
  TEXT_BASE_FONT_RATIO,
  TEXT_BOX_BORDER_EM,
  TEXT_BOX_PADDING_EM,
  TEXT_LINE_HEIGHT,
  textBoxFontPx
} from '../../../../shared/textBoxMetrics'
import { MIN_BOX_WIDTH } from './inkGeometry'

export { TEXT_BASE_FONT_RATIO }

export const TEXT_BOX_WIDTH = 0.26
/** 기본 박스에 담을 줄 수(줄높이 1.4 가정) + 패딩 여유. */
const DEFAULT_LINES = 2.2
const LINE_HEIGHT = 1.4

function finitePositive(value: number): boolean {
  return Number.isFinite(value) && value > 0
}

/** 표면 비율과 무관하게 화면상 같은 높이가 나오는 기본 박스 크기. */
export function defaultTextBoxSize(aspect: number): {
  width: number
  height: number
} {
  const safeAspect = finitePositive(aspect) ? aspect : 1
  const screenHeightRatio = TEXT_BASE_FONT_RATIO * LINE_HEIGHT * DEFAULT_LINES
  return {
    width: TEXT_BOX_WIDTH,
    height: Math.min(1, screenHeightRatio / safeAspect)
  }
}

/**
 * 클릭 지점에 첫 줄의 캐럿 중심이 오도록 배치한 새 텍스트박스.
 *
 * 박스 원점을 클릭에 두면 패딩+테두리만큼 글자가 오른쪽·아래로 밀려
 * "클릭한 곳보다 아래에 글자가 생긴다"고 느껴진다. 인셋과 첫 줄 높이의
 * 절반을 되돌려 놓는다. `clampToBounds` 면 왼쪽으로 미끄러지는 대신
 * 폭을 줄여 표면 안에 머문다(오른쪽 끝 클릭이 박스를 되튀기지 않게).
 */
export function textBoxAtClick(
  point: DrawingPoint,
  aspect: number,
  baseWidthPx: number,
  fontScale: number | undefined,
  clampToBounds: boolean,
  fontSizePt?: number,
  surfaceWidthPt = 595.28
): DrawingBox {
  const size = defaultTextBoxSize(aspect)
  const safeAspect = finitePositive(aspect) ? aspect : 1
  const safeWidthPx = finitePositive(baseWidthPx) ? baseWidthPx : 1
  const fontPx = textBoxFontPx(safeWidthPx, fontScale, fontSizePt, surfaceWidthPt)
  const insetPx = fontPx * (TEXT_BOX_PADDING_EM + TEXT_BOX_BORDER_EM)
  const rawX = point.x - insetPx / safeWidthPx
  const rawY = point.y -
    (insetPx + (fontPx * TEXT_LINE_HEIGHT) / 2) / (safeWidthPx * safeAspect)
  if (!clampToBounds) {
    return { x: rawX, y: rawY, width: size.width, height: size.height }
  }
  const x = Math.max(0, Math.min(rawX, 1 - MIN_BOX_WIDTH))
  const width = Math.max(MIN_BOX_WIDTH, Math.min(TEXT_BOX_WIDTH, 1 - x))
  const height = size.height
  const y = Math.max(0, Math.min(rawY, 1 - height))
  return { x, y, width, height }
}

/** 힐링에서 유의미한 변화로 치는 최소 차이 — 무한 보정 루프 방지. */
const HEAL_TOLERANCE = 0.001

/**
 * 표면([0,1]²)을 벗어난 텍스트박스를 안으로 되돌린 박스를 준다.
 * 예전 리사이즈 점프 버그가 페이지 절반을 덮는 거대/이탈 박스를 커밋해
 * 그 영역의 클릭을 전부 흡수하던 손상 데이터의 자가 치유 경로다.
 * 이미 정상이면 null (호출부는 무음 보정만 하면 된다).
 */
export function healedTextBox(box: DrawingBox): DrawingBox | null {
  if (
    !Number.isFinite(box.x) ||
    !Number.isFinite(box.y) ||
    !finitePositive(box.width) ||
    !finitePositive(box.height)
  ) {
    return null
  }
  const width = Math.min(1, box.width)
  const height = Math.min(1, box.height)
  const x = Math.max(0, Math.min(1 - width, box.x))
  const y = Math.max(0, Math.min(1 - height, box.y))
  const changed =
    Math.abs(x - box.x) > HEAL_TOLERANCE ||
    Math.abs(y - box.y) > HEAL_TOLERANCE ||
    Math.abs(width - box.width) > HEAL_TOLERANCE ||
    Math.abs(height - box.height) > HEAL_TOLERANCE
  return changed ? { ...box, x, y, width, height } : null
}

/** Fit text without clipping it against the lower edge of a bounded page. */
export function fittedTextBox(
  contentHeightPx: number,
  box: DrawingBox,
  baseWidthPx: number,
  aspect: number,
  clampToBounds = true
): DrawingBox | null {
  if (!finitePositive(contentHeightPx) || !finitePositive(baseWidthPx) || !finitePositive(aspect)) return null
  const needed = contentHeightPx / (baseWidthPx * aspect)
  const height = clampToBounds ? Math.min(1, needed) : needed
  const y = clampToBounds ? Math.max(0, Math.min(box.y, 1 - height)) : box.y
  return Math.abs(height - box.height) < 0.0001 && Math.abs(y - box.y) < 0.0001
    ? null
    : { ...box, y, height }
}
