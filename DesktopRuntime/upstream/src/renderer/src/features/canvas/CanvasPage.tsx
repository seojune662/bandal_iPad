import {
  useEffect,
  useRef,
  useState,
  type DragEvent as ReactDragEvent,
  type RefObject
} from 'react'
import type {
  DrawingClipSource,
  DrawingImageSource
} from '../../../../shared/types/drawing'
import type { PersonalBoardShape } from '../../../../shared/types/whiteboard'
import {
  BANDAL_IMAGE_MIME,
  InkLayer,
  readBandalImageDragData,
  type InkLayerProps
} from '../ink'
import {
  BANDAL_CLIP_MIME,
  readBandalClipDragData
} from '../pdf/clipTransfer'
import { imageSourceFromFileDrop } from '../materials/imageDrag'

export const DEFAULT_PAGE_ASPECT = Math.SQRT2

interface PageSize {
  width: number
  height: number
}

interface CanvasPageProps {
  pageNumber: number
  boardTitle: string
  /** Needed to resolve image shapes; without it they render as empty boxes. */
  courseId: string
  shapes: readonly PersonalBoardShape[]
  tool: InkLayerProps['tool']
  viewportRef: RefObject<HTMLDivElement>
  renderClip: NonNullable<InkLayerProps['renderClip']>
  onOpenClip: NonNullable<InkLayerProps['onOpenClip']>
  onCreate: InkLayerProps['onCreate']
  onUpdate: InkLayerProps['onUpdate']
  onRemove: InkLayerProps['onRemove']
  onRefineBox: InkLayerProps['onRefineBox']
  /** 패널 활성 여부 — 키보드 삭제가 활성 탭에만 반응하게. */
  interactive: boolean
  onDropClip: (
    source: DrawingClipSource,
    point: { x: number; y: number },
    page: number
  ) => void
  onDropImage: (
    source: DrawingImageSource,
    point: { x: number; y: number },
    page: number
  ) => void
  onActivate: (page: number) => void
  onVisibilityChange: (page: number, ratio: number) => void
}

function usePageSize(ref: RefObject<HTMLDivElement>): PageSize {
  const [size, setSize] = useState<PageSize>({ width: 0, height: 0 })

  useEffect(() => {
    const element = ref.current
    if (element === null) return
    const update = (width: number, height: number): void => {
      setSize((current) => current.width === width && current.height === height
        ? current
        : { width, height })
    }
    // ResizeObserver 의 contentRect(content-box)와 같은 기준으로 초기 측정 —
    // getBoundingClientRect(border-box)를 쓰면 첫 프레임만 2px 어긋난다.
    update(element.clientWidth, element.clientHeight)
    const observer = new ResizeObserver((entries) => {
      const entry = entries[0]
      if (entry !== undefined) {
        update(entry.contentRect.width, entry.contentRect.height)
      }
    })
    observer.observe(element)
    return () => observer.disconnect()
  }, [ref])

  return size
}

export function CanvasPage({
  pageNumber,
  boardTitle,
  courseId,
  shapes,
  tool,
  viewportRef,
  renderClip,
  onOpenClip,
  onCreate,
  onUpdate,
  onRemove,
  onRefineBox,
  interactive,
  onDropClip,
  onDropImage,
  onActivate,
  onVisibilityChange
}: CanvasPageProps): JSX.Element {
  const surfaceRef = useRef<HTMLDivElement>(null)
  const size = usePageSize(surfaceRef)

  useEffect(() => {
    const surface = surfaceRef.current
    const viewport = viewportRef.current
    if (surface === null || viewport === null) return
    const observer = new IntersectionObserver((entries) => {
      const entry = entries[0]
      onVisibilityChange(pageNumber, entry?.intersectionRatio ?? 0)
    }, {
      root: viewport,
      threshold: [0, 0.25, 0.5, 0.75, 1]
    })
    observer.observe(surface)
    return () => {
      observer.disconnect()
      onVisibilityChange(pageNumber, 0)
    }
  }, [onVisibilityChange, pageNumber, viewportRef])

  const handleDragOver = (event: ReactDragEvent<HTMLDivElement>): void => {
    const types = Array.from(event.dataTransfer.types)
    if (
      !types.includes(BANDAL_CLIP_MIME) &&
      !types.includes(BANDAL_IMAGE_MIME) &&
      !types.includes('Files')
    ) {
      return
    }
    // `getData` is empty during dragover by spec, so the decision has to come
    // from `types`. Without preventDefault the browser never fires `drop`.
    event.preventDefault()
    event.dataTransfer.dropEffect = 'copy'
  }

  /** Normalized position inside this page, or null before it is measured. */
  const pointAt = (
    event: ReactDragEvent<HTMLDivElement>
  ): { x: number; y: number } | null => {
    const surface = surfaceRef.current
    if (surface === null) return null
    const bounds = surface.getBoundingClientRect()
    // 셰이프 좌표계는 SVG(content box) 기준이라 border 를 빼고 정규화한다.
    const width = surface.clientWidth
    const height = surface.clientHeight
    if (width <= 0 || height <= 0) return null
    const left = bounds.left + surface.clientLeft
    const top = bounds.top + surface.clientTop
    return {
      x: Math.min(1, Math.max(0, (event.clientX - left) / width)),
      y: Math.min(1, Math.max(0, (event.clientY - top) / height))
    }
  }

  const handleDrop = (event: ReactDragEvent<HTMLDivElement>): void => {
    const image =
      readBandalImageDragData(event.dataTransfer) ??
      imageSourceFromFileDrop(courseId, event.dataTransfer)
    if (image !== null) {
      const point = pointAt(event)
      if (point === null) return
      event.preventDefault()
      onDropImage(image, point, pageNumber)
      return
    }
    const source = readBandalClipDragData(event.dataTransfer)
    if (source === null) return
    const point = pointAt(event)
    if (point === null) return
    event.preventDefault()
    onDropClip(source, point, pageNumber)
  }

  return (
    <article className="canvas-tab__page" data-page-number={pageNumber}>
      <div className="canvas-tab__page-number">페이지 {pageNumber}</div>
      <div
        ref={surfaceRef}
        className="canvas-tab__surface"
        onPointerDown={() => onActivate(pageNumber)}
        onFocusCapture={() => onActivate(pageNumber)}
        onDragEnter={() => onActivate(pageNumber)}
        onDragOver={handleDragOver}
        onDrop={handleDrop}
      >
        <InkLayer
          courseId={courseId}
          aspect={DEFAULT_PAGE_ASPECT}
          baseWidthPx={size.width}
          shapes={shapes}
          tool={tool}
          onCreate={onCreate}
          onUpdate={onUpdate}
          onRemove={onRemove}
          onRefineBox={onRefineBox}
          clampToBounds={true}
          interactive={interactive}
          ariaLabel={`${boardTitle} ${pageNumber}페이지 캔버스`}
          className="canvas-tab__ink-layer"
          renderClip={renderClip}
          onOpenClip={onOpenClip}
        />
      </div>
    </article>
  )
}
