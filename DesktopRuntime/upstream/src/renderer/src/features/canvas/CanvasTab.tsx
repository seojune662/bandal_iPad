import type { IDockviewPanelProps } from 'dockview'
import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState
} from 'react'
import { v4 as uuidv4 } from 'uuid'
import type {
  DrawingBox,
  DrawingClipSource,
  DrawingImageSource,
  DrawingShape
} from '../../../../shared/types/drawing'
import type {
  BoardBackground,
  OpenPersonalBoardResult,
  PersonalBoard,
  PersonalBoardShape,
  SetBoardBackgroundInput
} from '../../../../shared/types/whiteboard'
import { showToast } from '../../app/toast'
import { Icon } from '../../app/icons'
import { invoke } from '../../lib/ipc'
import {
  dataUrlImageAspect,
  healedImageBox,
  imageBoxAtPoint,
  instanceSurfaceKey,
  loadDrawingImage,
  primeDrawingImageCache,
  useInkToolStore,
  type InkHistoryAction
} from '../ink'
import { TextFormatRow } from '../ink/TextFormatRow'
import { requestPdfPageNavigation } from '../pdf/pdfPageNavigation'
import { CLIP_DELIVERY_EVENT, takeClipDeliveries } from './clipDelivery'
import { createPdfClipRenderer } from '../pdf/renderClip'
import { openMaterialInCourse } from '../workspace/openMaterial'
import { isTabDescriptor } from '../workspace/tabIdentity'
import { useHasBeenShown } from '../workspace/useHasBeenShown'
import { usePanelActive } from '../workspace/usePanelActive'
import {
  clipBoxAtDrop,
  createOptimisticCanvasShape,
  putOptimisticCanvasShape,
  removeOptimisticCanvasShapes,
  updateOptimisticCanvasShape,
  type CanvasShapeInput
} from './canvasModel'
import { createCanvasSaveQueue, type CanvasSaveState } from './canvasSaveQueue'
import { CanvasToolRail } from './CanvasToolRail'
import { CanvasPage, DEFAULT_PAGE_ASPECT } from './CanvasPage'
import { CanvasPreviewPanel } from './CanvasPreviewPanel'
import { isEditablePasteTarget } from '../materials/clipboardPaste'
import {
  clipboardImageFiles,
  normalizeWhiteboardImage,
  WHITEBOARD_IMAGE_MAX_FILES
} from '../ink/imageImport'
import './canvas.css'

type LoadState =
  | { phase: 'loading' }
  | { phase: 'loaded'; result: OpenPersonalBoardResult }
  | { phase: 'error'; message: string }

function sameDrawingBox(left: DrawingBox | undefined, right: DrawingBox): boolean {
  return left !== undefined &&
    left.x === right.x &&
    left.y === right.y &&
    left.width === right.width &&
    left.height === right.height
}

function provisionalClipAspect(source: DrawingClipSource): number {
  // 신버전 클립은 원본 페이지 비율을 들고 온다 — 없으면(구 페이로드/저장분)
  // A4 세로 가정 폴백. 이 가정이 슬라이드 PDF 를 세로로 늘이던 원인이었다.
  const pageAspect =
    source.pageAspect !== undefined &&
    Number.isFinite(source.pageAspect) &&
    source.pageAspect > 0
      ? source.pageAspect
      : Math.SQRT2
  const crop = source.crop
  return crop === undefined
    ? pageAspect
    : pageAspect * crop.height / crop.width
}

function readImageAspect(dataUrl: string): Promise<number | null> {
  return new Promise((resolve) => {
    const image = new Image()
    image.onload = () => {
      resolve(image.naturalWidth > 0 ? image.naturalHeight / image.naturalWidth : null)
    }
    image.onerror = () => resolve(null)
    image.src = dataUrl
  })
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback
}

function descriptorFromParams(
  params: unknown
): { courseId: string; boardId: string } | null {
  if (typeof params !== 'object' || params === null) return null
  const descriptor = (params as Record<string, unknown>)['descriptor']
  return isTabDescriptor(descriptor) && descriptor.kind === 'whiteboard'
    ? descriptor.payload
    : null
}

export function canvasUndoKey(boardId: string): string {
  return `personal-canvas:${boardId}`
}

interface CanvasSessionProps {
  initialBoard: PersonalBoard
  initialShapes: readonly PersonalBoardShape[]
  panelApi: IDockviewPanelProps['api']
}

function withShapePage(shape: DrawingShape): PersonalBoardShape {
  const candidate = (shape as DrawingShape & { page?: unknown }).page
  const page = typeof candidate === 'number' && Number.isInteger(candidate) && candidate >= 1
    ? candidate
    : 1
  return { ...shape, page }
}

function CanvasSession({
  initialBoard,
  initialShapes,
  panelApi
}: CanvasSessionProps): JSX.Element {
  // Instance-scoped undo: duplicate views of one board must not share stacks.
  const instanceId = useId()
  const surfaceKey = instanceSurfaceKey(canvasUndoKey(initialBoard.id), instanceId)
  useEffect(() => {
    return () => {
      useInkToolStore.getState().clearHistory(surfaceKey)
    }
  }, [surfaceKey])
  const [board, setBoard] = useState(initialBoard)
  const [shapes, setShapes] = useState<PersonalBoardShape[]>(() => [...initialShapes])
  const [saveState, setSaveState] = useState<CanvasSaveState>({ pending: 0, error: null })
  const saveQueue = useMemo(() => createCanvasSaveQueue(setSaveState), [])
  const [statusMessage, setStatusMessage] = useState<string | null>(null)
  const [editingTitle, setEditingTitle] = useState(false)
  const [titleDraft, setTitleDraft] = useState(initialBoard.title)
  const [renaming, setRenaming] = useState(false)
  const [backgroundBusy, setBackgroundBusy] = useState(false)
  const [pageBusy, setPageBusy] = useState(false)
  const [exportingPdf, setExportingPdf] = useState(false)
  const [visiblePage, setVisiblePage] = useState(1)
  const [isPreviewOpen, setIsPreviewOpen] = useState(false)
  const viewportRef = useRef<HTMLDivElement>(null)
  const titleInputRef = useRef<HTMLInputElement>(null)
  const shapesRef = useRef(shapes)
  const operationRef = useRef(new Map<string, number>())
  const visibilityRef = useRef(new Map<number, number>())
  const pendingScrollPageRef = useRef<number | null>(null)
  const cancelledTitleRenameRef = useRef(false)
  const panelActive = usePanelActive(panelApi)
  const activeTool = useInkToolStore((state) => state.activeTool)
  const setActiveTool = useInkToolStore((state) => state.setActiveTool)
  const color = useInkToolStore((state) => state.color)
  const width = useInkToolStore((state) => state.width)
  const opacity = useInkToolStore((state) => state.opacity)
  const canUndo = useInkToolStore((state) =>
    (state.histories[surfaceKey]?.undo.length ?? 0) > 0
  )
  const canRedo = useInkToolStore((state) =>
    (state.histories[surfaceKey]?.redo.length ?? 0) > 0
  )
  const renderClip = useMemo(
    () => createPdfClipRenderer(initialBoard.courseId),
    [initialBoard.courseId]
  )

  const replace = useCallback((next: PersonalBoardShape[]): void => {
    shapesRef.current = next
    setShapes(next)
  }, [])

  const nextOperation = useCallback((id: string): number => {
    const next = (operationRef.current.get(id) ?? 0) + 1
    operationRef.current.set(id, next)
    return next
  }, [])

  const showSaveError = useCallback((error: unknown): void => {
    setStatusMessage(errorMessage(error, '화이트보드 내용을 저장하지 못했어요.'))
  }, [])

  const persistShape = useCallback((
    shape: PersonalBoardShape,
    restore = false
  ): void => {
    const operation = nextOperation(shape.id)
    void saveQueue.enqueue([shape.id], async () => {
      const saved = await invoke('canvas:putShape', {
      boardId: board.id,
      id: shape.id,
      page: shape.page,
      shape: {
        kind: shape.kind,
        data: shape.data,
        style: shape.style
      },
      // Only undo may revive an erased shape. Every other save leaves a
      // tombstone alone, so a late in-flight write cannot un-erase.
      ...(restore ? { restore: true } : {})
      })
      if (
        operationRef.current.get(shape.id) === operation &&
        shapesRef.current.some((entry) => entry.id === shape.id)
      ) {
        replace(putOptimisticCanvasShape(shapesRef.current, {
          ...saved,
          page: shape.page
        }))
      }
    })
  }, [board.id, nextOperation, replace, saveQueue])

  const addInternal = useCallback((
    input: Omit<CanvasShapeInput, 'page'>,
    page: number,
    recordHistory: boolean
  ): PersonalBoardShape => {
    const optimistic = createOptimisticCanvasShape(
      { ...input, page },
      uuidv4(),
      new Date().toISOString()
    )
    replace(putOptimisticCanvasShape(shapesRef.current, optimistic))
    if (recordHistory) {
      useInkToolStore.getState().recordHistory(surfaceKey, {
        kind: 'remove',
        drawings: [optimistic]
      })
    }
    persistShape(optimistic)
    return optimistic
  }, [persistShape, replace, surfaceKey])

  const restoreInternal = useCallback((
    shape: PersonalBoardShape,
    recordHistory: boolean
  ): PersonalBoardShape => {
    const restored = {
      ...shape,
      updatedAt: new Date().toISOString()
    }
    replace(putOptimisticCanvasShape(shapesRef.current, restored))
    if (recordHistory) {
      useInkToolStore.getState().recordHistory(surfaceKey, {
        kind: 'remove',
        drawings: [restored]
      })
    }
    persistShape(restored, true)
    return restored
  }, [persistShape, replace, surfaceKey])

  const removeInternal = useCallback((
    idsInput: readonly string[],
    recordHistory: boolean
  ): PersonalBoardShape[] => {
    const ids = [...new Set(idsInput)]
    const idSet = new Set(ids)
    const removed = shapesRef.current.filter((shape) => idSet.has(shape.id))
    if (removed.length === 0) return []
    for (const shape of removed) nextOperation(shape.id)
    replace(removeOptimisticCanvasShapes(shapesRef.current, ids))
    if (recordHistory) {
      useInkToolStore.getState().recordHistory(surfaceKey, {
        kind: 'restore',
        drawings: removed
      })
    }
    void saveQueue.enqueue(removed.map((shape) => shape.id), async (pendingIds) => {
      await invoke('canvas:removeShapes', { boardId: board.id, ids: [...pendingIds] })
    })
    return removed
  }, [board.id, nextOperation, replace, saveQueue, surfaceKey])

  const updateInternal = useCallback((
    id: string,
    patch: Partial<Pick<DrawingShape, 'data' | 'style'>>,
    recordHistory: boolean
  ): PersonalBoardShape | null => {
    const before = shapesRef.current.find((shape) => shape.id === id)
    if (before === undefined) return null
    const now = new Date().toISOString()
    const nextShapes = updateOptimisticCanvasShape(
      shapesRef.current,
      id,
      patch,
      now
    )
    const updated = nextShapes.find((shape) => shape.id === id)
    if (updated === undefined) return null
    replace(nextShapes)
    if (recordHistory) {
      useInkToolStore.getState().recordHistory(surfaceKey, {
        kind: 'update',
        drawings: [before]
      })
    }
    persistShape(updated)
    return updated
  }, [persistShape, replace, surfaceKey])

  const executeHistory = useCallback((
    action: InkHistoryAction
  ): InkHistoryAction | null => {
    if (action.kind === 'remove') {
      const removed = removeInternal(
        action.drawings.map((shape) => shape.id),
        false
      )
      return removed.length === 0
        ? null
        : { kind: 'restore', drawings: removed }
    }
    if (action.kind === 'restore') {
      const restored = action.drawings.map((shape) =>
        restoreInternal(withShapePage(shape), false)
      )
      return { kind: 'remove', drawings: restored }
    }

    const inverse: DrawingShape[] = []
    for (const target of action.drawings) {
      const current = shapesRef.current.find((shape) => shape.id === target.id)
      if (current === undefined) return null
      const updated = updateInternal(
        target.id,
        { data: target.data, style: target.style },
        false
      )
      if (updated === null) return null
      inverse.push(current)
    }
    return { kind: 'update', drawings: inverse }
  }, [removeInternal, restoreInternal, updateInternal])

  const undo = useCallback((): void => {
    const store = useInkToolStore.getState()
    const action = store.beginUndo(surfaceKey)
    if (action === null) return
    const inverse = executeHistory(action)
    if (inverse === null) store.cancelUndo(surfaceKey, action)
    else store.finishUndo(surfaceKey, inverse)
  }, [executeHistory, surfaceKey])

  const redo = useCallback((): void => {
    const store = useInkToolStore.getState()
    const action = store.beginRedo(surfaceKey)
    if (action === null) return
    const inverse = executeHistory(action)
    if (inverse === null) store.cancelRedo(surfaceKey, action)
    else store.finishRedo(surfaceKey, inverse)
  }, [executeHistory, surfaceKey])

  const renameBoard = useCallback(async (): Promise<void> => {
    if (cancelledTitleRenameRef.current) {
      cancelledTitleRenameRef.current = false
      return
    }
    const title = titleDraft.trim()
    if (title.length === 0) {
      setStatusMessage('화이트보드 이름을 입력해 주세요.')
      titleInputRef.current?.focus()
      return
    }
    if (title === board.title) {
      setEditingTitle(false)
      return
    }
    setRenaming(true)
    try {
      const renamed = await invoke('canvas:rename', { id: board.id, title })
      setBoard(renamed)
      setTitleDraft(renamed.title)
      setEditingTitle(false)
      setStatusMessage(null)
    } catch (error: unknown) {
      setStatusMessage(errorMessage(error, '화이트보드 이름을 바꾸지 못했어요.'))
    } finally {
      setRenaming(false)
    }
  }, [board.id, board.title, titleDraft])

  const updateBoardAppearance = useCallback(async (
    patch: Omit<SetBoardBackgroundInput, 'boardId'>
  ): Promise<void> => {
    setBackgroundBusy(true)
    try {
      const updated = await invoke('canvas:setBackground', {
        boardId: board.id,
        ...patch
      })
      setBoard(updated)
      setStatusMessage(null)
    } catch (error: unknown) {
      showToast(
        errorMessage(error, '화이트보드 배경을 저장하지 못했어요.'),
        'danger'
      )
    } finally {
      setBackgroundBusy(false)
    }
  }, [board.id])

  const exportBoardPdf = useCallback(async (): Promise<void> => {
    setExportingPdf(true)
    try {
      await saveQueue.flush()
      const result = await invoke('canvas:exportPdf', { boardId: board.id })
      showToast(`과목 폴더에 PDF로 내보냈어요: ${result.relPath}`)
    } catch (error: unknown) {
      showToast(errorMessage(error, 'PDF로 내보내지 못했어요.'), 'danger')
    } finally {
      setExportingPdf(false)
    }
  }, [board.id, saveQueue])

  const addPage = useCallback(async (): Promise<void> => {
    const pageCount = board.pageCount + 1
    setPageBusy(true)
    try {
      const updated = await invoke('canvas:setPageCount', {
        boardId: board.id,
        pageCount
      })
      pendingScrollPageRef.current = updated.pageCount
      setBoard(updated)
      setStatusMessage(null)
    } catch (error: unknown) {
      showToast(errorMessage(error, '페이지를 추가하지 못했어요.'), 'danger')
    } finally {
      setPageBusy(false)
    }
  }, [board.id, board.pageCount])

  useEffect(() => {
    panelApi.setTitle(board.title)
  }, [board.title, panelApi])

  useEffect(() => {
    if (editingTitle) titleInputRef.current?.select()
  }, [editingTitle])

  const jumpToPage = useCallback((page: number): void => {
    if (page < 1 || page > board.pageCount) return
    setVisiblePage(page)
    viewportRef.current
      ?.querySelector(`[data-page-number="${page}"]`)
      ?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [board.pageCount])

  useEffect(() => {
    const page = pendingScrollPageRef.current
    if (page === null || page > board.pageCount) return
    pendingScrollPageRef.current = null
    requestAnimationFrame(() => jumpToPage(page))
  }, [board.pageCount, jumpToPage])

  const updatePageVisibility = useCallback((page: number, ratio: number): void => {
    if (ratio > 0) visibilityRef.current.set(page, ratio)
    else visibilityRef.current.delete(page)
    let bestPage = 1
    let bestRatio = -1
    for (const [candidate, candidateRatio] of visibilityRef.current) {
      if (
        candidateRatio > bestRatio ||
        (candidateRatio === bestRatio && candidate < bestPage)
      ) {
        bestPage = candidate
        bestRatio = candidateRatio
      }
    }
    if (bestRatio >= 0) setVisiblePage(bestPage)
  }, [])

  const placeImage = useCallback((
    source: DrawingImageSource,
    point: { x: number; y: number },
    page: number
  ): void => {
    void saveQueue.prepare(() => loadDrawingImage(board.courseId, source)
      .then((dataUrl) => (dataUrl === null ? null : dataUrlImageAspect(dataUrl)))
      .then((imageAspect) => {
        setActiveTool('select')
        addInternal({
          kind: 'image',
          data: {
            box: imageBoxAtPoint(point, DEFAULT_PAGE_ASPECT, imageAspect ?? 1),
            image: source
          },
          style: { color, width, opacity: 1 }
        }, page, true)
      })
    ).catch(() => showToast('사진을 추가하지 못했어요.', 'danger'))
  }, [addInternal, board.courseId, color, saveQueue, setActiveTool, width])

  const insertImageFiles = useCallback((filesInput: readonly File[]): Promise<void> => saveQueue.prepare(async () => {
    const files = [...filesInput].slice(0, WHITEBOARD_IMAGE_MAX_FILES)
    if (files.length === 0) return
    setStatusMessage('사진을 최적화하는 중…')
    try {
      const origin = { x: 0.5, y: 0.28 }
      for (const [index, file] of files.entries()) {
        const image = await normalizeWhiteboardImage(file)
        const saved = await invoke('materials:writeFile', {
          courseId: board.courseId,
          dirRelPath: `.bandal/whiteboards/${board.id}`,
          createDirIfMissing: true,
          fileName: image.fileName,
          encoding: 'base64',
          data: image.base64
        })
        const source: DrawingImageSource = {
          relPath: saved.relPath,
          label: file.name || '사진'
        }
        primeDrawingImageCache(board.courseId, source, image.dataUrl)
        const offset = Math.min(index, 8) * 0.03
        addInternal({
          kind: 'image',
          data: {
            box: imageBoxAtPoint(
              {
                x: Math.min(0.88, origin.x + offset),
                y: Math.min(0.8, origin.y + offset)
              },
              DEFAULT_PAGE_ASPECT,
              image.aspect
            ),
            image: source
          },
          style: { color, width, opacity: 1 }
        }, visiblePage, true)
      }
      setActiveTool('select')
      setStatusMessage(null)
      showToast(
        files.length === 1
          ? '사진을 화이트보드에 추가했어요.'
          : `${files.length}개 사진을 화이트보드에 추가했어요.`
      )
    } catch (error: unknown) {
      const message = errorMessage(error, '사진을 추가하지 못했어요.')
      setStatusMessage(message)
      showToast(message, 'danger')
    }
  }), [addInternal, board.courseId, board.id, color, saveQueue, setActiveTool, visiblePage, width])

  useEffect(() => {
    if (!panelActive) return
    const handlePaste = (event: ClipboardEvent): void => {
      if (event.defaultPrevented || isEditablePasteTarget(event.target)) return
      if (event.clipboardData === null) return
      const files = clipboardImageFiles(event.clipboardData)
      if (files.length === 0) return
      event.preventDefault()
      void insertImageFiles(files)
    }
    window.addEventListener('paste', handlePaste)
    return () => window.removeEventListener('paste', handlePaste)
  }, [insertImageFiles, panelActive])

  const placeClip = useCallback((
    source: DrawingClipSource,
    point: { x: number; y: number },
    page: number
  ): void => {
    const initialBox = clipBoxAtDrop(
      point,
      DEFAULT_PAGE_ASPECT,
      provisionalClipAspect(source)
    )
    const created = addInternal({
      kind: 'clip',
      data: { box: initialBox, clip: source },
      style: { color, width, opacity: 1 }
    }, page, true)

    // The placeholder lands immediately. Once the visible clip renderer has
    // the real crop, refine only an untouched provisional box to its exact
    // ratio. 재중심화(clipBoxAtDrop 재계산) 대신 healedImageBox 방식 —
    // 폭·자리 유지, 높이만 보정이라 화면에서 "점프"하지 않는다.
    // pageAspect 가 전달된 신버전 클립은 사실상 항상 no-op.
    void saveQueue.prepare(() => renderClip(source).then((dataUrl) =>
      dataUrl === null ? null : readImageAspect(dataUrl)
    ).then((clipAspect) => {
      if (clipAspect === null) return
      const current = shapesRef.current.find((shape) => shape.id === created.id)
      if (current === undefined || !sameDrawingBox(current.data.box, initialBox)) return
      const healed = healedImageBox(initialBox, DEFAULT_PAGE_ASPECT, clipAspect)
      if (healed === null) return
      updateInternal(created.id, {
        data: { ...current.data, box: healed }
      }, false)
    })).catch(() => {})
  }, [addInternal, color, renderClip, saveQueue, updateInternal, width])

  // Clips sent from a PDF by clicking, rather than dragged onto the surface.
  // Delivery follows the page with the greatest visible area. This keeps a
  // click-to-send clip near the student's current work without adding a modal.
  useEffect(() => {
    const drain = (): void => {
      for (const [index, source] of takeClipDeliveries(board.id).entries()) {
        // Count what is already here, not just this batch: sending three pages
        // one at a time is three separate batches, and they would otherwise
        // land on exactly the same spot and hide each other.
        const placed =
          shapesRef.current.filter(
            (shape) => shape.page === visiblePage && shape.kind === 'clip'
          ).length +
          index
        const offset = Math.min(placed, 8) * 0.035
        placeClip(source, { x: 0.28 + offset, y: 0.16 + offset }, visiblePage)
      }
    }
    drain()
    window.addEventListener(CLIP_DELIVERY_EVENT, drain)
    return () => window.removeEventListener(CLIP_DELIVERY_EVENT, drain)
  }, [board.id, placeClip, visiblePage])

  const openClip = useCallback((source: DrawingClipSource): void => {
    openMaterialInCourse(board.courseId, 'pdf', source.relPath)
    requestPdfPageNavigation({
      courseId: board.courseId,
      relPath: source.relPath,
      page: source.page
    })
  }, [board.courseId])

  return (
    <section
      className="canvas-tab"
      data-tool={activeTool}
      data-background={board.background}
      data-surface={board.surface}
    >
      <header className="canvas-tab__header">
        {editingTitle ? (
          <input
            ref={titleInputRef}
            className="canvas-tab__title-input"
            value={titleDraft}
            aria-label="화이트보드 이름"
            disabled={renaming}
            onChange={(event) => setTitleDraft(event.target.value)}
            onBlur={() => void renameBoard()}
            onKeyDown={(event) => {
              if (event.key === 'Enter') event.currentTarget.blur()
              if (event.key === 'Escape') {
                cancelledTitleRenameRef.current = true
                setTitleDraft(board.title)
                setEditingTitle(false)
              }
            }}
          />
        ) : (
          <button
            type="button"
            className="canvas-tab__title"
            aria-label={`${board.title} 이름 변경`}
            title="이름 변경"
            onClick={() => {
              cancelledTitleRenameRef.current = false
              setEditingTitle(true)
            }}
          >
            {board.title}
          </button>
        )}
        <button
          type="button"
          className="canvas-tab__preview-toggle"
          aria-pressed={isPreviewOpen}
          onClick={() => setIsPreviewOpen((open) => !open)}
        >
          <Icon name="layoutLeft" />
          미리보기
        </button>
        <span className="canvas-tab__local-badge" role="status">
          {saveState.error !== null ? '저장하지 못함' : saveState.pending > 0 ? '저장 중…' : '이 기기에 저장됨'}
        </span>
      </header>

      <CanvasToolRail
        canUndo={canUndo}
        canRedo={canRedo}
        enabled={panelActive}
        background={board.background}
        surface={board.surface}
        backgroundBusy={backgroundBusy}
        pageBusy={pageBusy}
        exportingPdf={exportingPdf}
        onUndo={undo}
        onRedo={redo}
        onInsertImages={(files) => { void insertImageFiles(files) }}
        onBackgroundChange={(background: BoardBackground) => {
          void updateBoardAppearance({ background })
        }}
        onSurfaceToggle={() => {
          void updateBoardAppearance({
            surface: board.surface === 'light' ? 'dark' : 'light'
          })
        }}
        onAddPage={() => { void addPage() }}
        onExportPdf={() => { void exportBoardPdf() }}
      />
      <TextFormatRow visible={activeTool === 'text'} />

      {saveState.error !== null && (
        <div className="canvas-tab__status" role="alert">
          <span>변경 내용을 저장하지 못했어요. 이 탭을 닫기 전에 다시 시도해 주세요: {saveState.error}</span>
          <button type="button" disabled={saveState.pending > 0}
            onClick={() => { void saveQueue.retry().catch(showSaveError) }}>다시 저장</button>
        </div>
      )}
      {statusMessage !== null && (
        <p className="canvas-tab__status" role="status">{statusMessage}</p>
      )}

      <div className="canvas-tab__main">
        {isPreviewOpen && (
          <CanvasPreviewPanel
            pageCount={board.pageCount}
            currentPage={visiblePage}
            background={board.background}
            shapes={shapes}
            onJump={jumpToPage}
          />
        )}
        <div ref={viewportRef} className="canvas-tab__viewport">
          <div className="canvas-tab__pages">
            {Array.from({ length: board.pageCount }, (_, index) => index + 1).map(
              (pageNumber) => (
                <CanvasPage
                  key={pageNumber}
                  pageNumber={pageNumber}
                  boardTitle={board.title}
                  shapes={shapes.filter((shape) => shape.page === pageNumber)}
                  tool={{ activeTool, color, width, opacity }}
                  viewportRef={viewportRef}
                  renderClip={renderClip}
                  onOpenClip={openClip}
                  onCreate={(shape) => { addInternal(shape, pageNumber, true) }}
                  onUpdate={(id, patch) => { updateInternal(id, patch, true) }}
                  onRemove={(ids) => { removeInternal(ids, true) }}
                  interactive={panelActive}
                  onRefineBox={(id, box) => {
                    // placeClip 정밀화와 같은 조용한 보정 — undo 미기록.
                    const current = shapesRef.current.find(
                      (shape) => shape.id === id
                    )
                    if (current === undefined) return
                    updateInternal(id, {
                      data: { ...current.data, box }
                    }, false)
                  }}
                  courseId={board.courseId}
                  onDropClip={placeClip}
                  onDropImage={placeImage}
                  onActivate={setVisiblePage}
                  onVisibilityChange={updatePageVisibility}
                />
              )
            )}
          </div>
        </div>
      </div>
    </section>
  )
}

function CanvasLoader({
  descriptor,
  panelApi
}: {
  descriptor: { courseId: string; boardId: string }
  panelApi: IDockviewPanelProps['api']
}): JSX.Element {
  const [loadState, setLoadState] = useState<LoadState>({ phase: 'loading' })

  useEffect(() => {
    let cancelled = false
    setLoadState({ phase: 'loading' })
    void invoke('canvas:open', { boardId: descriptor.boardId }).then((result) => {
      if (cancelled) return
      if (result.board.courseId !== descriptor.courseId) {
        setLoadState({
          phase: 'error',
          message: '이 화이트보드는 현재 과목에 속하지 않아요.'
        })
        return
      }
      setLoadState({ phase: 'loaded', result })
    }).catch((error: unknown) => {
      if (!cancelled) {
        setLoadState({
          phase: 'error',
          message: errorMessage(error, '화이트보드를 불러오지 못했어요.')
        })
      }
    })
    return () => {
      cancelled = true
    }
  }, [descriptor.boardId, descriptor.courseId])

  if (loadState.phase === 'loading') {
    return (
      <div className="canvas-state" data-state="loading">
        <p>화이트보드를 불러오는 중…</p>
      </div>
    )
  }
  if (loadState.phase === 'error') {
    return (
      <div className="canvas-state" data-state="error">
        <h2>화이트보드를 열지 못했어요</h2>
        <p>{loadState.message}</p>
      </div>
    )
  }

  return (
    <CanvasSession
      key={loadState.result.board.id}
      initialBoard={loadState.result.board}
      initialShapes={loadState.result.shapes}
      panelApi={panelApi}
    />
  )
}

export default function CanvasTab(props: IDockviewPanelProps): JSX.Element {
  const hasBeenShown = useHasBeenShown(props.api)
  const descriptor = descriptorFromParams(props.params)

  if (descriptor === null) {
    return <div className="canvas-state" data-state="invalid" />
  }
  if (!hasBeenShown) {
    return (
      <div className="canvas-state" data-state="loading" role="status">
        <p>화이트보드를 불러오는 중…</p>
      </div>
    )
  }

  return <CanvasLoader descriptor={descriptor} panelApi={props.api} />
}
