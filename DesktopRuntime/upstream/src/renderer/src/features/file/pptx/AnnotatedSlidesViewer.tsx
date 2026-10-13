import { usePanelAssistant } from '../../assistantPanel/panelContext'
import { registerDocumentContext } from '../../agent/documentContext'
import { memo, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { PptxPresentation } from '@silurus/ooxml/pptx'
import { DrawingLayer } from '../../pdf/tools/DrawingLayer'
import { PdfToolRail } from '../../pdf/tools/PdfToolRail'
import { useDrawings } from '../../pdf/tools/useDrawings'
import { usePdfToolStore } from '../../pdf/tools/toolStore'
import { PdfPageNoteDialog } from '../../links/PdfPageNoteDialog'
import { useMaterialConnections } from '../../links/useMaterialConnections'
import { subscribeOpenPdfPageNote, takeOpenPdfPageNote } from '../../links/pdfPageNoteNavigation'
import { claimPageSyncInput, publishPageSyncAnchor, subscribePageSyncAnchor, usePageNoteSync } from '../../links/pdfPageNoteSync'
import { PresentationContext } from './presentationContext'
import { convertPresentationToPdf, decodePresentation, loadSlidePresentation, slidePageSize } from './presentationJobs'
import { openHttpLink } from '../../../app/openHttpLink'
import { invoke } from '../../../lib/ipc'
import { showToast } from '../../../app/toast'
import { normalizeWhiteboardImage, clipboardImageFiles } from '../../ink/imageImport'
import type { DrawingsApi } from '../../pdf/tools/useDrawings'
import { PageSyncScroll } from '../../links/pageSyncScroll'
import { usePageImageCopy } from '../../pageImageCopy/usePageImageCopy'
import { pageImageSize } from '../../pageImageCopy/pageImage'
import { createScrollMemory } from '../../pdf/lib/scrollMemory'
import { SlideRenderCache } from './slideRenderCache'
import './presentation.css'

const GAP = 6, PADDING = 12
const slideMemory = createScrollMemory()
const SlideSurface = memo(function SlideSurface({ presentation, cache, index, width, courseId, relPath, drawings, interactive, annotating, jump }: {
  presentation: PptxPresentation; cache: SlideRenderCache; index: number; width: number; courseId: string; relPath: string; drawings: DrawingsApi; interactive: boolean; annotating: boolean; jump: (index: number) => void
}): JSX.Element {
  const canvasRef = useRef<HTMLCanvasElement>(null), textRef = useRef<HTMLDivElement>(null)
  const [error, setError] = useState<string | null>(null)
  const [retry, setRetry] = useState(0)
  const activeTool = usePdfToolStore((state) => state.activeTool)
  useEffect(() => {
    const canvas = canvasRef.current, text = textRef.current
    if (!canvas || !text) return
    const abort = new AbortController()
    setError(null)
    // Bound bitmap memory at high zoom; text-layer coordinates stay in CSS pixels.
    const dpr = Math.min(window.devicePixelRatio || 1, 2, 2400 / width, 2400 / (width * presentation.slideHeight / presentation.slideWidth))
    void cache.render(index, width, dpr, abort.signal).then(async ({ canvas: rendered, runs }) => {
      if (abort.signal.aborted) return
      canvas.width = rendered.width; canvas.height = rendered.height
      canvas.getContext('2d')?.drawImage(rendered, 0, 0)
      const { buildPptxTextLayer } = await import('@silurus/ooxml/pptx')
      if (abort.signal.aborted) return
      buildPptxTextLayer(text, runs, width, width * presentation.slideHeight / presentation.slideWidth, (target) => {
        if (target.kind === 'external' && /^https?:\/\//i.test(target.url)) openHttpLink(target.url)
        if (target.kind === 'internal') {
          const page = target.slideIndex ?? presentation.resolveInternalTarget(target.ref, index)
          if (page !== undefined) jump(page)
        }
      }, index)
    }).catch((cause) => { if (!abort.signal.aborted) setError(cause instanceof Error ? cause.message : '렌더링 오류') })
    return () => { abort.abort(); text.replaceChildren() }
  }, [presentation, cache, index, width, retry, jump])
  return <>
    <canvas ref={canvasRef} className="presentation-page__canvas" />
    <div ref={textRef} className="presentation-page__text" style={{ pointerEvents: annotating ? 'none' : 'auto' }} />
    {error && <button className="presentation-page__error" type="button" title={error} onClick={() => setRetry((v) => v + 1)}>슬라이드를 다시 불러오기</button>}
    {annotating && <DrawingLayer courseId={courseId} relPath={relPath} page={index + 1} pageWidth={width} pageWidthPt={slidePageSize(presentation).width} aspect={presentation.slideHeight / presentation.slideWidth} drawings={drawings.byPage.get(index + 1) ?? []} loading={drawings.loading} interactive={interactive} create={drawings.create} update={drawings.update} refine={drawings.refine} remove={drawings.remove} />}
    {!annotating && (drawings.byPage.get(index + 1)?.length ?? 0) > 0 && <DrawingLayer courseId={courseId} relPath={relPath} page={index + 1} pageWidth={width} pageWidthPt={slidePageSize(presentation).width} aspect={presentation.slideHeight / presentation.slideWidth} drawings={drawings.byPage.get(index + 1) ?? []} loading={false} interactive={false} create={drawings.create} update={drawings.update} refine={drawings.refine} remove={drawings.remove} />}
    <span className="presentation-page__number" data-drawing={annotating && activeTool !== 'select' || undefined}>{index + 1}</span>
  </>
})

export function AnnotatedSlidesViewer({ base64, fileName, courseId, relPath, onFallback }: { base64: string; fileName: string; courseId: string; relPath: string; onFallback: (message: string) => void }): JSX.Element {
  const assistant = usePanelAssistant()
  const workspace = useContext(PresentationContext)
  const [presentation, setPresentation] = useState<PptxPresentation | null>(null)
  const [fingerprint, setFingerprint] = useState('')
  const [annotating, setAnnotating] = useState(true)
  const [notesOpen, setNotesOpen] = useState(false)
  const [dialogOpen, setDialogOpen] = useState(false)
  const memoryKey = `${courseId}:${relPath}`
  const [savedPosition] = useState(() => slideMemory.get(workspace.panelId, memoryKey))
  const [zoom, setZoom] = useState(savedPosition?.zoom ?? 1)
  const positionRef = useRef(savedPosition?.anchor ?? null)
  const [view, setView] = useState({ top: 0, width: 800, height: 700 })
  const [currentPage, setCurrentPage] = useState(1)
  const [includeInk, setIncludeInk] = useState(true)
  const copyIdentity = useMemo(() => ({ base64, courseId, relPath }), [base64, courseId, relPath])
  const pageImageCopy = usePageImageCopy(copyIdentity)
  const scroller = useRef<HTMLDivElement>(null), fileInput = useRef<HTMLInputElement>(null), frame = useRef<number | null>(null)
  const pageSyncScroll = useRef(new PageSyncScroll())
  const cache = useMemo(() => presentation ? new SlideRenderCache(presentation) : null, [presentation])
  useEffect(() => () => cache?.dispose(), [cache])
  useEffect(() => registerDocumentContext(assistant?.panelId ?? `slides:${courseId}:${relPath}`, () => ({
    courseId, relPath, kind: 'presentation', title: fileName, page: currentPage,
    text: scroller.current?.querySelector(`[data-slide-index="${currentPage - 1}"] .presentation-page__text`)?.textContent?.slice(0, 10000) ?? ''
  })), [courseId, relPath, fileName, currentPage, assistant?.panelId])
  const drawings = useDrawings(courseId, relPath)
  const connections = useMaterialConnections(courseId, relPath)
  const pageConnections = connections.outgoing.filter((entry) => entry.kind === 'pdf-page-note')
  const connection = pageConnections.find((entry) => entry.id === workspace.pair?.connectionId)
  const [sync, setSync] = usePageNoteSync(workspace.pair?.pairId ?? null, connection?.metadata?.syncScroll ?? true)

  useEffect(() => {
    if (!presentation) return
    if (takeOpenPdfPageNote(courseId, relPath)) setDialogOpen(true)
    return subscribeOpenPdfPageNote((target) => {
      if (target.courseId === courseId && target.relPath === relPath && takeOpenPdfPageNote(courseId, relPath)) setDialogOpen(true)
    })
  }, [presentation, courseId, relPath])

  useEffect(() => {
    let cancelled = false, loaded: PptxPresentation | null = null
    setPresentation(null)
    void (async () => {
      const bytes = decodePresentation(base64)
      // Hash before the worker can transfer the buffer. Decode the deck once.
      const hash = await crypto.subtle.digest('SHA-256', bytes)
      if (cancelled) return
      const value = await loadSlidePresentation(bytes)
      loaded = value
      if (cancelled) { value.destroy(); return }
      setFingerprint(Array.from(new Uint8Array(hash), (n) => n.toString(16).padStart(2, '0')).join(''))
      setPresentation(value)
    })().catch((cause) => { if (!cancelled) onFallback(cause instanceof Error ? cause.message : '슬라이드를 해석하지 못했어요.') })
    return () => { cancelled = true; loaded?.destroy() }
  }, [base64, onFallback])
  const width = Math.max(180, view.width - PADDING * 2) * zoom
  const height = presentation ? width * presentation.slideHeight / presentation.slideWidth : width * .75
  const stride = height + GAP
  useLayoutEffect(() => {
    const node = scroller.current
    if (!node || !workspace.interactive || node.clientHeight <= 0) return
    const anchor = positionRef.current
    if (anchor) pageSyncScroll.current.apply(node, () => {
      node.scrollTop = PADDING + (anchor.page - 1) * stride + anchor.pageOffset * height - node.clientHeight / 2
    })
    setView((old) => old.top === node.scrollTop ? old : { ...old, top: node.scrollTop })
  }, [stride, height, view.height, workspace.interactive])
  const rememberPosition = useCallback((node: HTMLElement): void => {
    if (node.clientHeight <= 0 || !presentation) return
    const center = node.scrollTop + node.clientHeight / 2
    const index = Math.min(presentation.slideCount - 1, Math.max(0, Math.floor((center - PADDING + GAP / 2) / stride)))
    const anchor = { page: index + 1, pageOffset: Math.max(0, Math.min(1, (center - PADDING - index * stride) / height)) }
    positionRef.current = anchor
    slideMemory.set(workspace.panelId, memoryKey, { scrollTop: node.scrollTop, scrollHeight: node.scrollHeight, zoom, anchor })
  }, [presentation, stride, height, workspace.panelId, memoryKey, zoom])
  const jump = useCallback((index: number): void => {
    const node = scroller.current
    if (node) pageSyncScroll.current.apply(node, () => { node.scrollTop = PADDING + index * stride + height / 2 - node.clientHeight / 2 })
    if (node) rememberPosition(node)
    setCurrentPage(index + 1)
    if (workspace.pair && sync) {
      claimPageSyncInput(workspace.pair.pairId, workspace.panelId)
      publishPageSyncAnchor({ ...workspace.pair, originPanelId: workspace.panelId, page: index + 1, pageOffset: .5 })
    }
  }, [stride, height, workspace.pair, workspace.panelId, sync, rememberPosition])
  useEffect(() => {
    const node = scroller.current
    if (!node) return
    const observer = new ResizeObserver(() => {
      if (node.clientWidth <= 0 || node.clientHeight <= 0) return
      setView((old) => ({ ...old, width: node.clientWidth, height: node.clientHeight }))
    })
    observer.observe(node)
    return () => observer.disconnect()
  }, [presentation])
  useEffect(() => {
    if (presentation && workspace.pair) jump(Math.max(0, workspace.pair.initialPage - 1))
  }, [presentation, workspace.pair?.pairId])
  useEffect(() => {
    if (!workspace.pair || !sync || !presentation) return
    return subscribePageSyncAnchor(workspace.pair.pairId, (anchor) => {
      if (anchor.originPanelId === workspace.panelId || anchor.connectionId !== workspace.pair?.connectionId) return
      const node = scroller.current
      if (!node || node.clientHeight <= 0 || !pageSyncScroll.current.accept(anchor.sequence)) return
      pageSyncScroll.current.apply(node, () => { node.scrollTop = PADDING + Math.max(0, Math.min(presentation.slideCount - 1, anchor.page - 1)) * stride + anchor.pageOffset * height - node.clientHeight / 2 })
      rememberPosition(node)
      setCurrentPage(Math.min(presentation.slideCount, Math.max(1, anchor.page)))
      setView((old) => ({ ...old, top: node.scrollTop }))
    })
  }, [workspace.pair, workspace.panelId, sync, presentation, height, stride, rememberPosition])
  useEffect(() => () => { if (frame.current !== null) cancelAnimationFrame(frame.current) }, [])
  useEffect(() => {
    const node = scroller.current
    if (!node) return
    const wheel = (event: WheelEvent): void => {
      if (!event.ctrlKey && !event.metaKey) return
      event.preventDefault()
      setZoom((value) => Math.min(3, Math.max(.35, value * (event.deltaY > 0 ? .95 : 1.05))))
    }
    node.addEventListener('wheel', wheel, { passive: false })
    return () => node.removeEventListener('wheel', wheel)
  }, [presentation])
  const addImages = useCallback(async (files: File[]): Promise<void> => {
    if (!presentation) return
    try {
      for (const [index, file] of files.slice(0, 10).entries()) {
        const image = await normalizeWhiteboardImage(file)
        const saved = await invoke('materials:writeFile', { courseId, dirRelPath: '.bandal/images', createDirIfMissing: true, fileName: image.fileName, encoding: 'base64', data: image.base64 })
        const aspect = presentation.slideHeight / presentation.slideWidth
        const w = Math.min(.6, .6 * aspect / image.aspect), h = w * image.aspect / aspect
        await drawings.create({ courseId, relPath, page: currentPage, kind: 'image', data: { box: { x: .15 + index * .01, y: .15 + index * .01, width: w, height: h }, image: { relPath: saved.relPath, label: file.name, widthPx: image.widthPx, heightPx: image.heightPx } }, style: { color: 'ink', width: .002, opacity: 1 } })
      }
    } catch (cause) { showToast(cause instanceof Error ? cause.message : '이미지를 넣지 못했어요.', 'danger') }
  }, [presentation, courseId, relPath, currentPage, drawings.create])
  const exportPdf = useCallback(() => convertPresentationToPdf({ courseId, relPath }, undefined, includeInk), [courseId, relPath, includeInk])
  const pageSizes = useMemo(() => presentation ? Array.from({ length: presentation.slideCount }, () => slidePageSize(presentation)) : [], [presentation])
  const start = Math.max(0, Math.floor((view.top - PADDING) / stride) - 1)
  const end = Math.min(presentation?.slideCount ?? 0, Math.ceil((view.top + view.height) / stride) + 2)
  if (!presentation || !cache) return <div className="file-status" role="status">슬라이드를 해석하는 중…</div>
  return <div className="presentation-viewer" onPaste={(event) => {
    if (!workspace.interactive || (event.target instanceof HTMLElement && event.target.closest('input,textarea,[contenteditable=true]'))) return
    const files = clipboardImageFiles(event.clipboardData)
    if (files.length) { event.preventDefault(); event.stopPropagation(); void addImages(files) }
  }}>
    <header className="presentation-toolbar"><strong title={fileName}>{fileName}</strong><div className="presentation-toolbar__controls">
      <input type="number" aria-label="슬라이드 번호" min={1} max={presentation.slideCount} value={currentPage} onChange={(e) => { const n = Number(e.target.value); if (n >= 1 && n <= presentation.slideCount) jump(n - 1) }} /><span>/ {presentation.slideCount}</span>
      <button type="button" aria-pressed={annotating} onClick={() => setAnnotating((v) => !v)}>{annotating ? '필기 중' : '텍스트 선택'}</button>
      <button type="button" onClick={() => setDialogOpen(true)}>페이지 필기 {pageConnections.length || ''}</button>
      {workspace.pair && <button type="button" aria-pressed={sync} onClick={() => { setSync(!sync); if (connection?.metadata) void invoke('links:updatePageNote', { courseId, id: connection.id, metadata: { ...connection.metadata, syncScroll: !sync } }) }}>{sync ? '스크롤 연결됨' : '스크롤 연결'}</button>}
      <button type="button" aria-label="축소" onClick={() => setZoom((v) => Math.max(.35, v / 1.15))}>−</button><button type="button" title="너비에 맞추기" onClick={() => setZoom(1)}>{Math.round(zoom * 100)}%</button><button type="button" aria-label="확대" onClick={() => setZoom((v) => Math.min(3, v * 1.15))}>+</button>
      <button type="button" onClick={() => fileInput.current?.click()}>사진</button><input ref={fileInput} type="file" accept="image/*" multiple hidden onChange={(e) => { void addImages(Array.from(e.target.files ?? [])); e.target.value = '' }} />
      <button type="button" aria-pressed={notesOpen} onClick={() => setNotesOpen((v) => !v)}>발표자 노트</button>
      <label><input type="checkbox" checked={includeInk} onChange={(e) => setIncludeInk(e.target.checked)} />필기 포함</label><button type="button" onClick={() => void exportPdf()}>PDF로 변환</button>
    </div></header>
    {annotating && <PdfToolRail courseId={courseId} relPath={relPath} drawingsApi={drawings} interactive={workspace.interactive} onExport={exportPdf} />}
    <div className="presentation-scroller" tabIndex={0} aria-label="슬라이드 스크롤 영역" ref={scroller} onWheelCapture={() => { if (workspace.pair) claimPageSyncInput(workspace.pair.pairId, workspace.panelId) }} onPointerDownCapture={(event) => {
      if (workspace.pair) claimPageSyncInput(workspace.pair.pairId, workspace.panelId)
      if (event.target instanceof Element && !event.target.closest('input,textarea,button,a,[contenteditable=true]')) scroller.current?.focus({ preventScroll: true })
    }} onScroll={() => {
      if (frame.current !== null) return
      frame.current = requestAnimationFrame(() => {
        frame.current = null
        const node = scroller.current
        if (!node || node.clientHeight <= 0) return
        rememberPosition(node)
        const top = node.scrollTop
        setView((old) => ({ ...old, top }))
        const center = top + node.clientHeight / 2
        const index = Math.min(presentation.slideCount - 1, Math.max(0, Math.floor((center - PADDING + GAP / 2) / stride)))
        setCurrentPage(index + 1)
        if (workspace.pair && sync && !pageSyncScroll.current.isEcho(node)) publishPageSyncAnchor({ ...workspace.pair, originPanelId: workspace.panelId, page: index + 1, pageOffset: Math.max(0, Math.min(1, (center - PADDING - index * stride) / height)) })
      })
    }}><div className="presentation-pages" style={{ minWidth: width + PADDING * 2 }}>
      {Array.from({ length: presentation.slideCount }, (_, index) => <section key={index} className="presentation-page" tabIndex={-1} aria-label={`슬라이드 ${index + 1}`} onContextMenu={(event) => pageImageCopy.openMenu(event, {
        label: `${index + 1}번 슬라이드`,
        disabledReason: index < start || index >= end ? '슬라이드를 불러온 뒤 다시 시도해 주세요.' : undefined,
        inkDisabledReason: drawings.loading || drawings.error ? '필기를 모두 불러온 뒤 다시 복사해 주세요.' : undefined,
        render: (signal) => cache.render(index, pageImageSize(presentation.slideWidth, presentation.slideHeight).width, 1, signal)
      })} data-slide-index={index} style={{ width, height }}>
        {index >= start && index < end && <SlideSurface cache={cache} presentation={presentation} index={index} width={width} courseId={courseId} relPath={relPath} drawings={drawings} interactive={workspace.interactive} annotating={annotating} jump={jump} />}
      </section>)}
    </div></div>
    {pageImageCopy.overlay}
    {notesOpen && <aside className="presentation-notes"><strong>{currentPage}번 슬라이드 노트</strong><p>{presentation.getNotes(currentPage - 1)?.trim() || '발표자 노트가 없어요.'}</p></aside>}
    {dialogOpen && <PdfPageNoteDialog courseId={courseId} relPath={relPath} presentation={{ pageSizes, fingerprint }} currentPage={currentPage} connections={pageConnections} onClose={() => setDialogOpen(false)} />}
  </div>
}
