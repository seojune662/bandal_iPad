import type { IDockviewPanelProps } from 'dockview'
import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react'
import { invoke } from '../../lib/ipc'
import { isTabDescriptor } from '../workspace/tabIdentity'
import { useHasBeenShown } from '../workspace/useHasBeenShown'
import { imageDataUrl } from './imageSource'
import './image.css'

const MIN_ZOOM = 0.1
const MAX_ZOOM = 8
const ZOOM_STEP = 1.25

type ViewMode = 'fit' | 'zoom'

type ImageLoadState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'ready'; dataUrl: string }

interface NaturalSize {
  width: number
  height: number
}

function fileName(relPath: string): string {
  return relPath.split('/').at(-1) ?? relPath
}

function ImageError(): JSX.Element {
  return (
    <div className="image-viewer__status" data-state="error" role="alert">
      <h2>이미지를 열 수 없어요</h2>
      <p>파일이 없거나 읽을 수 없는 이미지예요.</p>
    </div>
  )
}

function ImageViewer({
  courseId,
  relPath
}: {
  courseId: string
  relPath: string
}): JSX.Element {
  const [loadState, setLoadState] = useState<ImageLoadState>({ status: 'loading' })
  const [viewMode, setViewMode] = useState<ViewMode>('fit')
  const [zoom, setZoom] = useState(1)
  const [naturalSize, setNaturalSize] = useState<NaturalSize | null>(null)
  const imageRef = useRef<HTMLImageElement>(null)

  useEffect(() => {
    let cancelled = false
    setLoadState({ status: 'loading' })

    void invoke('materials:readFile', { courseId, relPath })
      .then((content) => {
        if (cancelled) return
        const dataUrl = imageDataUrl(relPath, content)
        setLoadState(dataUrl === null ? { status: 'error' } : { status: 'ready', dataUrl })
      })
      .catch(() => {
        if (!cancelled) setLoadState({ status: 'error' })
      })

    return () => {
      cancelled = true
    }
  }, [courseId, relPath])

  const zoomBy = useCallback(
    (factor: number): void => {
      let baseZoom = zoom
      const image = imageRef.current
      if (viewMode === 'fit' && image !== null && image.naturalWidth > 0) {
        baseZoom = image.getBoundingClientRect().width / image.naturalWidth
      }
      setZoom(Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, baseZoom * factor)))
      setViewMode('zoom')
    },
    [viewMode, zoom]
  )

  if (loadState.status === 'loading') {
    return (
      <div className="image-viewer__status" data-state="loading" role="status">
        이미지를 불러오는 중…
      </div>
    )
  }

  if (loadState.status === 'error') return <ImageError />

  const zoomPercent = Math.round(zoom * 100)
  const imageStyle =
    viewMode === 'zoom' && naturalSize !== null
      ? ({ width: naturalSize.width * zoom } as CSSProperties)
      : undefined

  return (
    <div className="image-viewer" data-state="ready">
      <div className="image-viewer__toolbar" role="toolbar" aria-label="이미지 보기 도구">
        <button
          type="button"
          className="image-viewer__button"
          aria-pressed={viewMode === 'fit'}
          onClick={() => setViewMode('fit')}
        >
          창에 맞추기
        </button>
        <button
          type="button"
          className="image-viewer__button"
          aria-pressed={viewMode === 'zoom' && zoom === 1}
          onClick={() => {
            setZoom(1)
            setViewMode('zoom')
          }}
        >
          100% 원본
        </button>
        <button
          type="button"
          className="image-viewer__button"
          disabled={viewMode === 'zoom' && zoom <= MIN_ZOOM}
          onClick={() => zoomBy(1 / ZOOM_STEP)}
        >
          축소
        </button>
        <output className="image-viewer__zoom" aria-live="polite">
          {viewMode === 'fit' ? '창 맞춤' : `${zoomPercent}%`}
        </output>
        <button
          type="button"
          className="image-viewer__button"
          disabled={viewMode === 'zoom' && zoom >= MAX_ZOOM}
          onClick={() => zoomBy(ZOOM_STEP)}
        >
          확대
        </button>
      </div>

      <div className="image-viewer__viewport">
        <div className="image-viewer__stage" data-mode={viewMode}>
          <img
            ref={imageRef}
            className="image-viewer__image"
            src={loadState.dataUrl}
            alt={fileName(relPath)}
            draggable={false}
            style={imageStyle}
            onLoad={(event) => {
              const { naturalWidth, naturalHeight } = event.currentTarget
              if (naturalWidth === 0 || naturalHeight === 0) {
                setLoadState({ status: 'error' })
                return
              }
              setNaturalSize({ width: naturalWidth, height: naturalHeight })
            }}
            onError={() => setLoadState({ status: 'error' })}
          />
        </div>
      </div>
    </div>
  )
}

export default function ImageTab(props: IDockviewPanelProps): JSX.Element {
  const hasBeenShown = useHasBeenShown(props.api)
  const candidate = props.params['descriptor']
  if (!isTabDescriptor(candidate) || candidate.kind !== 'image') {
    return (
      <div className="workspace-panel image-panel" data-kind="image">
        <ImageError />
      </div>
    )
  }
  if (!hasBeenShown) {
    return (
      <div className="workspace-panel image-panel" data-kind="image">
        <div className="image-viewer__status" data-state="loading" role="status">
          이미지를 불러오는 중…
        </div>
      </div>
    )
  }

  const { courseId, relPath } = candidate.payload
  return (
    <div className="workspace-panel image-panel" data-kind="image">
      <ImageViewer
        key={`${courseId}:${relPath}`}
        courseId={courseId}
        relPath={relPath}
      />
    </div>
  )
}
