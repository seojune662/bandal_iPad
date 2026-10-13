import type { PointerEvent as ReactPointerEvent } from 'react'
import type { DrawingBox, DrawingShape } from '../../../../shared/types/drawing'
import { ClipShape, type RenderClip } from './ClipShape'
import { ImageShape } from './ImageShape'
import type { ResizeHandle } from './inkGeometry'

interface ReferencedShapeProps {
  shape: DrawingShape
  box: DrawingBox
  aspect: number
  baseWidthPx: number
  courseId?: string | undefined
  boardId?: string | undefined
  selected: boolean
  renderClip?: RenderClip | undefined
  onOpenClip: Parameters<typeof ClipShape>[0]['onOpenClip']
  onBeginManipulation: (
    event: ReactPointerEvent<Element>,
    shape: DrawingShape,
    kind: 'move' | 'resize',
    handle?: ResizeHandle
  ) => void
  onNaturalAspect?: ((shape: DrawingShape, naturalAspect: number) => void) | undefined
}

export function ReferencedShape(props: ReferencedShapeProps): JSX.Element | null {
  const {
    shape,
    box,
    aspect,
    baseWidthPx,
    courseId,
    boardId,
    selected,
    renderClip,
    onOpenClip,
    onBeginManipulation,
    onNaturalAspect
  } = props
  return shape.kind === 'clip' ? (
    <ClipShape
      shape={shape}
      box={box}
      aspect={aspect}
      baseWidthPx={baseWidthPx}
      selected={selected}
      renderClip={renderClip}
      onOpenClip={onOpenClip}
      onBeginManipulation={onBeginManipulation}
      onNaturalAspect={onNaturalAspect}
    />
  ) : (
    <ImageShape
      shape={shape}
      box={box}
      aspect={aspect}
      baseWidthPx={baseWidthPx}
      courseId={courseId}
      boardId={boardId}
      selected={selected}
      onBeginManipulation={onBeginManipulation}
      onNaturalAspect={onNaturalAspect}
    />
  )
}
