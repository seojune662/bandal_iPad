/**
 * One virtualized PDF page: renders the real pdf.js page only when near the
 * viewport (placeholder box with the measured aspect ratio otherwise), plus
 * the absolutely-positioned highlight overlay.
 *
 * Highlight rects sit between the canvas and the text layer (z-index 1 vs
 * the text layer's 2) with pointer-events disabled, so text selection is
 * never blocked; clicks and hovers are resolved by hit-testing in the
 * wrapper's handlers.
 */

import {
  memo,
  useCallback,
  useRef,
  useState,
  type ClipboardEvent as ReactClipboardEvent,
  type DragEvent as ReactDragEvent
} from 'react'
import { Page } from 'react-pdf'
import { BufferedPdfCanvas } from './BufferedPdfCanvas'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { rectsContainPoint } from './lib/annotationGeometry'
import { DrawingLayer } from './tools/DrawingLayer'
import { usePdfToolStore } from './tools/toolStore'
import type { Annotation } from '../../../../shared/types/annotation'
import type {
  CreateDrawingInput,
  Drawing,
  DrawingClipSource,
  DrawingImageSource,
  UpdateDrawingInput
} from '../../../../shared/types/drawing'
import { TabKindIcon } from '../workspace/workspaceIcons'
import { fileToBase64, pastedImageFileName } from '../materials/clipboardPaste'
import { imageSourceFromFileDrop } from '../materials/imageDrag'
import {
  BANDAL_IMAGE_MIME,
  dataUrlImageAspect,
  imageBoxAtPoint,
  loadDrawingImage,
  primeDrawingImageCache,
  readBandalImageDragData
} from '../ink'
import { imageDataUrl } from '../image/imageSource'
import { pdfClipLabel, writeBandalClipDragData } from './clipTransfer'

const PDF_PASTED_IMAGE_DIRECTORY = 'images'

export interface PdfPageViewProps {
  pageNumber: number
  onFirstRender?: () => void
  onContextMenu?: (event: React.MouseEvent<HTMLElement>) => void
  /** Rendered CSS width of the page in px. */
  width: number
  /** height / width — placeholder sizing before the page ever renders. */
  aspect: number
  isVisible: boolean
  clipDragEnabled: boolean
  /** Sends this page to a whiteboard without needing one open to drag onto. */
  onSendClip: (
    source: DrawingClipSource,
    clientX: number,
    clientY: number
  ) => void
  annotations: Annotation[]
  drawings: Drawing[]
  drawingsLoading: boolean
  /** 패널 활성 여부 — 키보드 삭제가 활성 탭에만 반응하게. */
  drawingsInteractive: boolean
  courseId: string
  relPath: string
  staleIds: Set<string>
  hoveredId: string | null
  activeId: string | null
  flashId: string | null
  registerRef: (element: HTMLElement | null) => void
  onAspect: (page: number, aspect: number) => void
  /** Click resolved to an annotation (only fired when selection is empty). */
  onAnnotationClick: (annotation: Annotation, clientX: number, clientY: number) => void
  onHoverChange: (id: string | null) => void
  onDrawingCreate: (input: CreateDrawingInput) => Promise<Drawing | null>
  onDrawingUpdate: (input: UpdateDrawingInput) => Promise<Drawing | null>
  onDrawingRefine: (input: UpdateDrawingInput) => Promise<Drawing | null>
  onDrawingRemove: (ids: string[]) => Promise<boolean>
  onDrawingResolveId?: ((id: string) => string) | undefined
}

function annotationAtPoint(
  annotations: Annotation[],
  element: HTMLElement,
  clientX: number,
  clientY: number
): Annotation | null {
  const box = element.getBoundingClientRect()
  if (box.width <= 0 || box.height <= 0) return null
  const x = (clientX - box.left) / box.width
  const y = (clientY - box.top) / box.height
  // Last match wins → later (newer) annotations sit visually on top.
  let hit: Annotation | null = null
  for (const annotation of annotations) {
    if (rectsContainPoint(annotation.rects, x, y)) hit = annotation
  }
  return hit
}

function pointInPage(
  element: HTMLElement,
  clientX: number,
  clientY: number
): { x: number; y: number } | null {
  const bounds = element.getBoundingClientRect()
  if (bounds.width <= 0 || bounds.height <= 0) return null
  return {
    x: Math.min(1, Math.max(0, (clientX - bounds.left) / bounds.width)),
    y: Math.min(1, Math.max(0, (clientY - bounds.top) / bounds.height))
  }
}

function sameBox(
  left: Drawing['data']['box'],
  right: NonNullable<Drawing['data']['box']>
): boolean {
  return left !== undefined &&
    left.x === right.x &&
    left.y === right.y &&
    left.width === right.width &&
    left.height === right.height
}

function highlightClass(
  annotation: Annotation,
  props: Pick<PdfPageViewProps, 'hoveredId' | 'activeId' | 'flashId' | 'staleIds'>
): string {
  let className = 'pdf-highlight'
  if (annotation.id === props.hoveredId) className += ' is-hovered'
  if (annotation.id === props.activeId) className += ' is-active'
  if (annotation.id === props.flashId) className += ' is-flashing'
  if (props.staleIds.has(annotation.id)) className += ' is-stale'
  return className
}

function PdfPageViewInner(props: PdfPageViewProps): JSX.Element {
  const {
    pageNumber,
    width,
    aspect,
    isVisible,
    clipDragEnabled,
    onSendClip,
    annotations,
    drawings,
    drawingsLoading,
    drawingsInteractive,
    courseId,
    relPath,
    registerRef,
    onAspect,
    onAnnotationClick,
    onHoverChange,
    onDrawingCreate,
    onDrawingUpdate,
    onDrawingRefine,
    onDrawingRemove,
    onDrawingResolveId
  } = props

  const wrapperRef = useRef<HTMLElement | null>(null)
  const [pageWidthPt, setPageWidthPt] = useState(595.28)
  const hoverFrame = useRef<number | null>(null)
  const insertionPointRef = useRef({ x: 0.5, y: 0.5 })
  const drawingsRef = useRef(drawings)
  drawingsRef.current = drawings
  const drawingColor = usePdfToolStore((state) => state.color)
  const drawingWidth = usePdfToolStore((state) => state.width)

  const setRefs = useCallback(
    (element: HTMLElement | null): void => {
      wrapperRef.current = element
      registerRef(element)
    },
    [registerRef]
  )

  const handleClick = useCallback(
    (event: React.MouseEvent<HTMLElement>): void => {
      const selection = window.getSelection()
      if (selection !== null && !selection.isCollapsed) return
      const element = wrapperRef.current
      if (element === null) return
      const hit = annotationAtPoint(annotations, element, event.clientX, event.clientY)
      if (hit !== null) onAnnotationClick(hit, event.clientX, event.clientY)
    },
    [annotations, onAnnotationClick]
  )

  const handleMouseMove = useCallback(
    (event: React.MouseEvent<HTMLElement>): void => {
      const element = wrapperRef.current
      const point = element === null
        ? null
        : pointInPage(element, event.clientX, event.clientY)
      if (point !== null) insertionPointRef.current = point
      if (annotations.length === 0) return
      const { clientX, clientY } = event
      if (hoverFrame.current !== null) return
      hoverFrame.current = requestAnimationFrame(() => {
        hoverFrame.current = null
        const element = wrapperRef.current
        if (element === null) return
        const hit = annotationAtPoint(annotations, element, clientX, clientY)
        onHoverChange(hit?.id ?? null)
      })
    },
    [annotations, onHoverChange]
  )

  const handleMouseLeave = useCallback((): void => {
    onHoverChange(null)
  }, [onHoverChange])

  const placeImage = useCallback(async (
    source: DrawingImageSource,
    point: { x: number; y: number },
    knownImageAspect?: number
  ): Promise<void> => {
    const initialBox = imageBoxAtPoint(point, aspect, knownImageAspect ?? 1)
    const created = await onDrawingCreate({
      courseId,
      relPath,
      page: pageNumber,
      kind: 'image',
      data: { box: initialBox, image: source },
      style: { color: drawingColor, width: drawingWidth, opacity: 1 }
    })
    if (created === null) throw new Error('이미지 도형을 저장하지 못했습니다.')
    if (created.data.image === undefined) {
      await onDrawingRemove([created.id])
      throw new Error('이미지 경로를 저장하지 못했습니다.')
    }
    if (knownImageAspect !== undefined) return
    const dataUrl = await loadDrawingImage(courseId, source)
    const measuredAspect = dataUrl === null
      ? null
      : await dataUrlImageAspect(dataUrl)
    if (measuredAspect === null) return
    const current = drawingsRef.current.find((drawing) => drawing.id === created.id) ?? created
    if (!sameBox(current.data.box, initialBox)) return
    await onDrawingUpdate({
      id: created.id,
      data: {
        ...current.data,
        box: imageBoxAtPoint(point, aspect, measuredAspect),
        image: source
      }
    })
  }, [aspect, courseId, drawingColor, drawingWidth, onDrawingCreate,
    onDrawingRemove, onDrawingUpdate, pageNumber, relPath])

  const handlePaste = useCallback((event: ReactClipboardEvent<HTMLElement>): void => {
    const imageFiles = Array.from(event.clipboardData.files).filter((file) =>
      file.type.toLocaleLowerCase().startsWith('image/')
    )
    if (imageFiles.length === 0) return
    event.preventDefault()
    const origin = insertionPointRef.current
    void (async () => {
      const timestamp = new Date()
      for (const [index, file] of imageFiles.entries()) {
        const base64 = await fileToBase64(file)
        const result = await invoke('materials:writeFile', {
          courseId,
          dirRelPath: PDF_PASTED_IMAGE_DIRECTORY,
          createDirIfMissing: true,
          fileName: pastedImageFileName(file, timestamp),
          encoding: 'base64',
          data: base64
        })
        const source: DrawingImageSource = {
          relPath: result.relPath,
          label: result.relPath.split('/').at(-1) ?? result.relPath
        }
        const dataUrl = imageDataUrl(result.relPath, {
          encoding: 'base64',
          data: base64
        })
        if (dataUrl === null) throw new Error('지원하지 않는 이미지 형식입니다.')
        primeDrawingImageCache(courseId, source, dataUrl)
        const measuredAspect = await dataUrlImageAspect(dataUrl)
        const offset = Math.min(index, 8) * 0.025
        await placeImage(source, {
          x: Math.min(1, origin.x + offset),
          y: Math.min(1, origin.y + offset)
        }, measuredAspect ?? undefined)
      }
      showToast(
        imageFiles.length === 1
          ? '이미지를 붙여넣었어요.'
          : `${imageFiles.length}개 이미지를 붙여넣었어요.`
      )
    })().catch((error: unknown) => {
      console.error('[Bandal] PDF에 이미지를 붙여넣지 못했습니다.', error)
      showToast('이미지를 붙여넣지 못했습니다.', 'danger')
    })
  }, [courseId, placeImage])

  const handleDragOver = useCallback((event: ReactDragEvent<HTMLElement>): void => {
    const types = Array.from(event.dataTransfer.types)
    if (!types.includes(BANDAL_IMAGE_MIME) && !types.includes('Files')) return
    event.preventDefault()
    event.dataTransfer.dropEffect = 'copy'
  }, [])

  const handleDrop = useCallback((event: ReactDragEvent<HTMLElement>): void => {
    const source =
      readBandalImageDragData(event.dataTransfer) ??
      imageSourceFromFileDrop(courseId, event.dataTransfer)
    const element = wrapperRef.current
    if (source === null || element === null) return
    const point = pointInPage(element, event.clientX, event.clientY)
    if (point === null) return
    event.preventDefault()
    event.dataTransfer.dropEffect = 'copy'
    insertionPointRef.current = point
    void placeImage(source, point).catch((error: unknown) => {
      console.error('[Bandal] PDF에 이미지를 놓지 못했습니다.', error)
      showToast('이미지를 놓지 못했습니다.', 'danger')
    })
  }, [courseId, placeImage])

  const height = Math.round(width * aspect)
  const clipSource: DrawingClipSource = {
    relPath,
    page: pageNumber,
    pageAspect: aspect,
    label: pdfClipLabel(relPath, pageNumber, false)
  }

  return (
    <section
      ref={setRefs}
      className="pdf-page"
      data-pdf-page={pageNumber}
      aria-label={`${pageNumber} 페이지`}
      tabIndex={-1}
      style={{ width, height, outline: 'none' }}
      onPointerDown={(event) => {
        if (!(event.target instanceof Element)) return
        if (
          event.target.closest(
            'button, input, textarea, [contenteditable="true"], .textLayer'
          ) === null
        ) {
          event.currentTarget.focus({ preventScroll: true })
        }
      }}
      onContextMenu={props.onContextMenu}
      onClick={handleClick}
      onMouseMove={handleMouseMove}
      onMouseLeave={handleMouseLeave}
      onPaste={handlePaste}
      onDragOver={handleDragOver}
      onDrop={handleDrop}
    >
      {clipDragEnabled && (
        <button
          type="button"
          className="pdf-page__clip-drag"
          draggable
          aria-label={`${pageNumber} 페이지를 화이트보드로 보내기`}
          title="눌러서 화이트보드로 보내기 (끌어다 놓아도 돼요)"
          onPointerDown={(event) => event.stopPropagation()}
          onClick={(event) => {
            event.stopPropagation()
            const bounds = event.currentTarget.getBoundingClientRect()
            onSendClip(
              clipSource,
              bounds.left + bounds.width / 2,
              bounds.bottom
            )
          }}
          onDragStart={(event) => {
            event.stopPropagation()
            writeBandalClipDragData(event.dataTransfer, clipSource)
          }}
        >
          <TabKindIcon kind="whiteboard" />
          화이트보드로
        </button>
      )}
      {isVisible ? (
        <>
          <Page
            pageNumber={pageNumber}
            renderMode="none"
            width={width}
            renderTextLayer
            renderAnnotationLayer={false}
            loading={<div className="pdf-page__placeholder" style={{ height }} />}
            error={<div className="pdf-page__placeholder" style={{ height }} />}
            onRenderSuccess={() => props.onFirstRender?.()}
            onLoadSuccess={(page) => {
              const viewport = page.getViewport({ scale: 1 })
              if (viewport.width > 0) {
                setPageWidthPt(viewport.width)
                onAspect(pageNumber, viewport.height / viewport.width)
              }
            }}
          ><BufferedPdfCanvas /></Page>
          <div className="pdf-highlight-layer" aria-hidden="true">
            {annotations.map((annotation) =>
              annotation.rects.map((rect, index) => (
                <div
                  key={`${annotation.id}:${index}`}
                  className={highlightClass(annotation, props)}
                  data-color={annotation.color}
                  style={{
                    left: `${rect.x * 100}%`,
                    top: `${rect.y * 100}%`,
                    width: `${rect.width * 100}%`,
                    height: `${rect.height * 100}%`
                  }}
                />
              ))
            )}
          </div>
          <DrawingLayer
            courseId={courseId}
            relPath={relPath}
            page={pageNumber}
            pageWidth={width}
            pageWidthPt={pageWidthPt}
            aspect={aspect}
            drawings={drawings}
            loading={drawingsLoading}
            interactive={drawingsInteractive}
            create={onDrawingCreate}
            update={onDrawingUpdate}
            refine={onDrawingRefine}
            remove={onDrawingRemove}
            resolveId={onDrawingResolveId}
          />
        </>
      ) : (
        <div className="pdf-page__placeholder" style={{ height }} />
      )}
    </section>
  )
}

export const PdfPageView = memo(PdfPageViewInner)
