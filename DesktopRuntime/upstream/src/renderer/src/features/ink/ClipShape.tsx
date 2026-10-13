import {
  useEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent
} from 'react'
import type {
  DrawingBox,
  DrawingClipSource,
  DrawingShape
} from '../../../../shared/types/drawing'
import { foreignObjectLayout } from './foreignObjectScale'
import { dataUrlImageAspect } from './imagePlacement'
import { observeImageVisibility } from './ImageShape'
import type { ResizeHandle } from './inkGeometry'
import { ResizeHandles } from './ResizeHandles'

export type RenderClip = (source: DrawingClipSource) => Promise<string | null>

interface ClipShapeProps {
  shape: DrawingShape
  box: DrawingBox
  aspect: number
  /** Pixel width of the surface; CSS inside the foreignObject is scaled by it. */
  baseWidthPx: number
  selected: boolean
  renderClip?: RenderClip | undefined
  onOpenClip?: ((source: DrawingClipSource) => void) | undefined
  onBeginManipulation: (
    event: ReactPointerEvent<Element>,
    shape: DrawingShape,
    kind: 'move' | 'resize',
    handle?: ResizeHandle
  ) => void
  /** 렌더 결과의 원본 비율 — 표면의 조용한 박스 치유(healedImageBox)용. */
  onNaturalAspect?: ((shape: DrawingShape, naturalAspect: number) => void) | undefined
}

type LoadState = 'idle' | 'loading' | 'ready' | 'error'

function clipCacheKey(source: DrawingClipSource): string {
  return JSON.stringify([
    source.relPath,
    source.page,
    source.crop?.x,
    source.crop?.y,
    source.crop?.width,
    source.crop?.height
  ])
}

/**
 * PDF 클립 — ImageShape 와 같은 SVG `<image>` 경로.
 * foreignObject+img 시절의 문제(측정 지연 잘림, object-fit 부재로 인한
 * 왜곡, 핸들-이미지 불일치)를 같은 방식으로 해소한다. loading/error
 * 플레이스홀더만 foreignObject 를 유지한다.
 */
export function ClipShape({
  shape,
  box,
  aspect,
  baseWidthPx,
  selected,
  renderClip,
  onOpenClip,
  onBeginManipulation,
  onNaturalAspect
}: ClipShapeProps): JSX.Element | null {
  const source = shape.data.clip
  const groupRef = useRef<SVGGElement>(null)
  const [visible, setVisible] = useState(false)
  const [loadState, setLoadState] = useState<LoadState>('idle')
  const [imageUrl, setImageUrl] = useState<string | null>(null)
  const [naturalAspect, setNaturalAspect] = useState<number | null>(null)
  const announcedAspectFor = useRef<string | null>(null)
  const onNaturalAspectRef = useRef(onNaturalAspect)
  onNaturalAspectRef.current = onNaturalAspect

  useEffect(() => {
    const element = groupRef.current
    if (element === null || renderClip === undefined) return
    return observeImageVisibility(element, setVisible)
  }, [renderClip])

  useEffect(() => {
    if (!visible || renderClip === undefined || source === undefined) return
    let cancelled = false
    setLoadState('loading')
    setImageUrl(null)
    setNaturalAspect(null)
    void renderClip(source)
      .then(async (url) => {
        if (url === null) return { url: null, ratio: null }
        return { url, ratio: await dataUrlImageAspect(url) }
      })
      .then(({ url, ratio }) => {
        if (cancelled) return
        if (url === null || ratio === null) {
          setImageUrl(null)
          setLoadState('error')
          return
        }
        setImageUrl(url)
        setNaturalAspect(ratio)
        setLoadState('ready')
        const key = clipCacheKey(source)
        if (announcedAspectFor.current !== key) {
          announcedAspectFor.current = key
          onNaturalAspectRef.current?.(shape, ratio)
        }
      })
      .catch(() => {
        if (!cancelled) {
          setImageUrl(null)
          setLoadState('error')
        }
      })
    return () => {
      cancelled = true
    }
    // shape 정체성은 클립 소스 필드들로 충분.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    renderClip,
    source?.crop?.height,
    source?.crop?.width,
    source?.crop?.x,
    source?.crop?.y,
    source?.page,
    source?.relPath,
    visible
  ])

  if (source === undefined) return null
  const failed = loadState === 'error'
  const ready = loadState === 'ready' && imageUrl !== null

  const boxScreenAspect = box.width > 0 ? (box.height * aspect) / box.width : 0
  const ratioMatches =
    naturalAspect !== null &&
    naturalAspect > 0 &&
    Math.abs(boxScreenAspect - naturalAspect) / naturalAspect <= 0.01

  if (ready) {
    return (
      <g ref={groupRef} className="ink-layer__clip-group">
        <image
          className="ink-layer__image-el"
          href={imageUrl}
          x={box.x}
          y={box.y}
          width={box.width}
          height={box.height}
          opacity={shape.style.opacity}
          preserveAspectRatio={ratioMatches ? 'none' : 'xMidYMid meet'}
          aria-label={source.label}
          onPointerDown={(event) => onBeginManipulation(event, shape, 'move')}
          onDoubleClick={(event) => {
            event.stopPropagation()
            onOpenClip?.(source)
          }}
        />
        <rect
          className="ink-layer__image-frame"
          x={box.x}
          y={box.y}
          width={box.width}
          height={box.height}
          vectorEffect="non-scaling-stroke"
        />
        {selected && (
          <ResizeHandles
            className="ink-layer__clip-resize"
            box={box}
            aspect={aspect}
            onPointerDown={(event, handle) =>
              onBeginManipulation(event, shape, 'resize', handle)}
          />
        )}
      </g>
    )
  }

  const foreignLayout = foreignObjectLayout(box, baseWidthPx, aspect)
  // Unmeasured surface: drawing now would size the border and radius against
  // the normalized viewBox and paint a huge wedge over the board.
  if (foreignLayout === null) return null

  return (
    <g ref={groupRef} className="ink-layer__clip-group">
      <foreignObject
        {...foreignLayout.objectProps}
        className="ink-layer__clip-object"
        style={{ opacity: shape.style.opacity, overflow: 'hidden' }}
        onPointerDown={(event) => onBeginManipulation(event, shape, 'move')}
        onDoubleClick={(event) => {
          event.stopPropagation()
          onOpenClip?.(source)
        }}
      >
        <div
          className="ink-layer__clip"
          style={foreignLayout.contentStyle}
          data-state={loadState}
          aria-label={`${source.label}${failed ? ', 원본을 찾을 수 없어요' : ''}`}
        >
          <div className="ink-layer__clip-placeholder">
            <strong>{source.label}</strong>
            <span>
              {failed ? '원본을 찾을 수 없어요' : '자료를 불러오는 중…'}
            </span>
          </div>
        </div>
      </foreignObject>
      {selected && (
        <ResizeHandles
          className="ink-layer__clip-resize"
          box={box}
          aspect={aspect}
          onPointerDown={(event, handle) =>
            onBeginManipulation(event, shape, 'resize', handle)}
        />
      )}
    </g>
  )
}
