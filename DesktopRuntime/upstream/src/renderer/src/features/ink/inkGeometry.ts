import { getStroke } from 'perfect-freehand'
import type {
  DrawingBox,
  DrawingColor,
  DrawingPoint,
  DrawingShape,
  DrawingStyle
} from '../../../../shared/types/drawing'

type Point2 = readonly [number, number]

const STROKE_COORD_SCALE = 1000
export const MIN_BOX_WIDTH = 0.03
export const MIN_BOX_HEIGHT = 0.025

export type ResizeHandle = 'nw' | 'ne' | 'sw' | 'se' | 'n' | 's' | 'e' | 'w'

export function drawingColorVariable(color: DrawingColor): string {
  return `var(--drawing-color-${color})`
}

export function normalizedPoint(
  element: SVGSVGElement,
  clientX: number,
  clientY: number,
  pressure: number,
  clampToBounds = true
): DrawingPoint {
  const bounds = element.getBoundingClientRect()
  const clamp = (value: number): number => Math.min(1, Math.max(0, value))
  const x = (clientX - bounds.left) / bounds.width
  const y = (clientY - bounds.top) / bounds.height
  return {
    x: clampToBounds ? clamp(x) : x,
    y: clampToBounds ? clamp(y) : y,
    p: clamp(pressure > 0 ? pressure : 0.5)
  }
}

export function normalizedBox(start: DrawingPoint, end: DrawingPoint): DrawingBox {
  return {
    x: Math.min(start.x, end.x),
    y: Math.min(start.y, end.y),
    width: Math.abs(end.x - start.x),
    height: Math.abs(end.y - start.y)
  }
}

export function moveDrawingBox(
  box: DrawingBox,
  dx: number,
  dy: number,
  clampToBounds = true
): DrawingBox {
  const x = box.x + dx
  const y = box.y + dy
  return {
    ...box,
    // Math.max 를 바깥에 — box 가 페이지보다 크면(1-width < 0) 안쪽 min 이
    // 음수를 내는데, 그때도 원점 밖으로 튀지 않아야 한다.
    x: clampToBounds ? Math.max(0, Math.min(1 - box.width, x)) : x,
    y: clampToBounds ? Math.max(0, Math.min(1 - box.height, y)) : y
  }
}

export function resizeDrawingBox(
  box: DrawingBox,
  dx: number,
  dy: number,
  clampToBounds = true,
  handle: ResizeHandle = 'se',
  lockAspectRatio = false,
  /** 표면의 세로/가로 비 — dx(폭 기준)와 dy(높이 기준)를 픽셀로 맞춰 비교. */
  aspect = 1
): DrawingBox {
  const right = box.x + box.width
  const bottom = box.y + box.height
  const movesWest = handle === 'nw' || handle === 'sw' || handle === 'w'
  const movesNorth = handle === 'nw' || handle === 'ne' || handle === 'n'
  // 엣지 핸들은 한 축만 만진다 — 리플로우 리사이즈의 핵심.
  const affectsX = handle !== 'n' && handle !== 's'
  const affectsY = handle !== 'e' && handle !== 'w'

  if (
    lockAspectRatio &&
    affectsX &&
    affectsY &&
    Number.isFinite(box.width) &&
    Number.isFinite(box.height) &&
    box.width > 0 &&
    box.height > 0
  ) {
    const horizontalDelta = movesWest ? -dx : dx
    const verticalDelta = movesNorth ? -dy : dy
    // 연속 스케일: 앵커(반대 코너)→잡은 코너 벡터에 드래그 델타를 사영한다.
    // 예전의 지배축 선택(|dx| ≥ |dy|·aspect)은 판정이 화면 픽셀 기준인데
    // 스케일은 박스 자체 크기 대비라, 가로세로 비가 극단인 박스(텍스트박스)
    // 에서 45° 드래그가 경계를 넘나들 때마다 크기가 수 배씩 튀었다.
    // 사영은 연속이고, 델타가 대각선과 평행하면 지배축 방식과 같다.
    // (dx 는 폭 정규화, dy 는 높이 정규화 — aspect 를 곱해 픽셀 비로 맞춘다.)
    const diagonalX = box.width
    const diagonalY = box.height * aspect
    const diagonalLengthSq = diagonalX * diagonalX + diagonalY * diagonalY
    const requestedScale = diagonalLengthSq > 0
      ? 1 +
        (diagonalX * horizontalDelta + diagonalY * verticalDelta * aspect) /
        diagonalLengthSq
      : 1
    const minimumScale = Math.max(
      MIN_BOX_WIDTH / box.width,
      MIN_BOX_HEIGHT / box.height
    )
    const maximumScale = clampToBounds
      ? Math.min(
          (movesWest ? right : 1 - box.x) / box.width,
          (movesNorth ? bottom : 1 - box.y) / box.height
        )
      : Number.POSITIVE_INFINITY
    // 최소 크기와 페이지 경계가 충돌하면(가늘고 긴 이미지) 경계가 이긴다 —
    // 최소 크기가 이기면 box 가 [0,1] 밖으로 자라 잘림/좌표 튐이 된다.
    const floorScale = Math.min(minimumScale, maximumScale)
    const scale = Math.max(
      floorScale,
      Math.min(maximumScale, requestedScale)
    )
    const width = box.width * scale
    const height = box.height * scale
    const x = movesWest ? right - width : box.x
    const y = movesNorth ? bottom - height : box.y

    if (!clampToBounds) return { ...box, x, y, width, height }
    const clampedWidth = Math.min(1, width)
    const clampedHeight = Math.min(1, height)
    return {
      ...box,
      x: Math.max(0, Math.min(1 - clampedWidth, x)),
      y: Math.max(0, Math.min(1 - clampedHeight, y)),
      width: clampedWidth,
      height: clampedHeight
    }
  }

  const x = movesWest && affectsX
    ? Math.min(right - MIN_BOX_WIDTH, clampToBounds ? Math.max(0, box.x + dx) : box.x + dx)
    : box.x
  const y = movesNorth && affectsY
    ? Math.min(bottom - MIN_BOX_HEIGHT, clampToBounds ? Math.max(0, box.y + dy) : box.y + dy)
    : box.y
  const width = !affectsX
    ? box.width
    : movesWest
      ? right - x
      : Math.max(MIN_BOX_WIDTH, box.width + dx)
  const height = !affectsY
    ? box.height
    : movesNorth
      ? bottom - y
      : Math.max(MIN_BOX_HEIGHT, box.height + dy)

  return {
    ...box,
    x,
    y,
    width: clampToBounds && affectsX && !movesWest ? Math.min(1 - box.x, width) : width,
    height: clampToBounds && affectsY && !movesNorth ? Math.min(1 - box.y, height) : height
  }
}

export function strokePath(
  points: readonly DrawingPoint[],
  style: DrawingStyle,
  aspect: number,
  isHighlighter: boolean
): string {
  if (
    points.length < 2 ||
    !Number.isFinite(aspect) ||
    aspect <= 0 ||
    !Number.isFinite(style.width) ||
    style.width <= 0 ||
    points.some((point) =>
      !Number.isFinite(point.x) ||
      !Number.isFinite(point.y) ||
      !Number.isFinite(point.p)
    )
  ) {
    return ''
  }
  const firstInput = points[0]
  const hasLength = firstInput !== undefined && points.some((point) =>
    point.x !== firstInput.x || point.y !== firstInput.y
  )
  if (!hasLength) return ''
  const outline = getStroke(
    points.map((point) => [
      point.x * STROKE_COORD_SCALE,
      point.y * aspect * STROKE_COORD_SCALE,
      point.p
    ]),
    {
      size: style.width * STROKE_COORD_SCALE,
      thinning: isHighlighter ? 0.08 : 0.62,
      smoothing: 0.55,
      streamline: 0.42,
      simulatePressure: false,
      start: { cap: true, taper: style.width * STROKE_COORD_SCALE * 2 },
      end: { cap: true, taper: style.width * STROKE_COORD_SCALE * 2 },
      last: true
    }
  )
  const first = outline[0]
  if (
    first === undefined ||
    outline.length < 3 ||
    outline.some((point) => !Number.isFinite(point[0]) || !Number.isFinite(point[1]))
  ) {
    return ''
  }
  const toPage = (point: Point2): Point2 => [
    point[0] / STROKE_COORD_SCALE,
    point[1] / STROKE_COORD_SCALE / aspect
  ]
  const start = toPage(first)
  let path = `M ${start[0]} ${start[1]}`
  for (let index = 1; index < outline.length - 1; index += 1) {
    const currentRaw = outline[index]
    const nextRaw = outline[index + 1]
    if (currentRaw === undefined || nextRaw === undefined) continue
    const current = toPage(currentRaw)
    const next = toPage(nextRaw)
    path += ` Q ${current[0]} ${current[1]} ${(current[0] + next[0]) / 2} ${(current[1] + next[1]) / 2}`
  }
  return `${path} Z`
}

export function lineEndpoints(shape: DrawingShape): [DrawingPoint, DrawingPoint] | null {
  const points = shape.data.points
  const first = points?.[0]
  const last = points?.[points.length - 1]
  if (first !== undefined && last !== undefined && points !== undefined && points.length >= 2) {
    return [first, last]
  }
  const box = shape.data.box
  if (box === undefined) return null
  return [
    { x: box.x, y: box.y, p: 0.5 },
    { x: box.x + box.width, y: box.y + box.height, p: 0.5 }
  ]
}

export function arrowHeadPoints(
  start: DrawingPoint,
  end: DrawingPoint,
  width: number,
  aspect: number
): string {
  if (
    !Number.isFinite(aspect) ||
    aspect <= 0 ||
    !Number.isFinite(width) ||
    width <= 0 ||
    !Number.isFinite(start.x) ||
    !Number.isFinite(start.y) ||
    !Number.isFinite(end.x) ||
    !Number.isFinite(end.y)
  ) {
    return ''
  }
  const startPhysical: Point2 = [start.x, start.y * aspect]
  const endPhysical: Point2 = [end.x, end.y * aspect]
  const angle = Math.atan2(
    endPhysical[1] - startPhysical[1],
    endPhysical[0] - startPhysical[0]
  )
  const size = Math.max(width * 4, 0.012)
  const wing = (offset: number): Point2 => [
    endPhysical[0] - Math.cos(angle + offset) * size,
    (endPhysical[1] - Math.sin(angle + offset) * size) / aspect
  ]
  const left = wing(-Math.PI / 6)
  const right = wing(Math.PI / 6)
  return `${left[0]},${left[1]} ${end.x},${end.y} ${right[0]},${right[1]}`
}

function pointSegmentDistance(point: Point2, start: Point2, end: Point2): number {
  const dx = end[0] - start[0]
  const dy = end[1] - start[1]
  if (dx === 0 && dy === 0) return Math.hypot(point[0] - start[0], point[1] - start[1])
  const t = Math.min(1, Math.max(0,
    ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / (dx * dx + dy * dy)
  ))
  return Math.hypot(point[0] - (start[0] + t * dx), point[1] - (start[1] + t * dy))
}

function boxPolyline(box: DrawingBox, aspect: number): Point2[] {
  return [
    [box.x, box.y * aspect],
    [box.x + box.width, box.y * aspect],
    [box.x + box.width, (box.y + box.height) * aspect],
    [box.x, (box.y + box.height) * aspect],
    [box.x, box.y * aspect]
  ]
}

function ellipsePolyline(box: DrawingBox, aspect: number): Point2[] {
  const points: Point2[] = []
  const centerX = box.x + box.width / 2
  const centerY = box.y + box.height / 2
  for (let index = 0; index <= 32; index += 1) {
    const angle = index / 32 * Math.PI * 2
    points.push([
      centerX + Math.cos(angle) * box.width / 2,
      (centerY + Math.sin(angle) * box.height / 2) * aspect
    ])
  }
  return points
}

function drawingPolyline(shape: DrawingShape, aspect: number): Point2[] {
  if (shape.kind === 'ink' || shape.kind === 'highlighter') {
    const points = (shape.data.points ?? [])
      .filter((point) => Number.isFinite(point.x) && Number.isFinite(point.y))
      .map((point): Point2 => [point.x, point.y * aspect])
    if (points.length > 0 || shape.data.box === undefined) return points
    return boxPolyline(shape.data.box, aspect)
  }
  if (shape.kind === 'line' || shape.kind === 'arrow') {
    const endpoints = lineEndpoints(shape)
    return endpoints === null
      ? []
      : endpoints.map((point) => [point.x, point.y * aspect])
  }
  const box = shape.data.box
  if (box === undefined) return []
  return shape.kind === 'ellipse'
    ? ellipsePolyline(box, aspect)
    : boxPolyline(box, aspect)
}

export function drawingHit(
  shape: DrawingShape,
  point: DrawingPoint,
  aspect: number
): boolean {
  if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) return false
  const safeAspect = Number.isFinite(aspect) && aspect > 0 ? aspect : 1
  const box = shape.data.box
  if (
    shape.kind === 'textbox' &&
    box !== undefined &&
    [box.x, box.y, box.width, box.height].every(Number.isFinite) &&
    point.x >= Math.min(box.x, box.x + box.width) &&
    point.x <= Math.max(box.x, box.x + box.width) &&
    point.y >= Math.min(box.y, box.y + box.height) &&
    point.y <= Math.max(box.y, box.y + box.height)
  ) {
    return true
  }
  const polyline = drawingPolyline(shape, safeAspect).filter((entry) =>
    Number.isFinite(entry[0]) && Number.isFinite(entry[1])
  )
  // A locationless saved shape cannot be targeted more precisely. Treat an
  // explicit eraser gesture anywhere as permission to clean it up.
  if (polyline.length === 0) return true
  const target: Point2 = [point.x, point.y * safeAspect]
  const shapeWidth = Number.isFinite(shape.style.width) && shape.style.width > 0
    ? shape.style.width
    : 0
  const threshold = Math.max(0.007, shapeWidth / 2 + 0.005)
  if (polyline.length === 1) {
    const only = polyline[0]
    return only !== undefined && Math.hypot(target[0] - only[0], target[1] - only[1]) <= threshold
  }
  for (let index = 1; index < polyline.length; index += 1) {
    const start = polyline[index - 1]
    const end = polyline[index]
    if (start !== undefined && end !== undefined && pointSegmentDistance(target, start, end) <= threshold) {
      return true
    }
  }
  return false
}
