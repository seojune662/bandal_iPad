import { usePanelAssistant } from '../assistantPanel/panelContext'
import { registerDocumentContext } from '../agent/documentContext'
/**
 * [M3-D] PDF viewer tab — dockview panel component for TabKind 'pdf'.
 *
 * Drop-in replacement for the M2 placeholder: reads its TabDescriptor from
 * `props.params.descriptor` (same contract as PlaceholderPanel). Loads the
 * material over `materials:readFile`, renders a virtualized react-pdf page
 * list with text-selection highlighting, an annotation rail, and per-file
 * scroll/zoom memory (session LRU).
 */

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState
} from 'react'
import { Document } from 'react-pdf'
import type { IDockviewPanelProps } from 'dockview'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { configurePdfWorker } from './pdfWorker'
import 'react-pdf/dist/Page/TextLayer.css'
import './pdf.css'
import { isTabDescriptor } from '../workspace/tabIdentity'
import { useHasBeenShown } from '../workspace/useHasBeenShown'
import { usePanelActive } from '../workspace/usePanelActive'
import { usePanelVisible } from '../workspace/usePanelVisible'
import { mediaUrlFor } from '../materials/mediaUrl'
import { useAnnotations } from './useAnnotations'
import { usePageTexts, useStaleAnnotationIds } from './usePageTexts'
import {
  useVisiblePages,
  type PdfViewportAnchor
} from './useVisiblePages'
import { PdfToolbar } from './PdfToolbar'
import { TextFormatRow } from '../ink/TextFormatRow'
import { wheelZoomFactor } from './lib/zoomInput'
import { PdfPageView } from './PdfPageView'
import { usePageImageCopy } from '../pageImageCopy/usePageImageCopy'
import { renderPdfPageImage } from './lib/renderPageImage'
import { PdfPreviewPanel } from './PdfPreviewPanel'
import { AnnotationRail } from './AnnotationRail'
import {
  HighlightPopover,
  SelectionPopover,
  WhiteboardPickerPopover,
  type ContentPoint
} from './popovers'
import { askAiAboutAnnotation, buildAnnotationPrompt } from './askAi'
import {
  PDF_ANNOTATION_JUMP_EVENT,
  type PdfAnnotationJumpDetail
} from '../notes/materialLinkNavigation'
import { readPageSelection } from './lib/domSelection'
import { normalizeSelectionRects, rectsBoundingBox } from './lib/annotationGeometry'
import { pdfScrollMemory } from './lib/scrollMemory'
import { PdfViewportResize } from './lib/viewportResize'
import { useDrawings } from './tools/useDrawings'
import { usePdfToolStore } from './tools/toolStore'
import type {
  Annotation,
  AnnotationAnchor,
  AnnotationRect,
  HighlightColor
} from '../../../../shared/types/annotation'
import type { Drawing } from '../../../../shared/types/drawing'
import type { TabDescriptor } from '../../../../shared/tabs'
import {
  isPdfPageNotePairContext,
  parsePdfPageNote,
  reconcilePdfPageNote,
  serializePdfPageNote,
  type PdfPageNotePairContext
} from '../../../../shared/pdfPageNote'
import { pdfClipLabel } from './clipTransfer'
import {
  PDF_PAGE_NAVIGATION_EVENT,
  takePdfPageNavigation,
  type PdfPageNavigationTarget
} from './pdfPageNavigation'
import { useWhiteboardClipDelivery } from './useWhiteboardClipDelivery'
import {
  PdfPageNoteDialog,
  readPdfPageSizes
} from '../links/PdfPageNoteDialog'
import {
  requestMaterialConnectionsRefresh,
  useMaterialConnections
} from '../links/useMaterialConnections'
import {
  claimPageSyncInput,
  publishPageSyncAnchor,
  subscribePageSyncAnchor,
  usePageNoteSync
} from '../links/pdfPageNoteSync'
import { PageSyncScroll } from '../links/pageSyncScroll'
import {
  subscribeOpenPdfPageNote,
  takeOpenPdfPageNote
} from '../links/pdfPageNoteNavigation'

configurePdfWorker()

const ZOOM_MIN = 0.4
const ZOOM_MAX = 4
const ZOOM_STEP = 1.15
/**
 * 반드시 모듈 레벨 상수 — react-pdf 는 options 참조가 바뀌면 문서를
 * 재로드한다. lazy 모드(range fetch)로 대형 PDF 도 첫 페이지 청크만 읽는다.
 */
const PDF_DOCUMENT_OPTIONS = {
  disableStream: true,
  disableAutoFetch: true,
  rangeChunkSize: 1048576
}
/** A4 portrait height/width — placeholder ratio before first measure. */
const DEFAULT_PAGE_ASPECT = Math.SQRT2
const PAGE_GUTTER_PX = 48
const MIN_PAGE_WIDTH_PX = 180
const FLASH_DURATION_MS = 1600
const SCROLL_SAVE_DEBOUNCE_MS = 250
const JUMP_TOP_OFFSET_PX = 88
const EMPTY_ANNOTATIONS: Annotation[] = []
const EMPTY_DRAWINGS: Drawing[] = []

interface PendingSelection {
  page: number
  anchor: AnnotationAnchor
  rects: AnnotationRect[]
  position: ContentPoint
}

interface EditPopoverState {
  annotationId: string
  position: ContentPoint
}

function descriptorFromParams(params: unknown): TabDescriptor | null {
  if (typeof params !== 'object' || params === null) return null
  const candidate = (params as Record<string, unknown>)['descriptor']
  return isTabDescriptor(candidate) ? candidate : null
}

function LoadingSkeleton(): JSX.Element {
  return (
    <div className="pdf-skeleton" aria-label="PDF 불러오는 중" role="status">
      <div className="pdf-skeleton__page" />
      <div className="pdf-skeleton__page" />
    </div>
  )
}

function ErrorPanel({ message }: { message: string }): JSX.Element {
  return (
    <div className="pdf-error" role="alert">
      <span className="pdf-error__mark" aria-hidden="true">
        !
      </span>
      <h2>PDF를 열 수 없어요</h2>
      <p>{message}</p>
    </div>
  )
}

function PdfViewer({
  courseId,
  relPath,
  interactive,
  visible,
  panelId,
  pageNotePair
}: {
  courseId: string
  relPath: string
  interactive: boolean
  visible: boolean
  panelId: string
  pageNotePair: PdfPageNotePairContext | null
}): JSX.Element {
  const assistant = usePanelAssistant()
  // 문서 소스는 bandal-media:// URL — pdf.js 가 Range 요청으로 필요한
  // 페이지만 가져온다. base64-over-IPC 시절의 64MB 캡·메모리 상주가 없다.
  const fileSource = useMemo(
    () => ({ url: mediaUrlFor(courseId, relPath) }),
    [courseId, relPath]
  )
  const [loadError, setLoadError] = useState<string | null>(null)
  const annotationsApi = useAnnotations(courseId, relPath)
  const { annotations, byPage } = annotationsApi
  const drawingsApi = useDrawings(courseId, relPath)
  const activeTool = usePdfToolStore((state) => state.activeTool)

  const scrollerRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)
  const whiteboardClip = useWhiteboardClipDelivery(courseId, contentRef)
  const {
    visiblePages,
    registerPage,
    elementFor,
    pageAtViewportCenter,
    captureViewportAnchor,
    restoreViewportAnchor,
    invalidatePageOffsets
  } = useVisiblePages(scrollerRef)

  const [firstPageRendered, setFirstPageRendered] = useState(false)
  const markFirstRender = useCallback(() => setFirstPageRendered(true), [])
  const [pdfProxy, setPdfProxy] = useState<PDFDocumentProxy | null>(null)
  const copyIdentity = useMemo(() => ({ fileSource, pdfProxy }), [fileSource, pdfProxy])
  const pageImageCopy = usePageImageCopy(copyIdentity)
  const [numPages, setNumPages] = useState(0)
  const [pageAspects, setPageAspects] = useState<Map<number, number>>(new Map())
  const [containerWidth, setContainerWidth] = useState(0)
  const [containerHeight, setContainerHeight] = useState(0)
  const [zoom, setZoom] = useState<number>(
    () => pdfScrollMemory.get(courseId, relPath)?.zoom ?? 1
  )
  const [currentPage, setCurrentPage] = useState(1)
  const aiPageText = useRef('')
  useEffect(() => {
    let live = true; aiPageText.current = ''
    if (pdfProxy) void pdfProxy.getPage(currentPage).then(page => page.getTextContent()).then(content => { if (live) aiPageText.current = content.items.map(item => 'str' in item ? item.str : '').join(' ').slice(0, 10000) }).catch(() => {})
    const off = registerDocumentContext(panelId, () => ({ courseId, kind: 'pdf', title: relPath.split('/').pop() ?? relPath, relPath, page: currentPage, text: aiPageText.current }))
    return () => { live = false; off() }
  }, [courseId, relPath, currentPage, pdfProxy, panelId])

  const [isPreviewOpen, setIsPreviewOpen] = useState(false)
  const [localRailOpen, setLocalRailOpen] = useState(false)
  const isRailOpen = assistant?.highlightsOpen ?? localRailOpen
  const setIsRailOpen = (open: boolean | ((value: boolean) => boolean)): void => {
    const next = typeof open === 'function' ? open(isRailOpen) : open
    if (assistant) assistant.setHighlightsOpen(next)
    else setLocalRailOpen(next)
  }
  const [isPageNoteDialogOpen, setIsPageNoteDialogOpen] = useState(false)
  const [pendingSelection, setPendingSelection] =
    useState<PendingSelection | null>(null)
  const [textSelectionActive, setTextSelectionActive] = useState(false)
  const textSelectionActiveRef = useRef(false)
  const [editPopover, setEditPopover] = useState<EditPopoverState | null>(null)
  const [hoveredId, setHoveredId] = useState<string | null>(null)
  const [flashId, setFlashId] = useState<string | null>(null)

  useEffect(() => {
    if (activeTool !== 'select') {
      setPendingSelection(null)
      setEditPopover(null)
      window.getSelection()?.removeAllRanges()
    }
  }, [activeTool])

  const zoomRef = useRef(zoom)
  const visibleRef = useRef(visible)
  visibleRef.current = visible
  const currentPageRef = useRef(currentPage)
  currentPageRef.current = currentPage
  const containerWidthRef = useRef(containerWidth)
  const containerHeightRef = useRef(containerHeight)
  const restoreRef = useRef({ done: false, cancelled: false })
  const restoreMountedRef = useRef(true)
  const restoreFrameRef = useRef<number | null>(null)
  const initialRestoreAnchorRef = useRef<PdfViewportAnchor | null>(null)
  const initialRestorePageRef = useRef<number | null>(null)
  const pendingLayoutAnchorRef = useRef<PdfViewportAnchor | null>(null)
  const viewportResize = useRef(new PdfViewportResize())
  const resizeSettleFrame = useRef<number | null>(null)
  const cancelViewportResize = useCallback((): void => {
    if (pendingLayoutAnchorRef.current === viewportResize.current.anchor) pendingLayoutAnchorRef.current = null
    viewportResize.current.cancel()
    if (resizeSettleFrame.current !== null) cancelAnimationFrame(resizeSettleFrame.current)
    resizeSettleFrame.current = null
  }, [])
  const cancelInitialRestore = useCallback((): void => {
    cancelViewportResize()
    restoreRef.current.cancelled = true
    if (restoreFrameRef.current !== null) cancelAnimationFrame(restoreFrameRef.current)
    restoreFrameRef.current = null
    if (initialRestoreAnchorRef.current !== null && pendingLayoutAnchorRef.current === initialRestoreAnchorRef.current) {
      pendingLayoutAnchorRef.current = null
    }
    initialRestoreAnchorRef.current = null
    initialRestorePageRef.current = null
  }, [cancelViewportResize])
  const jumpToPageRef = useRef<(page: number, restoring?: boolean) => void>(() => {})
  const viewAnchorRef = useRef<PdfViewportAnchor | null>(null)
  const zoomPointRef = useRef<{ page: number; x: number; y: number; clientX: number; clientY: number } | null>(null)
  const zoomGesturePointRef = useRef<typeof zoomPointRef.current>(null)
  const zoomFrameRef = useRef<number | null>(null)
  const zoomPinnedPages = useRef(new Set<number>())
  const zoomEndTimer = useRef<number | null>(null)
  const [zooming, setZooming] = useState(false)
  const wasVisibleRef = useRef(visible)
  const flashTimer = useRef<number | null>(null)
  const scrollFrame = useRef<number | null>(null)
  const saveTimer = useRef<number | null>(null)
  const reconciledFingerprintRef = useRef<string | null>(null)
  const pageSyncScroll = useRef(new PageSyncScroll())
  const connections = useMaterialConnections(courseId, relPath)
  const pageNoteConnections = useMemo(
    () =>
      connections.outgoing.filter(
        (record) => record.kind === 'pdf-page-note' && record.target.kind === 'note'
      ),
    [connections.outgoing]
  )
  const pairedConnection = useMemo(
    () =>
      pageNotePair === null
        ? null
        : pageNoteConnections.find(
            (record) => record.id === pageNotePair.connectionId
          ) ?? null,
    [pageNoteConnections, pageNotePair]
  )
  const [pageNoteSync, setPageNoteSync] = usePageNoteSync(
    pageNotePair?.pairId ?? null,
    pairedConnection?.metadata?.syncScroll ?? true
  )
  useEffect(() => {
    if (pageNotePair !== null && pairedConnection?.metadata !== null && pairedConnection !== null) {
      setPageNoteSync(pairedConnection.metadata.syncScroll)
    }
  }, [pageNotePair, pairedConnection, setPageNoteSync])

  useEffect(() => {
    if (pdfProxy === null || pageNoteConnections.length === 0) return
    const fingerprint = pdfProxy.fingerprints[0] ?? ''
    const stale = pageNoteConnections.filter(
      (record) =>
        record.metadata !== null &&
        (record.metadata.fingerprint !== fingerprint ||
          record.metadata.pageSizes.length !== pdfProxy.numPages)
    )
    const reconcileKey = `${fingerprint}:${pdfProxy.numPages}`
    if (stale.length === 0 || reconciledFingerprintRef.current === reconcileKey) return
    reconciledFingerprintRef.current = reconcileKey
    let disposed = false
    void readPdfPageSizes(pdfProxy).then(async (pageSizes) => {
      for (const record of stale) {
        if (disposed || record.target.kind !== 'note') return
        try {
          const note = await invoke('notes:read', record.target.payload)
          const document = parsePdfPageNote(note.markdown)
          if (document === null) continue
          const reconciled = reconcilePdfPageNote(
            document,
            relPath,
            fingerprint,
            pageSizes
          )
          await invoke('notes:write', {
            ...record.target.payload,
            markdown: serializePdfPageNote(reconciled),
            expectedMtime: note.mtime
          })
          await invoke('links:updatePageNote', {
            courseId,
            id: record.id,
            metadata: {
              version: 1,
              syncScroll: record.metadata?.syncScroll ?? true,
              fingerprint,
              pageSizes
            }
          })
        } catch (error) {
          console.error('[Bandal] 변경된 PDF와 페이지 필기를 맞추지 못했습니다.', error)
        }
      }
      if (!disposed) requestMaterialConnectionsRefresh(courseId)
    }).catch((error: unknown) => {
      console.error('[Bandal] 변경된 PDF의 페이지 크기를 읽지 못했습니다.', error)
    })
    return () => {
      disposed = true
    }
  }, [courseId, pageNoteConnections, pdfProxy, relPath])

  useEffect(() => {
    if (pdfProxy === null) return
    const openIfMatching = (target: { courseId: string; relPath: string }): void => {
      if (target.courseId !== courseId || target.relPath !== relPath) return
      takeOpenPdfPageNote(courseId, relPath)
      setIsPageNoteDialogOpen(true)
    }
    const stop = subscribeOpenPdfPageNote(openIfMatching)
    if (takeOpenPdfPageNote(courseId, relPath)) setIsPageNoteDialogOpen(true)
    return stop
  }, [courseId, pdfProxy, relPath])

  const rememberViewportAnchor = useCallback((): PdfViewportAnchor | null => {
    if (viewportResize.current.anchor !== null) return viewportResize.current.anchor
    if (scrollerRef.current && viewportResize.current.isScrollEcho(scrollerRef.current.scrollTop)) return viewAnchorRef.current
    // ResizeObserver runs after CSS has already changed the viewport. A
    // scroll event in that frame must not replace the pre-resize position
    // with one measured from the new toolbar/viewport height.
    if (pendingLayoutAnchorRef.current !== null) return pendingLayoutAnchorRef.current
    const scroller = scrollerRef.current
    if (scroller !== null && (
      (containerWidthRef.current > 0 && scroller.clientWidth !== containerWidthRef.current) ||
      (containerHeightRef.current > 0 && scroller.clientHeight !== containerHeightRef.current)
    )) {
      return viewAnchorRef.current
    }
    const anchor = captureViewportAnchor()
    if (anchor !== null) viewAnchorRef.current = anchor
    return anchor ?? viewAnchorRef.current
  }, [captureViewportAnchor])

  const annotatedPages = useMemo(
    () => [...byPage.keys()].sort((a, b) => a - b),
    [byPage]
  )
  const pageTexts = usePageTexts(firstPageRendered ? pdfProxy : null, annotatedPages)
  const staleIds = useStaleAnnotationIds(annotations, pageTexts)
  const pageOfAnnotation = useMemo(() => {
    const map = new Map<string, number>()
    for (const annotation of annotations) map.set(annotation.id, annotation.page)
    return map
  }, [annotations])

  // -- layout: container width ---------------------------------------------
  useEffect(() => {
    const scroller = scrollerRef.current
    if (scroller === null) return
    const observer = new ResizeObserver(() => {
      const width = scroller.clientWidth
      const height = scroller.clientHeight
      // Dockview's `always` renderer can temporarily give an inactive panel a
      // zero-sized box. Treat that as hidden, not as a real fit-width request:
      // rendering every page at MIN_PAGE_WIDTH would clamp scrollTop to a
      // different page before the tab is shown again.
      if (width <= 0 || height <= 0 ||
        (width === containerWidthRef.current && height === containerHeightRef.current)) return
      if (numPages > 0) {
        viewportResize.current.begin(pendingLayoutAnchorRef.current ?? viewAnchorRef.current, {
          width, height,
          pageWidth: Math.max(MIN_PAGE_WIDTH_PX, Math.round((width - PAGE_GUTTER_PX) * zoomRef.current))
        })
        pendingLayoutAnchorRef.current ??= viewportResize.current.anchor
      }
      invalidatePageOffsets()
      containerWidthRef.current = width
      containerHeightRef.current = height
      setContainerWidth(width)
      setContainerHeight(height)
    })
    observer.observe(scroller)
    if (scroller.clientWidth > 0) {
      containerWidthRef.current = scroller.clientWidth
      containerHeightRef.current = scroller.clientHeight
      setContainerWidth(scroller.clientWidth)
      setContainerHeight(scroller.clientHeight)
    }
    return () => observer.disconnect()
  }, [invalidatePageOffsets, numPages, rememberViewportAnchor])

  const defaultAspect = pageAspects.get(1) ?? DEFAULT_PAGE_ASPECT
  const pageWidth = Math.max(
    MIN_PAGE_WIDTH_PX,
    Math.round((containerWidth - PAGE_GUTTER_PX) * zoom)
  )

  const settleViewportResize = useCallback((): void => {
    if (resizeSettleFrame.current !== null) cancelAnimationFrame(resizeSettleFrame.current)
    const settle = (): void => {
      resizeSettleFrame.current = null
      const anchor = viewportResize.current.anchor
      const scroller = scrollerRef.current
      if (anchor === null || scroller === null || !visibleRef.current) return
      if (restoreViewportAnchor(anchor)) {
        viewAnchorRef.current = anchor
        viewportResize.current.recordRestoredScroll(scroller.scrollTop)
      }
      const settled = viewportResize.current.observe({
        width: scroller.clientWidth,
        height: scroller.clientHeight,
        pageWidth: elementFor(anchor.page)?.getBoundingClientRect().width ?? 0
      })
      if (!settled) resizeSettleFrame.current = requestAnimationFrame(settle)
    }
    resizeSettleFrame.current = requestAnimationFrame(settle)
  }, [elementFor, restoreViewportAnchor])

  useEffect(() => () => {
    if (resizeSettleFrame.current !== null) cancelAnimationFrame(resizeSettleFrame.current)
  }, [])

  // Page boxes only move when document layout changes. Rebuild their cached
  // centers here; ordinary scroll frames only perform a binary search.
  useLayoutEffect(() => {
    invalidatePageOffsets()
    if (numPages === 0 || !visible) {
      wasVisibleRef.current = visible
      return
    }

    // Saved zoom changes the page boxes. Finish its page jump against those
    // committed boxes, while a newer gesture can still cancel this work.
    if (initialRestorePageRef.current !== null) {
      const page = initialRestorePageRef.current
      initialRestorePageRef.current = null
      if (restoreMountedRef.current && !restoreRef.current.cancelled) {
        initialRestoreAnchorRef.current = null
        pendingLayoutAnchorRef.current = null
        jumpToPageRef.current(page, true)
        return
      }
    }

    const zoomPoint = zoomPointRef.current
    const zoomElement = zoomPoint ? elementFor(zoomPoint.page) : null
    const scroller = scrollerRef.current
    if (zoomPoint && zoomElement && scroller) {
      const box = zoomElement.getBoundingClientRect()
      scroller.scrollLeft += box.left + box.width * zoomPoint.x - zoomPoint.clientX
      scroller.scrollTop += box.top + box.height * zoomPoint.y - zoomPoint.clientY
      zoomPointRef.current = null
      pendingLayoutAnchorRef.current = null
      rememberViewportAnchor()
      return
    }
    const becameVisible = !wasVisibleRef.current
    wasVisibleRef.current = true
    const anchor =
      pendingLayoutAnchorRef.current ??
      viewportResize.current.anchor ??
      (becameVisible ? viewAnchorRef.current : null)
    if (anchor !== null && restoreViewportAnchor(anchor)) {
      pendingLayoutAnchorRef.current = null
      viewAnchorRef.current = anchor
      viewportResize.current.recordRestoredScroll(scrollerRef.current?.scrollTop ?? 0)
      if (viewportResize.current.anchor !== null) settleViewportResize()
      setCurrentPage(anchor.page)
      return
    }

    const current = rememberViewportAnchor()
    setCurrentPage(current?.page ?? pageAtViewportCenter())
  }, [
    pageWidth,
    containerWidth,
    containerHeight,
    pageAspects,
    numPages,
    visible,
    invalidatePageOffsets,
    pageAtViewportCenter,
    rememberViewportAnchor,
    restoreViewportAnchor,
    settleViewportResize
  ])

  // -- zoom -----------------------------------------------------------------
  const applyZoom = useCallback((next: number, point?: { clientX: number; clientY: number; page: number }): void => {
    cancelInitialRestore()
    const clamped = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, next))
    if (clamped === zoomRef.current) return
    const scroller = scrollerRef.current
    const page = point?.page || pageAtViewportCenter()
    const element = elementFor(page)
    if (scroller && element) {
      const viewport = scroller.getBoundingClientRect()
      const box = element.getBoundingClientRect()
      const clientX = point?.clientX ?? viewport.left + scroller.clientWidth / 2
      const clientY = point?.clientY ?? viewport.top + scroller.clientHeight / 2
      const gesture = zoomGesturePointRef.current
      // Keep the same document coordinate throughout one gesture. Recomputing
      // from rounded scrollTop on Windows accumulates a pixel fraction per tick.
      const anchor = gesture && gesture.page === page && gesture.clientX === clientX && gesture.clientY === clientY
        ? gesture
        : { page, x: (clientX - box.left) / box.width, y: (clientY - box.top) / box.height, clientX, clientY }
      zoomGesturePointRef.current = anchor
      zoomPointRef.current = anchor
    }
    zoomRef.current = clamped
    for (const page of visiblePages) zoomPinnedPages.current.add(page)
    setZooming(true)
    if (zoomEndTimer.current !== null) window.clearTimeout(zoomEndTimer.current)
    zoomEndTimer.current = window.setTimeout(() => {
      zoomPinnedPages.current.clear()
      zoomGesturePointRef.current = null
      setZooming(false)
    }, 200)
    if (zoomFrameRef.current !== null) return
    zoomFrameRef.current = window.requestAnimationFrame(() => {
      zoomFrameRef.current = null
      setPendingSelection(null)
      setZoom(zoomRef.current)
    })
  }, [elementFor, pageAtViewportCenter, visiblePages, cancelInitialRestore])

  useEffect(() => {
    const scroller = scrollerRef.current
    if (scroller === null) return
    const handleWheel = (event: WheelEvent): void => {
      if (!event.ctrlKey && !event.metaKey) return
      event.preventDefault()
      const pageNode = event.target instanceof Element ? event.target.closest<HTMLElement>('[data-pdf-page]') : null
      applyZoom(zoomRef.current * wheelZoomFactor(event.deltaY, event.deltaMode, scroller.clientHeight), {
        clientX: event.clientX, clientY: event.clientY,
        page: Number(pageNode?.dataset.pdfPage) || pageAtViewportCenter()
      })
    }
    scroller.addEventListener('wheel', handleWheel, { passive: false })
    return () => scroller.removeEventListener('wheel', handleWheel)
  }, [applyZoom, pageAtViewportCenter])
  useEffect(() => () => {
    if (zoomFrameRef.current !== null) window.cancelAnimationFrame(zoomFrameRef.current)
    if (zoomEndTimer.current !== null) window.clearTimeout(zoomEndTimer.current)
  }, [])

  // -- scroll: current page, memory save ------------------------------------
  const persistScroll = useCallback((): void => {
    const scroller = scrollerRef.current
    if (scroller === null) return
    const canMeasure =
      visibleRef.current &&
      scroller.clientHeight > 0 &&
      scroller.scrollHeight > 0
    const anchor = canMeasure
      ? rememberViewportAnchor()
      : viewAnchorRef.current
    const previous = pdfScrollMemory.get(courseId, relPath)
    if (!canMeasure && previous === null && anchor === null) return
    pdfScrollMemory.set(courseId, relPath, {
      scrollTop: canMeasure ? scroller.scrollTop : (previous?.scrollTop ?? 0),
      scrollHeight: canMeasure
        ? scroller.scrollHeight
        : (previous?.scrollHeight ?? 0),
      zoom: zoomRef.current,
      ...(anchor === null ? {} : { anchor })
    })
    // 재시작 대비 — 마지막 페이지/줌을 로컬 SQLite 에도 남긴다(피기백,
    // 같은 디바운스). 실패는 조용히: 위치 기록은 사용자 콘텐츠가 아니다.
    void invoke('pdf:setViewState', {
      courseId,
      relPath,
      page: anchor?.page ?? currentPageRef.current,
      zoom: zoomRef.current
    }).catch(() => {})
  }, [courseId, relPath, rememberViewportAnchor])

  const handleScroll = useCallback((): void => {
    // Hidden panels can emit a scroll event when the browser clamps their
    // scrollTop. That is layout fallout, not user navigation, and must never
    // overwrite the last real reading position.
    if (!visibleRef.current) return
    if (scrollFrame.current === null) {
      scrollFrame.current = requestAnimationFrame(() => {
        scrollFrame.current = null
        const anchor = rememberViewportAnchor()
        setCurrentPage(anchor?.page ?? pageAtViewportCenter())
        const scroller = scrollerRef.current
        const applyingPageSync = scroller !== null && pageSyncScroll.current.isEcho(scroller)
        if (
          anchor !== null &&
          pageNotePair !== null &&
          pageNoteSync &&
          !applyingPageSync
        ) {
          publishPageSyncAnchor({
            connectionId: pageNotePair.connectionId,
            pairId: pageNotePair.pairId,
            page: anchor.page,
            pageOffset: anchor.pageOffset,
            originPanelId: panelId
          })
        }
      })
    }
    if (saveTimer.current !== null) window.clearTimeout(saveTimer.current)
    saveTimer.current = window.setTimeout(persistScroll, SCROLL_SAVE_DEBOUNCE_MS)
  }, [
    pageAtViewportCenter,
    pageNotePair,
    pageNoteSync,
    panelId,
    persistScroll,
    rememberViewportAnchor
  ])

  useEffect(() => {
    if (pageNotePair === null || !pageNoteSync) return
    return subscribePageSyncAnchor(pageNotePair.pairId, (anchor) => {
      if (
        anchor.connectionId !== pageNotePair.connectionId ||
        anchor.originPanelId === panelId
      ) {
        return
      }
      const scroller = scrollerRef.current
      if (!scroller || scroller.clientHeight <= 0 || !pageSyncScroll.current.accept(anchor.sequence)) return
      cancelInitialRestore()
      pageSyncScroll.current.apply(scroller, () => restoreViewportAnchor({
        page: Math.min(Math.max(1, anchor.page), Math.max(1, numPages)),
        pageOffset: anchor.pageOffset
      }))
      setCurrentPage(Math.min(Math.max(1, anchor.page), Math.max(1, numPages)))

    })
  }, [numPages, pageNotePair, pageNoteSync, panelId, restoreViewportAnchor, cancelInitialRestore])

  const togglePageNoteSync = useCallback((): void => {
    const next = !pageNoteSync
    setPageNoteSync(next)
    if (pairedConnection?.metadata === null || pairedConnection === null) return
    void invoke('links:updatePageNote', {
      courseId,
      id: pairedConnection.id,
      metadata: { ...pairedConnection.metadata, syncScroll: next }
    }).catch((error: unknown) => {
      console.error('[Bandal] 페이지 필기 동기화 설정을 저장하지 못했습니다.', error)
    })
  }, [courseId, pageNoteSync, pairedConnection, setPageNoteSync])

  // Switching away should flush the semantic anchor immediately instead of
  // waiting for the scroll debounce. On return, the layout effect above uses
  // the same anchor even if Dockview/Chromium reset the hidden element's
  // numeric scrollTop.
  useEffect(() => {
    if (!visible) {
      if (restoreRef.current.done) cancelInitialRestore()
      persistScroll()
    }
  }, [visible, persistScroll, cancelInitialRestore])

  useEffect(() => {
    return () => {
      persistScroll()
      if (scrollFrame.current !== null) cancelAnimationFrame(scrollFrame.current)
      if (saveTimer.current !== null) window.clearTimeout(saveTimer.current)
      if (flashTimer.current !== null) window.clearTimeout(flashTimer.current)
    }
  }, [persistScroll])
  useEffect(() => {
    restoreMountedRef.current = true
    return () => {
      restoreMountedRef.current = false
      if (restoreFrameRef.current !== null) cancelAnimationFrame(restoreFrameRef.current)
      restoreFrameRef.current = null
    }
  }, [])

  // -- scroll restore (once per document) -----------------------------------
  useLayoutEffect(() => {
    if (restoreRef.current.done || restoreRef.current.cancelled || !visible || numPages === 0 || containerWidth === 0) return
    const scroller = scrollerRef.current
    if (scroller === null) return
    // Loading stored state must not take navigation back from a gesture,
    // linked pane, explicit jump, or a tab that has since been hidden/closed.
    const canRestore = (): boolean => restoreMountedRef.current && !restoreRef.current.cancelled && visibleRef.current && scrollerRef.current === scroller
    restoreRef.current.done = true
    const entry = pdfScrollMemory.get(courseId, relPath)
    if (
      entry !== null &&
      (entry.anchor !== undefined || entry.scrollHeight > 0)
    ) {
      restoreFrameRef.current = requestAnimationFrame(() => {
        restoreFrameRef.current = null
        if (!canRestore()) return
        cancelViewportResize()
        if (entry.anchor !== undefined) viewAnchorRef.current = entry.anchor
        const target = scrollerRef.current
        if (target === null) return
        if (
          entry.anchor !== undefined &&
          restoreViewportAnchor(entry.anchor)
        ) {
          setCurrentPage(entry.anchor.page)
          return
        }
        target.scrollTop = entry.scrollTop * (target.scrollHeight / entry.scrollHeight)
        const anchor = rememberViewportAnchor()
        setCurrentPage(anchor?.page ?? pageAtViewportCenter())
      })
      return
    }
    // 세션 메모리가 없다 = 재시작 후 첫 열람 — 로컬 DB의 마지막 페이지로.
    void invoke('pdf:getViewState', { courseId, relPath })
      .then((saved) => {
        if (saved === null || !canRestore()) return
        restoreFrameRef.current = requestAnimationFrame(() => {
          restoreFrameRef.current = null
          if (!canRestore()) return
          cancelViewportResize()
          const savedAnchor = { page: saved.page, pageOffset: 0 }
          viewAnchorRef.current = savedAnchor
          if (Number.isFinite(saved.zoom) && saved.zoom > 0 && saved.zoom !== 1) {
            initialRestoreAnchorRef.current = savedAnchor
            initialRestorePageRef.current = saved.page
            pendingLayoutAnchorRef.current = savedAnchor
            zoomRef.current = saved.zoom
            setZoom(saved.zoom)
            return
          }
          jumpToPageRef.current(saved.page, true)
        })
      })
      .catch(() => {})
  }, [
    numPages,
    containerWidth,
    visible,
    courseId,
    relPath,
    pageAtViewportCenter,
    rememberViewportAnchor,
    restoreViewportAnchor,
    cancelViewportResize
  ])

  // -- selection → mini toolbar ---------------------------------------------
  const captureSelection = useCallback((): void => {
    const content = contentRef.current
    if (content === null) return
    const selection = readPageSelection(window.getSelection())
    if (selection === null || !content.contains(selection.pageElement)) {
      setPendingSelection(null)
      return
    }
    const pageBox = selection.pageElement.getBoundingClientRect()
    const rects = normalizeSelectionRects(selection.clientRects, {
      left: pageBox.left,
      top: pageBox.top,
      width: pageBox.width,
      height: pageBox.height
    })
    if (rects.length === 0) {
      setPendingSelection(null)
      return
    }
    const contentBox = content.getBoundingClientRect()
    const bounds = selection.boundsClientRect
    setEditPopover(null)
    setPendingSelection({
      page: selection.page,
      anchor: selection.anchor,
      rects,
      position: {
        left: bounds.left + bounds.width / 2 - contentBox.left,
        top: bounds.top + bounds.height - contentBox.top + 10
      }
    })
  }, [])

  // Document-level: selection drags often end outside the scroller. While a
  // drag owns the text layer, drawing objects become inert so crossing a box
  // cannot break Chromium's range extension.
  useEffect(() => {
    let frame: number | null = null
    const scheduleCapture = (): void => {
      if (frame !== null) cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        frame = null
        captureSelection()
      })
    }
    const handlePointerDown = (event: PointerEvent): void => {
      const target = event.target
      const content = contentRef.current
      if (
        activeTool !== 'select' ||
        content === null ||
        !(target instanceof Element) ||
        !content.contains(target) ||
        target.closest('.textLayer') === null
      ) return
      textSelectionActiveRef.current = true
      setTextSelectionActive(true)
    }
    const finishSelection = (event: Event): void => {
      const target = event.target
      if (target instanceof Element && target.closest('.pdf-popover') !== null) {
        return
      }
      textSelectionActiveRef.current = false
      setTextSelectionActive(false)
      scheduleCapture()
    }
    const handleSelectionChange = (): void => {
      if (!textSelectionActiveRef.current) scheduleCapture()
    }
    document.addEventListener('pointerdown', handlePointerDown, true)
    document.addEventListener('pointerup', finishSelection, true)
    document.addEventListener('pointercancel', finishSelection, true)
    document.addEventListener('mouseup', finishSelection, true)
    document.addEventListener('selectionchange', handleSelectionChange)
    return () => {
      if (frame !== null) cancelAnimationFrame(frame)
      document.removeEventListener('pointerdown', handlePointerDown, true)
      document.removeEventListener('pointerup', finishSelection, true)
      document.removeEventListener('pointercancel', finishSelection, true)
      document.removeEventListener('mouseup', finishSelection, true)
      document.removeEventListener('selectionchange', handleSelectionChange)
    }
  }, [activeTool, captureSelection])

  const flash = useCallback((id: string): void => {
    if (flashTimer.current !== null) window.clearTimeout(flashTimer.current)
    setFlashId(id)
    flashTimer.current = window.setTimeout(() => setFlashId(null), FLASH_DURATION_MS)
  }, [])

  const createHighlight = useCallback(
    async (color: HighlightColor): Promise<void> => {
      if (pendingSelection === null) return
      const created = await annotationsApi.create({
        courseId,
        relPath,
        page: pendingSelection.page,
        color,
        rects: pendingSelection.rects,
        anchor: pendingSelection.anchor,
        comment: null
      })
      if (created === null) return
      setPendingSelection(null)
      window.getSelection()?.removeAllRanges()
      flash(created.id)
    },
    [pendingSelection, annotationsApi, courseId, relPath, flash]
  )

  // -- highlight click → edit popover ---------------------------------------
  const handleAnnotationClick = useCallback(
    (annotation: Annotation, clientX: number, clientY: number): void => {
      const content = contentRef.current
      if (content === null) return
      const contentBox = content.getBoundingClientRect()
      setPendingSelection(null)
      setEditPopover({
        annotationId: annotation.id,
        position: {
          left: clientX - contentBox.left,
          top: clientY - contentBox.top + 14
        }
      })
    },
    []
  )

  const editedAnnotation = useMemo(
    () =>
      editPopover === null
        ? null
        : annotations.find((entry) => entry.id === editPopover.annotationId) ?? null,
    [editPopover, annotations]
  )

  // -- [M5] annotation → AI tutor -------------------------------------------
  const askAi = useCallback(
    (annotation: Annotation): void => {
      if (assistant) assistant.ask(buildAnnotationPrompt(annotation))
      else askAiAboutAnnotation(courseId, annotation)
    },
    [courseId, assistant]
  )

  const sendToNote = useCallback(
    async (
      annotation: Annotation,
      comment: string | null
    ): Promise<void> => {
      try {
        const result = await invoke('link:sendHighlightToNote', {
          courseId,
          relPath,
          page: annotation.page,
          quote: annotation.anchor.quote,
          comment,
          annotationId: annotation.id
        })
        showToast(`필기로 보냈어요: ${result.relPath}`)
      } catch (error) {
        console.error('[Bandal] 하이라이트를 필기로 보내지 못했습니다.', error)
        showToast('하이라이트를 필기로 보내지 못했습니다.', 'danger')
      }
    },
    [courseId, relPath]
  )

  // -- rail jump ------------------------------------------------------------
  const jumpToAnnotation = useCallback(
    (annotation: Annotation): boolean => {
      const scroller = scrollerRef.current
      const element = elementFor(annotation.page)
      if (scroller === null || element === null) return false
      cancelInitialRestore()
      const scrollerBox = scroller.getBoundingClientRect()
      const elementBox = element.getBoundingClientRect()
      const rectY = annotation.rects[0]?.y ?? 0
      scroller.scrollTo({
        top:
          elementBox.top -
          scrollerBox.top +
          scroller.scrollTop +
          rectY * elementBox.height -
          JUMP_TOP_OFFSET_PX,
        behavior: 'smooth'
      })
      flash(annotation.id)
      return true
    },
    [elementFor, flash, cancelInitialRestore]
  )

  const jumpToPage = useCallback(
    (page: number, restoring = false): void => {
      const clamped = Math.min(Math.max(1, page), Math.max(1, numPages))
      const scroller = scrollerRef.current
      const element = elementFor(clamped)
      if (scroller === null || element === null) return
      if (restoring) cancelViewportResize()
      else cancelInitialRestore()
      const scrollerBox = scroller.getBoundingClientRect()
      const elementBox = element.getBoundingClientRect()
      scroller.scrollTop =
        elementBox.top - scrollerBox.top + scroller.scrollTop - 12
      setCurrentPage(clamped)
      // Publish explicit navigation synchronously, before a pending resize
      // observer can claim the previous page as its pre-reflow anchor.
      viewAnchorRef.current = captureViewportAnchor()
      requestAnimationFrame(() => {
        rememberViewportAnchor()
      })
    },
    [elementFor, numPages, captureViewportAnchor, rememberViewportAnchor, cancelInitialRestore, cancelViewportResize]
  )
  // 복원 effect(정의 위쪽)가 최신 jumpToPage 를 부를 수 있게 ref 로 노출.
  jumpToPageRef.current = jumpToPage

  // A note link can activate an existing panel or mount a fresh one. The
  // sender retries this event until annotations and page boxes are ready;
  // once handled, this uses the same precise scroll + flash path as the rail.
  useEffect(() => {
    const handleLinkedAnnotation = (rawEvent: Event): void => {
      if (!(rawEvent instanceof CustomEvent)) return
      const detail = rawEvent.detail as Partial<PdfAnnotationJumpDetail> | null
      if (
        detail === null ||
        detail.courseId !== courseId ||
        detail.relPath !== relPath ||
        typeof detail.annotationId !== 'string'
      ) {
        return
      }
      const annotation = annotations.find(
        (entry) => entry.id === detail.annotationId
      )
      if (annotation !== undefined && jumpToAnnotation(annotation)) {
        detail.handled = true
      }
    }
    window.addEventListener(PDF_ANNOTATION_JUMP_EVENT, handleLinkedAnnotation)
    return () =>
      window.removeEventListener(
        PDF_ANNOTATION_JUMP_EVENT,
        handleLinkedAnnotation
      )
  }, [annotations, courseId, jumpToAnnotation, relPath])

  useEffect(() => {
    if (numPages === 0) return
    let frame: number | null = null
    const navigate = (page: number): void => {
      if (frame !== null) cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        frame = null
        jumpToPage(page)
      })
    }
    const handleNavigation = (event: Event): void => {
      const detail = (event as CustomEvent<PdfPageNavigationTarget>).detail
      if (detail.courseId !== courseId || detail.relPath !== relPath) return
      navigate(takePdfPageNavigation(courseId, relPath) ?? detail.page)
    }
    window.addEventListener(PDF_PAGE_NAVIGATION_EVENT, handleNavigation)
    const pendingPage = takePdfPageNavigation(courseId, relPath)
    if (pendingPage !== null) navigate(pendingPage)
    return () => {
      window.removeEventListener(PDF_PAGE_NAVIGATION_EVENT, handleNavigation)
      if (frame !== null) cancelAnimationFrame(frame)
    }
  }, [courseId, jumpToPage, numPages, relPath])

  const handleAspect = useCallback((page: number, aspect: number): void => {
    setPageAspects((current) => {
      const previous = current.get(page)
      if (previous !== undefined && Math.abs(previous - aspect) < 0.001) {
        return current
      }
      const anchor =
        visibleRef.current
          ? rememberViewportAnchor()
          : viewAnchorRef.current
      if (anchor !== null) pendingLayoutAnchorRef.current = anchor
      const next = new Map(current)
      next.set(page, aspect)
      return next
    })
  }, [rememberViewportAnchor])

  const handleDocumentLoad = useCallback((pdf: PDFDocumentProxy): void => {
    setPdfProxy(pdf)
    setNumPages(pdf.numPages)
  }, [])

  if (loadError !== null) {
    return <ErrorPanel message={loadError} />
  }

  const zoomPercent = Math.round(zoom * 100)

  return (
    <div
      className="pdf-tab"
      data-tool={activeTool}
      data-text-selecting={textSelectionActive ? 'true' : undefined}
      onWheelCapture={cancelInitialRestore}
      onPointerDownCapture={cancelInitialRestore}
      onKeyDownCapture={cancelInitialRestore}
    >
      <PdfToolbar
        currentPage={currentPage}
        numPages={numPages}
        zoomPercent={zoomPercent}
        isPreviewOpen={isPreviewOpen}
        isRailOpen={isRailOpen}
        annotationCount={annotations.length}
        courseId={courseId}
        relPath={relPath}
        drawingsApi={drawingsApi}
        flushAnnotations={annotationsApi.flush}
        onJumpToPage={jumpToPage}
        onZoomIn={() => applyZoom(zoom * ZOOM_STEP)}
        onZoomOut={() => applyZoom(zoom / ZOOM_STEP)}
        onZoomFit={() => applyZoom(1)}
        onTogglePreview={() => setIsPreviewOpen((open) => !open)}
        onToggleRail={() => setIsRailOpen((open) => !open)}
        onOpenPageNotes={() => setIsPageNoteDialogOpen(true)}
        pageNoteCount={pageNoteConnections.length}
        pageNotePaired={pageNotePair !== null}
        pageNoteSyncEnabled={pageNoteSync}
        onTogglePageNoteSync={togglePageNoteSync}
      />
      {annotationsApi.error !== null && (
        <div className="pdf-annotation-error" role="alert">
          <span>주석을 저장하거나 불러오지 못했어요: {annotationsApi.error}</span>
          {annotationsApi.hasUnsavedUpdates && <>
            <span> 탭을 닫기 전에 다시 저장해 주세요. </span>
            <button type="button" onClick={() => { void annotationsApi.retryUpdates?.() }}>다시 저장</button>
          </>}
        </div>
      )}
      <TextFormatRow visible={activeTool === 'text'} />
      <div className="pdf-tab__main">
        {isPreviewOpen && (
          <PdfPreviewPanel
            pdf={pdfProxy}
            numPages={numPages}
            currentPage={currentPage}
            onJump={jumpToPage}
          />
        )}
        <div
          ref={scrollerRef}
        onWheelCapture={() => { if (pageNotePair) claimPageSyncInput(pageNotePair.pairId, panelId) }}
        onPointerDownCapture={() => { if (pageNotePair) claimPageSyncInput(pageNotePair.pairId, panelId) }}
        onKeyDownCapture={() => { if (pageNotePair) claimPageSyncInput(pageNotePair.pairId, panelId) }}
          className="pdf-scroller"
          onScroll={handleScroll}
        >
          <div ref={contentRef} className="pdf-content">
            {(
              <Document
                file={fileSource}
                options={PDF_DOCUMENT_OPTIONS}
                loading={<LoadingSkeleton />}
                error={
                  <ErrorPanel message="PDF 파일을 해석하지 못했어요. 파일이 손상되었을 수 있어요." />
                }
                onLoadSuccess={handleDocumentLoad}
                onLoadError={(error) => {
                  console.error('[Bandal] PDF를 불러오지 못했습니다.', error)
                  setLoadError(
                    'PDF를 열 수 없어요. 파일이 삭제·이동되었거나 손상되었을 수 있어요.'
                  )
                }}
                externalLinkTarget="_blank"
              >
                {Array.from({ length: numPages }, (_, index) => {
                  const pageNumber = index + 1
                  const pageAnnotations =
                    byPage.get(pageNumber) ?? EMPTY_ANNOTATIONS
                  const pageDrawings =
                    drawingsApi.byPage.get(pageNumber) ?? EMPTY_DRAWINGS
                  const idOnPage = (id: string | null): string | null =>
                    id !== null && pageOfAnnotation.get(id) === pageNumber
                      ? id
                      : null
                  return (
                    <PdfPageView
                      onFirstRender={markFirstRender}
                      key={pageNumber}
                      pageNumber={pageNumber}
                      onContextMenu={(event) => pageImageCopy.openMenu(event, {
                        label: `${pageNumber} 페이지`,
                        disabledReason: !pdfProxy || !visiblePages.has(pageNumber) ? '페이지를 불러온 뒤 다시 시도해 주세요.' : undefined,
                        inkDisabledReason: drawingsApi.loading || drawingsApi.error || annotationsApi.loading || annotationsApi.error ? '필기를 모두 불러온 뒤 다시 복사해 주세요.' : undefined,
                        render: pdfProxy ? (signal) => renderPdfPageImage(pdfProxy, pageNumber, signal) : undefined
                      })}
                      width={pageWidth}
                      aspect={pageAspects.get(pageNumber) ?? defaultAspect}
                      isVisible={visiblePages.has(pageNumber) || (zooming && zoomPinnedPages.current.has(pageNumber))}
                      clipDragEnabled={activeTool === 'select'}
                      onSendClip={(source, clientX, clientY) => {
                        setPendingSelection(null)
                        setEditPopover(null)
                        void whiteboardClip.send(source, clientX, clientY)
                      }}
                      annotations={pageAnnotations}
                      drawings={pageDrawings}
                      drawingsLoading={drawingsApi.loading}
                      courseId={courseId}
                      relPath={relPath}
                      staleIds={staleIds}
                      hoveredId={idOnPage(hoveredId)}
                      activeId={idOnPage(editPopover?.annotationId ?? null)}
                      flashId={idOnPage(flashId)}
                      registerRef={registerPage(pageNumber)}
                      onAspect={handleAspect}
                      onAnnotationClick={handleAnnotationClick}
                      onHoverChange={setHoveredId}
                      drawingsInteractive={interactive}
                      onDrawingCreate={drawingsApi.create}
                      onDrawingUpdate={drawingsApi.update}
                      onDrawingRefine={drawingsApi.refine}
                      onDrawingRemove={drawingsApi.remove}
                      onDrawingResolveId={drawingsApi.resolveId}
                    />
                  )
                })}
              </Document>
            )}

            {pendingSelection !== null && (
              <SelectionPopover
                position={pendingSelection.position}
                clipSource={{
                  relPath,
                  page: pendingSelection.page,
                  crop: rectsBoundingBox(pendingSelection.rects),
                  pageAspect:
                    pageAspects.get(pendingSelection.page) ?? defaultAspect,
                  label: pdfClipLabel(relPath, pendingSelection.page, true)
                }}
                onPick={(color) => void createHighlight(color)}
                onDismiss={() => setPendingSelection(null)}
              />
            )}
            {editPopover !== null && editedAnnotation !== null && (
              <HighlightPopover
                // Remount per highlight so an unsaved memo draft can never
                // follow the popover onto a different annotation.
                key={editedAnnotation.id}
                annotation={editedAnnotation}
                position={editPopover.position}
                isStale={staleIds.has(editedAnnotation.id)}
                onChangeColor={(color) =>
                  void annotationsApi.update({ id: editedAnnotation.id, color })
                }
                onSaveComment={(comment) =>
                  void annotationsApi.update({ id: editedAnnotation.id, comment })
                }
                onDelete={() => {
                  void annotationsApi.remove(editedAnnotation.id)
                  setEditPopover(null)
                }}
                onDismiss={() => setEditPopover(null)}
                onAskAi={(draftComment) => {
                  askAi({ ...editedAnnotation, comment: draftComment })
                  setEditPopover(null)
                }}
                onSendToNote={(draftComment) => {
                  void sendToNote(editedAnnotation, draftComment)
                  setEditPopover(null)
                }}
              />
            )}
            {whiteboardClip.picker !== null && (
              <WhiteboardPickerPopover
                boards={whiteboardClip.picker.boards}
                position={whiteboardClip.picker.position}
                onPick={whiteboardClip.choose}
                onCreate={() => { void whiteboardClip.create() }}
                onDismiss={whiteboardClip.dismiss}
              />
            )}
          </div>
        </div>

        {isRailOpen && (
          <AnnotationRail
            annotations={annotations}
            staleIds={staleIds}
            activeId={editPopover?.annotationId ?? null}
            error={annotationsApi.error}
            onJump={jumpToAnnotation}
            onAskAi={askAi}
            onClose={() => setIsRailOpen(false)}
          />
        )}
      </div>
      {pageImageCopy.overlay}
      {isPageNoteDialogOpen && pdfProxy !== null && (
        <PdfPageNoteDialog
          courseId={courseId}
          relPath={relPath}
          pdf={pdfProxy}
          currentPage={currentPage}
          connections={pageNoteConnections}
          onClose={() => setIsPageNoteDialogOpen(false)}
        />
      )}
    </div>
  )
}

/** Dockview panel entry — same props contract as PlaceholderPanel. */
export default function PdfTab(props: IDockviewPanelProps): JSX.Element {
  const hasBeenShown = useHasBeenShown(props.api)
  const panelActive = usePanelActive(props.api)
  const panelVisible = usePanelVisible(props.api)

  // dockview 기본 렌더러('onlyWhenVisible')는 비활성 패널의 DOM 을 떼어내고,
  // 분리된 스크롤 컨테이너는 브라우저가 scrollTop 을 0으로 리셋한다 — 탭을
  // 오가면 1페이지로 돌아오던 원인. 'always' 로 DOM 을 유지해 스크롤·줌·
  // 검색 상태를 통째로 보존한다.
  useEffect(() => {
    props.api.setRenderer('always')
  }, [props.api])

  const descriptor = descriptorFromParams(props.params)
  if (descriptor === null || descriptor.kind !== 'pdf') {
    return <div className="workspace-panel" data-kind="unknown" />
  }
  if (!hasBeenShown) {
    return (
      <div className="workspace-panel pdf-panel" data-kind="pdf">
        <LoadingSkeleton />
      </div>
    )
  }
  const { courseId, relPath } = descriptor.payload
  const pageNotePair = isPdfPageNotePairContext(props.params['pageNotePair']) &&
    props.params['pageNotePair'].role === 'pdf'
    ? props.params['pageNotePair']
    : null
  return (
    <div className="workspace-panel pdf-panel" data-kind="pdf">
      <PdfViewer
        key={`${courseId}:${relPath}`}
        courseId={courseId}
        relPath={relPath}
        interactive={panelActive}
        visible={panelVisible}
        panelId={props.api.id}
        pageNotePair={pageNotePair}
      />
    </div>
  )
}
