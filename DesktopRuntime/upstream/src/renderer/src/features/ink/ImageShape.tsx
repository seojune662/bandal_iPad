import {
  useEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent
} from 'react'
import type {
  DrawingBox,
  DrawingImageSource,
  DrawingShape
} from '../../../../shared/types/drawing'
import { invoke } from '../../lib/ipc'
import { imageDataUrl } from '../image/imageSource'
import { foreignObjectLayout } from './foreignObjectScale'
import { dataUrlImageAspect } from './imagePlacement'
import type { ResizeHandle } from './inkGeometry'
import { ResizeHandles } from './ResizeHandles'

interface ImageShapeProps {
  shape: DrawingShape
  box: DrawingBox
  aspect: number
  /** Pixel width of the surface; CSS inside the foreignObject is scaled by it. */
  baseWidthPx: number
  courseId?: string | undefined
  boardId?: string | undefined
  selected: boolean
  onBeginManipulation: (
    event: ReactPointerEvent<Element>,
    shape: DrawingShape,
    kind: 'move' | 'resize',
    handle?: ResizeHandle
  ) => void
  /**
   * 원본 세로/가로 비가 확정되면 1회 알린다 — 소유 표면이 `?? 1` 폴백으로
   * 굳은 box 를 조용히 치유(healedImageBox)하는 데 쓴다. 미배선이면 no-op.
   */
  onNaturalAspect?: ((shape: DrawingShape, naturalAspect: number) => void) | undefined
}

type LoadState = 'idle' | 'loading' | 'ready' | 'error'

const IMAGE_CACHE_LIMIT = 48
const imageCache = new Map<string, Promise<string | null>>()
function cacheKey(scope: 'course' | 'board', ownerId: string, imageId: string): string {
  return JSON.stringify([scope, ownerId, imageId])
}

function touchCache(key: string, value: Promise<string | null>): void {
  imageCache.delete(key)
  imageCache.set(key, value)
  while (imageCache.size > IMAGE_CACHE_LIMIT) {
    const oldest = imageCache.keys().next().value as string | undefined
    if (oldest === undefined) return
    imageCache.delete(oldest)
  }
}

export function primeDrawingImageCache(
  courseId: string,
  source: DrawingImageSource,
  dataUrl: string
): void {
  touchCache(cacheKey('course', courseId, source.relPath), Promise.resolve(dataUrl))
}

export function primeSharedDrawingImageCache(
  boardId: string,
  source: DrawingImageSource,
  dataUrl: string
): void {
  if (source.assetId === undefined) return
  touchCache(cacheKey('board', boardId, source.assetId), Promise.resolve(dataUrl))
}

export function loadDrawingImage(
  courseId: string,
  source: DrawingImageSource
): Promise<string | null> {
  const key = cacheKey('course', courseId, source.relPath)
  const cached = imageCache.get(key)
  if (cached !== undefined) {
    touchCache(key, cached)
    return cached
  }
  const pending = invoke('materials:readFile', {
    courseId,
    relPath: source.relPath
  }).then((content) => imageDataUrl(source.relPath, content)).catch(() => null)
  touchCache(key, pending)
  void pending.then((url) => {
    if (url === null && imageCache.get(key) === pending) imageCache.delete(key)
  })
  return pending
}

export function loadSharedDrawingImage(
  boardId: string,
  source: DrawingImageSource
): Promise<string | null> {
  if (source.assetId === undefined) return Promise.resolve(null)
  const key = cacheKey('board', boardId, source.assetId)
  const cached = imageCache.get(key)
  if (cached !== undefined) {
    touchCache(key, cached)
    return cached
  }
  // Legacy shared-board assets remain in storage; this app no longer fetches them.
  const pending = Promise.resolve<string | null>(null)
  touchCache(key, pending)
  void pending.then((url) => {
    if (url === null && imageCache.get(key) === pending) imageCache.delete(key)
  })
  return pending
}

function visibleWithoutObserver(element: Element): boolean {
  const rect = element.getBoundingClientRect()
  return (
    rect.width > 0 &&
    rect.height > 0 &&
    rect.bottom > 0 &&
    rect.right > 0 &&
    rect.top < window.innerHeight &&
    rect.left < window.innerWidth
  )
}

export function observeImageVisibility(
  element: Element,
  onVisible: (visible: boolean) => void
): () => void {
  if (visibleWithoutObserver(element)) onVisible(true)
  if (typeof IntersectionObserver === 'undefined') return () => undefined

  const observer = new IntersectionObserver((entries) => {
    onVisible(entries.some((entry) => entry.isIntersecting))
  })
  observer.observe(element)
  return () => observer.disconnect()
}

export function ImageShape({
  shape,
  box,
  aspect,
  baseWidthPx,
  courseId,
  boardId,
  selected,
  onBeginManipulation,
  onNaturalAspect
}: ImageShapeProps): JSX.Element | null {
  const source = shape.data.image
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
    if (element === null) return
    return observeImageVisibility(element, setVisible)
  }, [])

  useEffect(() => {
    if (!visible || source === undefined) return
    const shared = source.storage === 'shared' && source.assetId !== undefined
    if ((!shared && courseId === undefined) || (shared && boardId === undefined)) {
      setLoadState('error')
      setImageUrl(null)
      return
    }
    let cancelled = false
    setLoadState('loading')
    setImageUrl(null)
    setNaturalAspect(null)
    const pending = shared
      ? loadSharedDrawingImage(boardId as string, source)
      : loadDrawingImage(courseId as string, source)
    void pending
      .then(async (url) => {
        if (url === null) return { url: null, ratio: null }
        // 디코드 검증 겸 원본 비율 취득 — SVG <image> 는 onLoad 가 없다.
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
        const sourceId = source.assetId ?? source.relPath
        if (announcedAspectFor.current !== sourceId) {
          announcedAspectFor.current = sourceId
          onNaturalAspectRef.current?.(shape, ratio)
        }
      })
    return () => {
      cancelled = true
    }
    // shape 정체성은 relPath 로 충분 — shape 객체 참조로 재로드하지 않는다.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [boardId, courseId, source?.assetId, source?.relPath, source?.storage, visible])

  if (source === undefined) return null
  const failed = loadState === 'error'
  const ready = loadState === 'ready' && imageUrl !== null

  // box 화면 비율이 원본과 맞으면 "none"으로 box 를 정확히 채워 핸들과
  // 픽셀 단위로 일치시킨다. 안 맞으면(미치유 레거시·healing 미배선 표면)
  // 기존 object-fit: contain 과 같은 레터박스(meet)로 찌그러짐을 막는다.
  const boxScreenAspect = box.width > 0 ? (box.height * aspect) / box.width : 0
  const ratioMatches =
    naturalAspect !== null &&
    naturalAspect > 0 &&
    Math.abs(boxScreenAspect - naturalAspect) / naturalAspect <= 0.01

  if (ready) {
    return (
      <g ref={groupRef} className="ink-layer__image-group">
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
            className="ink-layer__image-resize"
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
  // Never render CSS pixels directly into the normalized SVG viewBox.
  if (foreignLayout === null) return null

  return (
    <g ref={groupRef} className="ink-layer__image-group">
      <foreignObject
        {...foreignLayout.objectProps}
        className="ink-layer__image-object"
        style={{ opacity: shape.style.opacity, overflow: 'hidden' }}
        onPointerDown={(event) => onBeginManipulation(event, shape, 'move')}
      >
        <div
          className="ink-layer__image"
          style={foreignLayout.contentStyle}
          data-state={loadState}
          aria-label={`${source.label}${failed ? ', 원본을 찾을 수 없어요' : ''}`}
        >
          <div className="ink-layer__image-placeholder">
            <strong>{source.label}</strong>
            <span>
              {failed ? '원본을 찾을 수 없어요' : '이미지를 불러오는 중…'}
            </span>
          </div>
        </div>
      </foreignObject>
      {selected && (
        <ResizeHandles
          className="ink-layer__image-resize"
          box={box}
          aspect={aspect}
          onPointerDown={(event, handle) =>
            onBeginManipulation(event, shape, 'resize', handle)}
        />
      )}
    </g>
  )
}
