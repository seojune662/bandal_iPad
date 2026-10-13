import type { PointerEvent as ReactPointerEvent } from 'react'
import type { DrawingBox } from '../../../../shared/types/drawing'
import type { ResizeHandle } from './inkGeometry'

/** 표면 폭을 모를 때의 정규화 핸들 크기(구 동작). */
const HANDLE_SIZE = 0.016
/** 표면 폭을 알면 줌과 무관하게 화면 픽셀로 고정한다. */
const HANDLE_PX = 10

const HANDLE_CORNERS: readonly ResizeHandle[] = ['nw', 'ne', 'sw', 'se']

/** 텍스트박스: 코너(자유 리사이즈) + 좌우 엣지(폭만 — 줄바꿈 재배치). */
export const TEXTBOX_HANDLES: readonly ResizeHandle[] = [
  'nw', 'ne', 'sw', 'se', 'e', 'w'
]

export interface ResizeHandleBox extends DrawingBox {
  handle: ResizeHandle
}

function handleCenter(
  handle: ResizeHandle,
  box: DrawingBox
): { x: number; y: number } {
  const midX = box.x + box.width / 2
  const midY = box.y + box.height / 2
  switch (handle) {
    case 'nw': return { x: box.x, y: box.y }
    case 'ne': return { x: box.x + box.width, y: box.y }
    case 'sw': return { x: box.x, y: box.y + box.height }
    case 'se': return { x: box.x + box.width, y: box.y + box.height }
    case 'n': return { x: midX, y: box.y }
    case 's': return { x: midX, y: box.y + box.height }
    case 'e': return { x: box.x + box.width, y: midY }
    case 'w': return { x: box.x, y: midY }
  }
}

/** 줌 불변 핸들 크기: 픽셀 고정이 가능하면 그쪽, 아니면 정규화 상수. */
export function resizeHandleSize(baseWidthPx?: number): number {
  return baseWidthPx !== undefined && Number.isFinite(baseWidthPx) && baseWidthPx > 0
    ? HANDLE_PX / baseWidthPx
    : HANDLE_SIZE
}

export function resizeHandleBoxes(
  box: DrawingBox,
  aspect: number,
  handles: readonly ResizeHandle[] = HANDLE_CORNERS,
  sizeNormalized: number = HANDLE_SIZE
): ResizeHandleBox[] {
  if (!Number.isFinite(aspect) || aspect <= 0) return []
  const size = Number.isFinite(sizeNormalized) && sizeNormalized > 0
    ? sizeNormalized
    : HANDLE_SIZE
  const screenSquareHeight = size / aspect
  const halfWidth = size / 2
  const halfHeight = screenSquareHeight / 2

  return handles.map((handle) => {
    const center = handleCenter(handle, box)
    return {
      handle,
      x: center.x - halfWidth,
      y: center.y - halfHeight,
      width: size,
      height: screenSquareHeight
    }
  })
}

interface ResizeHandlesProps {
  box: DrawingBox
  aspect: number
  className: string
  /** 알면 핸들이 화면 픽셀 크기로 고정된다(줌 불변). */
  baseWidthPx?: number
  fill?: string
  handles?: readonly ResizeHandle[]
  onPointerDown: (
    event: ReactPointerEvent<SVGRectElement>,
    handle: ResizeHandle
  ) => void
}

export function ResizeHandles({
  box,
  aspect,
  className,
  baseWidthPx,
  fill,
  handles = HANDLE_CORNERS,
  onPointerDown
}: ResizeHandlesProps): JSX.Element {
  const boxes = resizeHandleBoxes(
    box,
    aspect,
    handles,
    resizeHandleSize(baseWidthPx)
  )
  return (
    <>
      {boxes.map(({ handle, ...handleBox }) => (
        <rect
          key={handle}
          className={className}
          data-resize-handle={handle}
          {...handleBox}
          fill={fill}
          vectorEffect="non-scaling-stroke"
          onPointerDown={(event) => onPointerDown(event, handle)}
        />
      ))}
    </>
  )
}
