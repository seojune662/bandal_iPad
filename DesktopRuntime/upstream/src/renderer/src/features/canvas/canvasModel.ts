import type { DrawingBox, DrawingShape } from '../../../../shared/types/drawing'
import type { PersonalBoardShape } from '../../../../shared/types/whiteboard'

export type CanvasShapeInput = Omit<
  PersonalBoardShape,
  'id' | 'createdAt' | 'updatedAt'
>

/** Builds the shape shown immediately while its local IPC write is in flight. */
export function createOptimisticCanvasShape(
  input: CanvasShapeInput,
  id: string,
  timestamp: string
): PersonalBoardShape {
  return {
    id,
    ...input,
    createdAt: timestamp,
    updatedAt: timestamp
  }
}

/** Inserts a new optimistic shape or replaces its server-confirmed version. */
export function putOptimisticCanvasShape(
  shapes: readonly PersonalBoardShape[],
  shape: PersonalBoardShape
): PersonalBoardShape[] {
  const index = shapes.findIndex((entry) => entry.id === shape.id)
  if (index < 0) return [...shapes, shape]
  return shapes.map((entry, entryIndex) =>
    entryIndex === index ? shape : entry
  )
}

/** Applies a text/move/resize edit before the upsert completes. */
export function updateOptimisticCanvasShape(
  shapes: readonly PersonalBoardShape[],
  id: string,
  patch: Partial<Pick<DrawingShape, 'data' | 'style'>>,
  timestamp: string
): PersonalBoardShape[] {
  return shapes.map((shape) =>
    shape.id === id
      ? {
          ...shape,
          data: patch.data ?? shape.data,
          style: patch.style ?? shape.style,
          updatedAt: timestamp
        }
      : shape
  )
}

/** Hides erased shapes immediately while the soft-delete is persisted. */
export function removeOptimisticCanvasShapes(
  shapes: readonly PersonalBoardShape[],
  ids: readonly string[]
): PersonalBoardShape[] {
  const removed = new Set(ids)
  return shapes.filter((shape) => !removed.has(shape.id))
}

export interface CanvasDropPoint {
  x: number
  y: number
}

const DEFAULT_CLIP_WIDTH = 1 / 3
const MAX_CLIP_EXTENT = 0.9

/** Places a clip around the drop point while preserving its pixel aspect. */
export function clipBoxAtDrop(
  point: CanvasDropPoint,
  surfaceAspect: number,
  clipAspect: number
): DrawingBox {
  const safeSurfaceAspect = surfaceAspect > 0 && Number.isFinite(surfaceAspect)
    ? surfaceAspect
    : 1
  const safeClipAspect = clipAspect > 0 && Number.isFinite(clipAspect)
    ? clipAspect
    : 1
  let width = DEFAULT_CLIP_WIDTH
  let height = width * safeClipAspect / safeSurfaceAspect
  if (height > MAX_CLIP_EXTENT) {
    const scale = MAX_CLIP_EXTENT / height
    width *= scale
    height = MAX_CLIP_EXTENT
  }
  const x = Math.min(1 - width, Math.max(0, point.x - width / 2))
  const y = Math.min(1 - height, Math.max(0, point.y - height / 2))
  return { x, y, width, height }
}
