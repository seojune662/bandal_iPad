import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from 'react'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import type { Annotation, AnnotationRect } from '../../upstream/src/shared/types/annotation'
import type { AnnotationAnchor } from '../../upstream/src/shared/types/annotation'
import type { Drawing } from '../../upstream/src/shared/types/drawing'
import type { DrawingsApi } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { usePdfToolStore } from '../../upstream/src/renderer/src/features/pdf/tools/toolStore'
import { openHttpLink } from '../../upstream/src/renderer/src/app/openHttpLink'
import { strokePath } from '../../upstream/src/renderer/src/features/ink/inkGeometry'
import { registerNativeInk } from '../pencil/persistence'
import { NativePDFSession } from './session'
import { NativePDFPointerRelay } from './pointerRelay'
import type { NativeObjectScene } from './objectScene'
import { resolveNativeSelectionAnchor } from './nativeSelection'
import { readHighlightPalette } from './highlightPalette'
import { NativePDFEditorGeometry, type PDFFrame } from './editorGeometry'
import type { NativePDFEvent, NativePDFTransport, NativePDFViewport } from './types'

interface Props {
  panelId: string; courseId: string; relPath: string; visible: boolean; interactive: boolean
  scroller: RefObject<HTMLDivElement>; pdf: PDFDocumentProxy | null; drawings: DrawingsApi; annotations: Annotation[]
  page: number; zoom: number; blocked: boolean
  activeAnnotation: string | null; hoveredAnnotation: string | null
  onViewport(viewport: NativePDFViewport): void
  onSelection(selection: { page: number; quote: string; anchor: AnnotationAnchor; rects: AnnotationRect[]; x: number; y: number }): void
  onReady(sizes: Array<{ page: number; width: number; height: number }>): void
  onAnnotation(id: string, x: number, y: number): void
  onPageAction(action: 'whiteboard' | 'imageMenu', page: number, x: number, y: number): void
  onBodyTap(): void
  onActivate(): void
}

const report = (error: unknown): void => {
  window.dispatchEvent(new ErrorEvent('error', { error, message: error instanceof Error ? error.message : String(error) }))
}
function transport(): NativePDFTransport { return window.bandal as unknown as NativePDFTransport }
function originalPath(drawing: Drawing, aspect: number): string | undefined {
  if (drawing.kind !== 'ink' && drawing.kind !== 'highlighter') return undefined
  const points = drawing.data.points ?? []
  return strokePath(points, drawing.style, aspect, drawing.kind === 'highlighter', drawing.data.inkVersion)
}

/** Keeps the desktop viewer's semantic model and chrome. The original DOM
 * page boxes remain as navigation anchors, but expensive PDF.js page painting
 * is suspended while the native body is visible. */
export function useNativePDF(props: Props): { active: boolean; hasPending: boolean; flush(): Promise<void> } {
  const latest = useRef(props); latest.current = props
  const [ready, setReady] = useState(false)
  const [pendingCount, setPendingCount] = useState(0)
  const [palette, setPalette] = useState(() => readHighlightPalette(document.documentElement))
  const session = useRef<NativePDFSession | null>(null)
  const aspects = useRef(new Map<number, number>())
  const receiving = useRef(false)
  const nativeViewport = useRef<NativePDFViewport | null>(null)
  const tool = usePdfToolStore(state => state.activeTool)
  const color = usePdfToolStore(state => state.color)
  const width = usePdfToolStore(state => state.width)
  const opacity = usePdfToolStore(state => state.opacity)
  // The host capabilities gate stays off until native integration tests pass.
  const active = ready && props.visible
  const activeRef = useRef(active); activeRef.current = active

  useEffect(() => {
    let cancelled = false
    const generation = crypto.randomUUID()
    // An old generation may still own a failed durable flush. Do not replace
    // its native document while the newly selected document opens beside it.
    const id = { surfaceId: `${props.panelId}:${generation}`, generation, courseId: props.courseId, relPath: props.relPath }
    const bridge = transport()
    const entry = new NativePDFSession(id, bridge, props.drawings)
    const pointers = new NativePDFPointerRelay(() => latest.current.scroller.current, () => usePdfToolStore.getState().setActiveTool('text'))
    let unregister: (() => void) | undefined
    let opened = false, retired = false, selectionSequence = 0, viewportSequence = 0
    const retire = (): void => { if (unregister && !retired) { retired = true; unregister() } }
    const unsubscribe = bridge.on('pdfNative:event', (event: NativePDFEvent) => {
      if (event.surfaceId !== id.surfaceId || event.generation !== id.generation) return
      if (event.type === 'stroke') { void entry.accept(event.payload).catch(report); return }
      if (cancelled) return
      if (event.type === 'activate') {
        // Native paper contact does not generate a DOM pointerdown. Use the
        // original palette's keyboard dismissal so pen/highlighter contact
        // closes it too, without inventing a stroke or a text-editor click.
        document.querySelector('.pdf-tool-popover')?.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, key: 'Escape' }))
        latest.current.onActivate(); return
      }
      if (event.type === 'pending') {
        const count = event.payload.count
        if (typeof count === 'number' && Number.isInteger(count) && count >= 0) setPendingCount(count)
        return
      }
      if (event.type === 'error') { report(new Error(String(event.payload.message ?? '네이티브 PDF 입력 오류'))); return }
      if (event.type === 'bodyTap') {
        // Dismiss only PDF popovers/menu. A fabricated document pointer would
        // also finish the original InkLayer's newly opened text session.
        latest.current.onBodyTap()
        document.querySelector('.page-image-menu')?.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Escape' }))
        return
      }
      if (event.type === 'pointer') {
        // Let Dockview activate an inactive split before its original object
        // editor receives input. Ink bypasses this relay and remains native.
        if (!latest.current.interactive) latest.current.onActivate()
        requestAnimationFrame(() => { if (!cancelled) pointers.accept(event.payload as unknown as Parameters<NativePDFPointerRelay['accept']>[0]) })
      } else if (event.type === 'viewport') {
        const value = event.payload as unknown as NativePDFViewport
        if (![value.page, value.zoom, value.progress].every(Number.isFinite)) return
        nativeViewport.current = value; receiving.current = true
        const sequence = ++viewportSequence
        latest.current.onViewport(value)
        window.dispatchEvent(new Event('bandal-native-pdf-editor-layout'))
        requestAnimationFrame(() => requestAnimationFrame(() => { if (sequence === viewportSequence) receiving.current = false }))
      } else if (event.type === 'selection') {
        const selection = event.payload as unknown as Parameters<Props['onSelection']>[0]
        const sequence = ++selectionSequence
        void resolveNativeSelectionAnchor(latest.current.pdf, selection).then(anchor => {
          if (!cancelled && sequence === selectionSequence) latest.current.onSelection({ ...selection, anchor })
        }).catch(report)
      } else if (event.type === 'annotation') {
        const { id, x, y } = event.payload
        if (typeof id === 'string' && typeof x === 'number' && typeof y === 'number' && [x,y].every(Number.isFinite)) latest.current.onAnnotation(id,x,y)
      } else if (event.type === 'pageAction') {
        const { action, page, x, y } = event.payload
        if ((action === 'whiteboard' || action === 'imageMenu') && typeof page === 'number' && Number.isInteger(page) && page > 0
          && typeof x === 'number' && typeof y === 'number' && [x,y].every(Number.isFinite)) latest.current.onPageAction(action,page,x,y)
      } else if (event.type === 'link') {
        const url = event.payload.url
        if (typeof url === 'string' && /^https?:\/\//i.test(url)) openHttpLink(url)
      }
    })
    void (async () => {
      const capabilities = await bridge.invoke('pdfNative:capabilities', {}) as { enabled?: boolean }
      if (!capabilities.enabled || cancelled) return
      const state = await entry.invoke('open') as { pending: unknown[]; pageSizes: Array<{ page: number; width: number; height: number }> }
      opened = true
      unregister = registerNativeInk({ key: `nativePDF:${id.surfaceId}:${id.generation}`, courseId: id.courseId, relPath: id.relPath }, async () => {
        if (!cancelled) { await entry.flush(); return }
        try { await entry.close(); unsubscribe() } catch (error) { report(error); throw error }
      })
      if (cancelled) { retire(); return }
      session.current = entry
      setPendingCount(state.pending?.length ?? 0)
      aspects.current = new Map(state.pageSizes.map(size => [size.page, size.height / size.width]))
      latest.current.onReady(state.pageSizes)
      await entry.replay(state.pending ?? [])
      if (cancelled) { retire(); return }
      setReady(true)
    })().catch(report)
    return () => {
      cancelled = true; setReady(false); setPendingCount(0)
      if (session.current === entry) session.current = null
      pointers.dispose()
      if (opened) {
        // Keep completion events subscribed until the journal and original
        // renderer queue are flushed. A failed close remains recoverable.
        void entry.invoke('layout', { visible: false }).catch(report)
        retire()
      } else { unsubscribe() }
    }
  }, [props.panelId, props.courseId, props.relPath])

  useEffect(() => {
    const entry = session.current
    if (!ready || !entry) return
    // The desktop store already uses normalized page-width units.
    const style = { color, width: tool === 'highlighter' ? Math.max(width * 4, 0.014) : width,
      opacity: tool === 'highlighter' ? Math.min(opacity, 0.34) : opacity }
    void entry.invoke('snapshot', {
      loading: props.drawings.loading,
      active: props.interactive,
      drawings: props.drawings.drawings.map(drawing => ({ ...drawing,
        ...(entry.mutationIdForDrawing(drawing.id) ? { clientMutationId: entry.mutationIdForDrawing(drawing.id) } : {}),
        nativePath: originalPath(drawing, aspects.current.get(drawing.page) ?? Math.SQRT2) })),
      annotations: props.annotations.map(annotation => ({ ...annotation, nativeColor: palette[annotation.color],
        nativeOpacity: props.activeAnnotation === annotation.id ? 0.72 : props.hoveredAnnotation === annotation.id ? 0.6 : 0.42 })), tool: { name: tool, style }
    }).catch(report)
  }, [ready, props.drawings.drawings, props.drawings.loading, props.interactive, props.annotations, props.activeAnnotation, props.hoveredAnnotation, palette, tool, color, width, opacity, props.zoom])

  useLayoutEffect(() => {
    const entry = session.current, element = props.scroller.current
    if (!entry || !ready || !element) return
    let frame = 0, layoutSequence = 0, disposed = false
    let lastHoles: PDFFrame[] = []
    const editors = new NativePDFEditorGeometry()
    const layout = (): void => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => { void (async () => {
        const sequence = ++layoutSequence
        const rect = element.getBoundingClientRect()
        // The desktop PDF's style palette and highlight editor use role=dialog
        // for accessibility but are nonmodal. Keep PDFKit visible and route
        // only their rectangles back to HTML. A true modal always takes over,
        // including one nested inside a popover or explicitly aria-modal.
        const dialog = [...document.querySelectorAll<HTMLElement>('[role="dialog"], [role="alertdialog"], dialog[open]')].find(node =>
          node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden' &&
          (node.getAttribute('aria-modal') === 'true' || !node.matches('.pdf-tool-popover, .pdf-popover')))
        editors.prune()
        if (!activeRef.current) editors.dispose()
        const activeEditors = activeRef.current && !dialog ? [...element.querySelectorAll<HTMLElement>('.ink-layer__textbox-editor')] : []
        if (activeEditors.length) {
          // Resume a document hidden by a modal before asking PDFKit for its
          // page geometry. Retain the previous aperture while it responds.
          await entry.invoke('layout', { visible: true, holes: lastHoles,
            rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } })
          if (disposed || sequence !== layoutSequence) return
        }
        for (const editor of activeEditors) {
          const page = Number(editor.closest<HTMLElement>('[data-pdf-page]')?.dataset.pdfPage)
          if (!Number.isInteger(page) || page < 1) continue
          const geometry = await entry.invoke('pageGeometry', { page }) as PDFFrame
          if (disposed || sequence !== layoutSequence || !editor.isConnected) return
          editors.apply(editor, geometry, rect)
        }
        const colors = readHighlightPalette(element)
        setPalette(current => JSON.stringify(current) === JSON.stringify(colors) ? current : colors)
        const holes = [...document.querySelectorAll<HTMLElement>('.pdf-popover, .pdf-tool-popover, .context-menu, .page-image-menu, .ink-layer__textbox-editor')].map(node => node.getBoundingClientRect())
          .filter(hole => hole.width > 0 && hole.height > 0 && hole.bottom > rect.top && hole.top < rect.bottom && hole.right > rect.left && hole.left < rect.right)
          .map(hole => ({ x: hole.x - rect.x - 2, y: hole.y - rect.y - 2, width: hole.width + 4, height: hole.height + 4 }))
        lastHoles = holes
        void entry.invoke('layout', { visible: activeRef.current && !dialog, holes, rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } }).catch(report)
      })().catch(error => { if (!disposed) report(error) }) })
    }
    const observer = new ResizeObserver(layout); observer.observe(element)
    const mutations = new MutationObserver(layout); mutations.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'transform', 'hidden', 'role', 'aria-modal', 'open'], characterData: true })
    window.addEventListener('resize', layout); window.addEventListener('bandal-native-pdf-editor-layout', layout); layout()
    return () => { disposed = true; layoutSequence++; cancelAnimationFrame(frame); observer.disconnect(); mutations.disconnect(); window.removeEventListener('resize', layout); window.removeEventListener('bandal-native-pdf-editor-layout', layout); editors.dispose() }
  }, [ready, active, props.scroller])

  useLayoutEffect(() => {
    const element = props.scroller.current, entry = session.current
    if (!active || !element || !entry) return
    const scene = (event: Event): void => {
      const target = event.target
      if (!(target instanceof SVGSVGElement)) return
      const page = Number(target.closest<HTMLElement>('[data-pdf-page]')?.dataset.pdfPage)
      if (!Number.isInteger(page) || page < 1) return
      void entry.invoke('objectScene', { page, ...(event as CustomEvent<NativeObjectScene>).detail }).catch(report)
    }
    element.addEventListener('bandal-native-pdf-object-scene', scene)
    return () => element.removeEventListener('bandal-native-pdf-object-scene', scene)
  }, [active, ready, props.scroller])

  useEffect(() => {
    const entry = session.current
    if (!active || !entry || receiving.current) return
    if (nativeViewport.current?.page === props.page && Math.abs(nativeViewport.current.zoom - props.zoom) < 0.001) return
    void entry.invoke('navigate', { page: props.page, zoom: props.zoom, progress: 0 }).catch(report)
  }, [active, props.page, props.zoom])

  // Semantic DOM anchors reflect native scrolling, and changes caused by a
  // desktop link/page-note synchronizer are delivered back without page rect
  // streaming. Ink never depends on this asynchronous DOM bookkeeping.
  useEffect(() => {
    const element = props.scroller.current
    if (!active || !element) return
    const scroll = (): void => {
      if (receiving.current || !session.current) return
      const center = element.getBoundingClientRect().top + element.clientHeight / 2
      const pages = [...element.querySelectorAll<HTMLElement>('[data-pdf-page]')]
      const page = pages.find(node => { const r = node.getBoundingClientRect(); return r.top <= center && r.bottom >= center })
      if (!page) return
      const rect = page.getBoundingClientRect()
      const viewport = element.getBoundingClientRect()
      void session.current.invoke('navigate', { page: Number(page.dataset.pdfPage), zoom: latest.current.zoom, progress: (center - rect.top) / rect.height,
        horizontalProgress: (viewport.left + viewport.width/2 - rect.left)/rect.width }).catch(report)
    }
    element.addEventListener('scroll', scroll)
    return () => element.removeEventListener('scroll', scroll)
  }, [active, props.scroller])
  return { active, hasPending: ready && pendingCount > 0, flush: async () => {
    if (session.current) await session.current.flush()
    else await latest.current.drawings.flush?.()
  } }
}
