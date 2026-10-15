import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from 'react'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import type { Annotation, AnnotationRect } from '../../upstream/src/shared/types/annotation'
import type { AnnotationAnchor } from '../../upstream/src/shared/types/annotation'
import type { DrawingsApi } from '../../upstream/src/renderer/src/features/pdf/tools/useDrawings'
import { usePdfInputStore as usePdfToolStore, usePdfInputStoreApi } from '../ipad/input/PdfInputStore'
import { focusPdfInputSurface } from '../ipad/input/markdown'
import { flushNativeSurfaceLayout, isNativeHostBlocked, onNativeHostBlocked } from '../ipad/nativeSurfaces'
import { openHttpLink } from '../../upstream/src/renderer/src/app/openHttpLink'
import { registerNativeInk } from '../pencil/persistence'
import { NativePDFSession } from './session'
import { NativePDFPointerRelay } from './pointerRelay'
import type { NativeObjectScene } from './objectScene'
import { nativePDFDrawingPayload } from './drawingPayload'
import { NativePDFDrawingSnapshotPublisher } from './drawingSnapshot'
import { NativePDFObjectSceneQueue } from './objectSceneQueue'
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
/** Keeps the desktop viewer's semantic model and chrome. The original DOM
 * page boxes remain as navigation anchors, but expensive PDF.js page painting
 * is suspended while the native body is visible. */
export function useNativePDF(props: Props): { active: boolean; hasPending: boolean; flush(): Promise<void> } {
  const latest = useRef(props); latest.current = props
  const [ready, setReady] = useState(false)
  const [pendingCount, setPendingCount] = useState(0)
  const [sceneToolRevision, setSceneToolRevision] = useState(0)
  const [palette, setPalette] = useState(() => readHighlightPalette(document.documentElement))
  const session = useRef<NativePDFSession | null>(null)
  const snapshots = useRef<NativePDFDrawingSnapshotPublisher | null>(null)
  const objectScenes = useRef<{ entry: NativePDFSession; queue: NativePDFObjectSceneQueue } | null>(null)
  const surfaceLayoutRevision = useRef(0)
  const drawingLoadWaiters = useRef(new Set<() => void>())
  const inputStore = usePdfInputStoreApi()
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
    if (!props.drawings.loading) for (const wake of [...drawingLoadWaiters.current]) wake()
  }, [props.drawings.loading])

  const publishCurrent = (entry: NativePDFSession, publisher: NativePDFDrawingSnapshotPublisher, colors: Record<string, number[]>): Promise<void> => {
    const current = latest.current, selected = inputStore.getState()
    const sceneOwner = objectScenes.current?.entry === entry ? objectScenes.current : null
    const sceneEpoch = sceneOwner?.queue.observeTool(selected.activeTool)
    const style = { color: selected.color, width: selected.activeTool === 'highlighter' ? Math.max(selected.width * 4, 0.014) : selected.width,
      opacity: selected.activeTool === 'highlighter' ? Math.min(selected.opacity, 0.34) : selected.opacity }
    return publisher.publish({
      ...(entry.nativeInkErase ? { nativeInkErase: true } : {}),
      objectSceneEpoch: sceneEpoch,
      loading: current.drawings.loading,
      active: current.interactive,
      annotations: current.annotations.map(annotation => ({ ...annotation, nativeColor: colors[annotation.color],
        nativeOpacity: current.activeAnnotation === annotation.id ? 0.72 : current.hoveredAnnotation === annotation.id ? 0.6 : 0.42 })),
      tool: { name: selected.activeTool, style }
    }, current.drawings.drawings.map(drawing => ({ ...nativePDFDrawingPayload(drawing, aspects.current.get(drawing.page) ?? Math.SQRT2),
      ...(entry.mutationIdForDrawing(drawing.id) ? { clientMutationId: entry.mutationIdForDrawing(drawing.id) } : {}) })))
  }

  useEffect(() => {
    let cancelled = false
    let cancelDrawingLoadWait: (() => void) | undefined
    const waitForDrawings = (): Promise<void> => {
      if (cancelled || !latest.current.drawings.loading) return Promise.resolve()
      return new Promise(resolve => {
        const finish = (): void => {
          drawingLoadWaiters.current.delete(wake)
          cancelDrawingLoadWait = undefined
          resolve()
        }
        const wake = (): void => { if (cancelled || !latest.current.drawings.loading) finish() }
        cancelDrawingLoadWait = finish
        drawingLoadWaiters.current.add(wake)
        wake()
      })
    }
    const generation = crypto.randomUUID()
    // An old generation may still own a failed durable flush. Do not replace
    // its native document while the newly selected document opens beside it.
    const id = { surfaceId: `${props.panelId}:${generation}`, generation, courseId: props.courseId, relPath: props.relPath }
    const bridge = transport()
    const entry = new NativePDFSession(id, bridge, props.drawings)
    const sceneOwner = { entry, queue: new NativePDFObjectSceneQueue(payload => entry.invoke('objectScene', payload),
      (reason, retry) => window.dispatchEvent(new CustomEvent('bandal:operation-error', {
        detail: { reason, retry, operation: 'PDF 개체 화면 갱신' }
      }))) }
    objectScenes.current = sceneOwner
    sceneOwner.queue.observeTool(inputStore.getState().activeTool)
    // Tool ownership changes synchronously with the store, before child layout
    // effects can enqueue a scene or an old native reply can clear its state.
    const stopSceneTool = inputStore.subscribe((state, previous) => {
      if (state.activeTool === previous.activeTool) return
      sceneOwner.queue.observeTool(state.activeTool)
      // React may coalesce eraser→pen→eraser into an unchanged tool selector.
      // Still replay the child scene and acknowledge this new queue epoch.
      setSceneToolRevision(revision => revision + 1)
    })
    const pointers = new NativePDFPointerRelay(() => latest.current.scroller.current, () => inputStore.getState().setActiveTool('text'))
    let unregister: (() => void) | undefined
    let publisher: NativePDFDrawingSnapshotPublisher | undefined
    let opened = false, retired = false, selectionSequence = 0, viewportSequence = 0
    const retire = (): void => { if (unregister && !retired) { retired = true; unregister() } }
    const unsubscribe = bridge.on('pdfNative:event', (event: NativePDFEvent) => {
      if (event.surfaceId !== id.surfaceId || event.generation !== id.generation) return
      if (event.type === 'stroke') { void entry.accept(event.payload).catch(report); return }
      if (event.type === 'eraseCommit') { void entry.acceptOperation({ ...event.payload, type: 'eraseCommit' }).catch(report); return }
      if (cancelled) return
      if (event.type === 'activate') {
        // Native paper contact does not generate a DOM pointerdown. Use the
        // original palette's keyboard dismissal so pen/highlighter contact
        // closes it too, without inventing a stroke or a text-editor click.
        document.querySelector('.ipad-pdf-popover, .pdf-tool-popover')?.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, cancelable: true, key: 'Escape' }))
        focusPdfInputSurface(latest.current.scroller.current)
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
      const capabilities = await bridge.invoke('pdfNative:capabilities', {}) as { enabled?: boolean; drawingPatch?: number; objectScenePatch?: number; nativeInkErase?: number }
      if (!capabilities.enabled || cancelled) return
      sceneOwner.queue.configurePatch(capabilities.objectScenePatch === 1)
      const state = await entry.invoke('open') as { pending: unknown[]; documentRevision?: string; pageSizes: Array<{ page: number; width: number; height: number }> }
      entry.configureNativeErase(capabilities.nativeInkErase === 1, state.documentRevision)
      opened = true
      unregister = registerNativeInk({ key: `nativePDF:${id.surfaceId}:${id.generation}`, courseId: id.courseId, relPath: id.relPath }, async () => {
        if (!cancelled) { await entry.flush(); return }
        try { await entry.close(); unsubscribe() } catch (error) { report(error); throw error }
      })
      if (cancelled) { retire(); return }
      session.current = entry
      publisher = new NativePDFDrawingSnapshotPublisher(payload => sceneOwner.queue.sendSnapshot(payload, wire => entry.invoke('snapshot', wire)), capabilities.drawingPatch === 1)
      snapshots.current = publisher
      setPendingCount(state.pending?.length ?? 0)
      aspects.current = new Map(state.pageSizes.map(size => [size.page, size.height / size.width]))
      latest.current.onReady(state.pageSizes)
      await entry.replay(state.pending ?? [])
      if (cancelled) { retire(); return }
      // Common HTML apertures belong to the shared registry. Its first ACK
      // must precede visible paper, including when this hook mounts without
      // the shell bootstrap (for example an isolated host fixture).
      await flushNativeSurfaceLayout()
      if (cancelled) { retire(); return }
      // Do not expose native paper until its first panel-specific pen/style
      // snapshot has been acknowledged. A layout effect can otherwise win the
      // race against the passive snapshot effect and lose the first contact.
      const inputVersion = (): unknown[] => {
        const current = latest.current, selected = inputStore.getState()
        return [current.drawings.loading, current.drawings.drawings, current.interactive, current.annotations,
          current.activeAnnotation, current.hoveredAnnotation, selected.activeTool, selected.color, selected.width, selected.opacity]
      }
      let acknowledged: unknown[]
      do {
        // A visible loading=true surface rejects the first Pencil contact.
        // Wait for the initial repository load without polling or publishing
        // incomplete snapshots, then acknowledge its latest tool and rows.
        await waitForDrawings()
        if (cancelled) { retire(); return }
        acknowledged = inputVersion()
        await publishCurrent(entry, publisher, readHighlightPalette(latest.current.scroller.current ?? document.documentElement))
        if (cancelled) { retire(); return }
      } while (inputVersion().some((value, index) => value !== acknowledged[index]))
      setReady(true)
    })().catch(report)
    return () => {
      cancelled = true; cancelDrawingLoadWait?.(); setReady(false); setPendingCount(0)
      if (session.current === entry) session.current = null
      publisher?.dispose()
      if (snapshots.current === publisher) snapshots.current = null
      pointers.dispose()
      stopSceneTool(); sceneOwner.queue.dispose()
      if (objectScenes.current === sceneOwner) objectScenes.current = null
      if (opened) {
        // Keep completion events subscribed until the journal and original
        // renderer queue are flushed. A failed close remains recoverable.
        void entry.invoke('layout', { visible: false, revision: ++surfaceLayoutRevision.current }).catch(report)
        retire()
      } else { unsubscribe() }
    }
  }, [props.panelId, props.courseId, props.relPath])

  useEffect(() => {
    const entry = session.current, publisher = snapshots.current
    if (!ready || !entry || !publisher) return
    // The desktop store already uses normalized page-width units.
    void publishCurrent(entry, publisher, palette).catch(report)
  }, [ready, active, props.scroller, sceneToolRevision, props.drawings.drawings, props.drawings.loading, props.interactive, props.annotations, props.activeAnnotation, props.hoveredAnnotation, palette, tool, color, width, opacity])

  useLayoutEffect(() => {
    const entry = session.current, element = props.scroller.current
    if (!entry || !ready || !element) return
    let frame = 0, layoutSequence = 0, disposed = false
    let lastHoles: PDFFrame[] = []
    let layoutFlight: { signature: string; promise: Promise<unknown> } | undefined
    const publishLayout = (payload: { visible: boolean; occluded: boolean; holes: PDFFrame[]; rect: PDFFrame }): Promise<unknown> => {
      // Body mutations also include unrelated status/text updates. Reuse the
      // acknowledged or in-flight layout when its native meaning is unchanged;
      // editor geometry must still wait for that same ACK before proceeding.
      const signature = JSON.stringify(payload)
      if (layoutFlight?.signature === signature) return layoutFlight.promise
      const promise = entry.invoke('layout', { ...payload, revision: ++surfaceLayoutRevision.current })
      const flight = { signature, promise }
      layoutFlight = flight
      void promise.catch(() => {
        // A stale rejection must not discard a newer geometry request. A
        // failed latest layout remains retryable on the next layout update.
        if (layoutFlight === flight) layoutFlight = undefined
      })
      return promise
    }
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
        const dialog = [...document.querySelectorAll<HTMLElement>('[role="dialog"], [role="alertdialog"], dialog[open], .shell-settings-overlay[data-open="true"]')].find(node =>
          node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden' &&
          (node.getAttribute('aria-modal') === 'true' || (!node.matches('.pdf-tool-popover, .pdf-popover') && !node.closest('[data-bandal-native-overlay]'))))
        const occluded = !!dialog || isNativeHostBlocked()
        editors.prune()
        if (!activeRef.current) editors.dispose()
        const activeEditors = activeRef.current && !occluded ? [...element.querySelectorAll<HTMLElement>('.ink-layer__textbox-editor')] : []
        if (activeEditors.length) {
          // Resume a document hidden by a modal before asking PDFKit for its
          // page geometry. Retain the previous aperture while it responds.
          await publishLayout({ visible: true, occluded: false, holes: lastHoles,
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
        // Only page-aligned text editors belong to this layout. Common HTML
        // overlays are published by nativeSurfaces: duplicating them here
        // would retain the old rectangle until this independent RAF runs,
        // even after a palette drag's final geometry/release ACK succeeds.
        const holes = [...element.querySelectorAll<HTMLElement>('.ink-layer__textbox-editor')].filter(node =>
          !node.closest('[hidden], [inert]') && getComputedStyle(node).visibility !== 'hidden').map(node => node.getBoundingClientRect())
          .filter(hole => hole.width > 0 && hole.height > 0 && hole.bottom > rect.top && hole.top < rect.bottom && hole.right > rect.left && hole.left < rect.right)
          .map(hole => ({ x: hole.x - rect.x - 2, y: hole.y - rect.y - 2, width: hole.width + 4, height: hole.height + 4 }))
        lastHoles = holes
        await publishLayout({ visible: activeRef.current, occluded, holes, rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } })
      })().catch(error => { if (!disposed) report(error) }) })
    }
    const observer = new ResizeObserver(layout); observer.observe(element)
    const mutations = new MutationObserver(layout); mutations.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'transform', 'hidden', 'role', 'aria-modal', 'open', 'data-open', 'inert'], characterData: true })
    const releaseHost = onNativeHostBlocked(layout)
    window.addEventListener('resize', layout); window.addEventListener('bandal-native-pdf-editor-layout', layout); layout()
    return () => { disposed = true; layoutSequence++; cancelAnimationFrame(frame); observer.disconnect(); mutations.disconnect(); releaseHost(); window.removeEventListener('resize', layout); window.removeEventListener('bandal-native-pdf-editor-layout', layout); editors.dispose() }
  }, [ready, active, props.scroller])

  useLayoutEffect(() => {
    const element = props.scroller.current, entry = session.current, owner = objectScenes.current
    if (!active || !element || !entry || owner?.entry !== entry) return
    owner.queue.resume(inputStore.getState().activeTool)
    const scene = (event: Event): void => {
      const target = event.target
      if (!(target instanceof SVGSVGElement)) return
      const page = Number(target.closest<HTMLElement>('[data-pdf-page]')?.dataset.pdfPage)
      if (!Number.isInteger(page) || page < 1) return
      const mounted = new Set([...element.querySelectorAll<HTMLElement>('[data-native-pdf="true"][data-pdf-page]')]
        .map(node => Number(node.dataset.pdfPage)))
      owner.queue.prunePages(mounted)
      try { owner.queue.publish(page, (event as CustomEvent<NativeObjectScene>).detail, inputStore.getState().activeTool) }
      catch (error) { report(error) }
    }
    element.addEventListener('bandal-native-pdf-object-scene', scene)
    // Child layout effects run before this parent listener is installed. Ask
    // each current source to republish its exact editing state on mount/resume.
    for (const svg of element.querySelectorAll('svg.ink-layer')) {
      svg.dispatchEvent(new Event('bandal-native-pdf-request-object-scene'))
    }
    // The existing passive snapshot effect ACKs this epoch. Keeping preparation
    // there avoids mapping every drawing twice and doing it before paint here.
    return () => {
      element.removeEventListener('bandal-native-pdf-object-scene', scene)
      owner.queue.pause()
    }
  }, [active, ready, props.scroller, sceneToolRevision])

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
