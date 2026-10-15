import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import { createPortal, flushSync } from 'react-dom'
import { PdfToolbar as OriginalPdfToolbar, type PdfToolbarProps } from '../../../upstream/src/renderer/src/features/pdf/PdfToolbar'
import { PdfToolIcon } from '../../../upstream/src/renderer/src/features/pdf/tools/pdfToolIcons'
import type { InkTool } from '../../../upstream/src/renderer/src/features/ink/inkToolStore'
import { invoke } from '../../../upstream/src/renderer/src/lib/ipc'
import { usePdfInputScope, usePdfInputStore, usePdfInputStoreApi } from './PdfInputStore'
import { PDF_COLORS, samePreset } from './preferences'
import { clampPalette, relativePalette, placePopover, type Frame } from './geometry'
import { acquireNativeInput, flushNativeSurfaceLayout, registerNativeOverlay, isNativeHostBlocked, onNativeHostBlocked } from '../nativeSurfaces'

const labels: Record<InkTool, string> = { pen: '펜', highlighter: '형광펜', eraser: '지우개', select: '선택', text: '텍스트', rect: '사각형', ellipse: '타원', arrow: '화살표', line: '직선' }
const colorLabels = { ink: '먹색', red: '빨강', orange: '주황', yellow: '노랑', green: '초록', blue: '파랑', violet: '보라' }
const core: InkTool[] = ['pen', 'highlighter', 'eraser', 'select']
const additional: InkTool[] = ['text', 'rect', 'ellipse', 'arrow', 'line']
const shortcuts: Record<string, InkTool> = { p: 'pen', h: 'highlighter', e: 'eraser', v: 'select', t: 'text', r: 'rect', o: 'ellipse' }
type Menu = 'styles' | 'tools' | 'document' | null
interface Drag {
  id: number; handle: HTMLElement; startX: number; startY: number; origin: { left: number; top: number }
  lastX: number; lastY: number; release?: () => Promise<void>; ended: boolean; finishing: boolean
}

/** Original PDF actions stay available in a nonmodal document menu. */
export function PdfInputToolbar(props: PdfToolbarProps): JSX.Element | null {
  const scope = usePdfInputScope()
  const [obscured, setObscured] = useState(isNativeHostBlocked)
  useLayoutEffect(() => {
    if (!scope) return
    const update = (): void => setObscured(isNativeHostBlocked() || [...document.querySelectorAll<HTMLElement>('[role="dialog"], [role="alertdialog"], dialog[open]')].some(element =>
      element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden' &&
      (element.getAttribute('aria-modal') === 'true' || !element.closest('[data-bandal-native-overlay], .pdf-tool-popover, .pdf-popover'))))
    const unsubscribe = onNativeHostBlocked(update)
    const observer = new MutationObserver(update)
    observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class','style','hidden','open','role','aria-modal'] })
    update()
    return () => { unsubscribe(); observer.disconnect() }
  }, [scope?.owner])
  if (!scope) return <OriginalPdfToolbar {...props} />
  return scope.active && scope.visible && !obscured ? <PdfPalette {...props} /> : null
}

function PdfPalette(props: PdfToolbarProps): JSX.Element {
  const scope = usePdfInputScope()!
  const store = usePdfInputStoreApi()
  const tool = usePdfInputStore(state => state.activeTool)
  const color = usePdfInputStore(state => state.color)
  const width = usePdfInputStore(state => state.width)
  const opacity = usePdfInputStore(state => state.opacity)
  const favorites = usePdfInputStore(state => state.favorites)
  const position = usePdfInputStore(state => state.position)
  const collapsed = usePdfInputStore(state => state.collapsed)
  const palette = useRef<HTMLDivElement>(null), popup = useRef<HTMLDivElement>(null), statusElement = useRef<HTMLDivElement>(null)
  const [viewport, setViewport] = useState<Frame | null>(null)
  const [placement, setPlacement] = useState({ left: -10000, top: -10000 })
  const [menu, setMenu] = useState<Menu>(null)
  const [popupPlacement, setPopupPlacement] = useState({ left: -10000, top: -10000 })
  const [message, setMessage] = useState(''), [exporting, setExporting] = useState(false)
  const status = props.drawingsApi.loading ? '필기를 불러오는 중…' : props.drawingsApi.error || message
  const [statusPlacement, setStatusPlacement] = useState({ left: -10000, top: -10000, visible: false })
  const [blocked, setBlocked] = useState(isNativeHostBlocked)
  const drag = useRef<Drag | null>(null), resizing = useRef(false), mounted = useRef(true), viewportRef = useRef(viewport)
  viewportRef.current = viewport
  const owner = scope.owner + ':palette'
  const fail = (error: unknown): void => { if (mounted.current) setMessage(error instanceof Error ? error.message : String(error)) }
  const failMove = (error: unknown, release: () => Promise<void>, operation = '필기 도구 이동'): void => {
    fail(error)
    window.dispatchEvent(new CustomEvent('bandal:operation-error', { detail: { reason: error, operation, retry: async () => {
      await flushNativeSurfaceLayout(); await release()
      if (mounted.current) setMessage('')
    } } }))
  }
  useEffect(() => onNativeHostBlocked(() => { setBlocked(isNativeHostBlocked()); if (isNativeHostBlocked()) setMenu(null) }), [])

  useEffect(() => {
    const root = scope.root.current
    if (!root) return
    const update = (): void => {
      const scroller = root.querySelector<HTMLElement>('.pdf-scroller')
      if (!scroller) return
      const rect = scroller.getBoundingClientRect(), visual = window.visualViewport
      const left = Math.max(rect.left, visual?.offsetLeft ?? 0), top = Math.max(rect.top, visual?.offsetTop ?? 0)
      const right = Math.min(rect.right, (visual?.offsetLeft ?? 0) + (visual?.width ?? window.innerWidth))
      const bottom = Math.min(rect.bottom, (visual?.offsetTop ?? 0) + (visual?.height ?? window.innerHeight))
      const next = { left, top, width: Math.max(0, right-left), height: Math.max(0, bottom-top) }
      setViewport(previous => previous && Object.keys(next).every(key => previous[key as keyof Frame] === next[key as keyof Frame]) ? previous : next)
    }
    const resize = new ResizeObserver(update); resize.observe(root)
    const scroller = root.querySelector('.pdf-scroller'); if (scroller) resize.observe(scroller)
    let frame = 0
    const mutations = new MutationObserver(records => {
      if (records.every(record => record.target instanceof Element && record.target.closest('[data-bandal-native-overlay]'))) return
      cancelAnimationFrame(frame); frame = requestAnimationFrame(update)
    })
    mutations.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['style','class','hidden'] })
    window.addEventListener('resize', update); window.visualViewport?.addEventListener('resize', update); window.visualViewport?.addEventListener('scroll', update)
    update()
    return () => { resize.disconnect(); mutations.disconnect(); cancelAnimationFrame(frame); window.removeEventListener('resize', update); window.visualViewport?.removeEventListener('resize', update); window.visualViewport?.removeEventListener('scroll', update) }
  }, [scope.root])

  useLayoutEffect(() => {
    const element = palette.current
    if (!element || !viewport) return
    const update = (): void => { if (!drag.current) setPlacement(clampPalette(viewport, element.getBoundingClientRect(), position)) }
    const resize = new ResizeObserver(update); resize.observe(element); update()
    return () => resize.disconnect()
  }, [viewport, position])

  useLayoutEffect(() => {
    const element = palette.current
    return element ? registerNativeOverlay(owner, element) : undefined
  }, [owner])

  useLayoutEffect(() => {
    const element = popup.current, anchor = palette.current
    if (!menu || !element || !anchor || !viewport) return
    const unregister = registerNativeOverlay(owner + ':menu', element)
    const update = (): void => setPopupPlacement(placePopover(viewport, anchor.getBoundingClientRect(), element.getBoundingClientRect()))
    const resize = new ResizeObserver(update); resize.observe(element); update()
    return () => { resize.disconnect(); unregister() }
  }, [menu, owner, viewport, placement])

  useLayoutEffect(() => {
    const element = statusElement.current, anchor = palette.current
    if (menu || !status || !element || !anchor || !viewport) return
    const unregister = registerNativeOverlay(owner + ':status', element)
    const update = (): void => {
      const bounds = anchor.getBoundingClientRect()
      const above = bounds.top - viewport.top - 20
      const below = viewport.top + viewport.height - bounds.bottom - 20
      const maxWidth = Math.max(0, Math.min(300, viewport.width - 24))
      const maxHeight = Math.max(0, Math.min(180, Math.max(above, below)))
      // Measure with the actual available slot first. Long errors scroll in
      // that slot instead of pushing into the tab strip or over the palette.
      element.style.maxWidth = `${maxWidth}px`
      element.style.maxHeight = `${maxHeight}px`
      const next = { ...placePopover(viewport, bounds, element.getBoundingClientRect()), visible: maxWidth >= 44 && maxHeight >= 32 }
      setStatusPlacement(previous => previous.left === next.left && previous.top === next.top && previous.visible === next.visible ? previous : next)
    }
    const resize = new ResizeObserver(update); resize.observe(element); resize.observe(anchor); update()
    return () => { resize.disconnect(); unregister() }
  }, [menu, status, owner, viewport, placement])

  const finishDrag = async (current: Drag): Promise<void> => {
    if (!current.release || current.finishing) return
    current.finishing = true
    try {
      const element = palette.current, view = viewportRef.current
      if (mounted.current && element && view) {
        const position = relativePalette(view, element.getBoundingClientRect(), {
          left: current.origin.left + current.lastX-current.startX, top: current.origin.top + current.lastY-current.startY })
        drag.current = null
        flushSync(() => store.getState().setPosition(position))
      }
      await current.release()
    } catch (error) {
      failMove(error, current.release)
    }
    finally {
      if (drag.current === current) drag.current = null
      try { if (current.handle.hasPointerCapture(current.id)) current.handle.releasePointerCapture(current.id) } catch { /* Detached after tab close. */ }
    }
  }
  const moveDrag = (current: Drag): void => {
    const element = palette.current, view = viewportRef.current
    if (!current.release || !element || !view || current.ended) return
    const position = relativePalette(view, element.getBoundingClientRect(), {
      left: current.origin.left + current.lastX-current.startX, top: current.origin.top + current.lastY-current.startY })
    flushSync(() => setPlacement(clampPalette(view, element.getBoundingClientRect(), position)))
  }
  const startDrag = (event: ReactPointerEvent<HTMLButtonElement>): void => {
    if (event.button !== 0 || drag.current || resizing.current || !palette.current) return
    event.preventDefault(); event.stopPropagation(); setMenu(null)
    const current: Drag = { id: event.pointerId, handle: event.currentTarget, startX: event.clientX, startY: event.clientY,
      lastX: event.clientX, lastY: event.clientY, origin: placement, ended: false, finishing: false }
    drag.current = current
    try { current.handle.setPointerCapture(current.id) } catch { /* Synthetic test input. */ }
    void acquireNativeInput(owner).then(release => {
      current.release = release
      if (!mounted.current || current.ended) { current.ended = true; void finishDrag(current) }
      else moveDrag(current)
    }).catch(error => { drag.current = null; fail(error); try { current.handle.releasePointerCapture(current.id) } catch { /* No capture. */ } })
  }
  const dragEvent = (event: ReactPointerEvent<HTMLButtonElement>): void => {
    const current = drag.current
    if (!current || current.id !== event.pointerId) return
    event.preventDefault(); event.stopPropagation()
    if (event.type === 'pointermove' || event.type === 'pointerup') { current.lastX = event.clientX; current.lastY = event.clientY }
    if (event.type === 'pointermove') moveDrag(current)
    else { current.ended = true; void finishDrag(current) }
  }
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
      if (drag.current) { drag.current.ended = true; void finishDrag(drag.current) }
    }
  }, [])

  useEffect(() => {
    const close = (event: Event): void => {
      if (event.target instanceof Node && !palette.current?.contains(event.target) && !popup.current?.contains(event.target)) setMenu(null)
    }
    const key = (event: KeyboardEvent): void => {
      if (isNativeHostBlocked() || typeof event.key !== 'string') return
      if (event.key === 'Escape') { setMenu(null); return }
      const target = event.target instanceof Element ? event.target : null
      if (target?.closest('input,textarea,select,[contenteditable="true"]') || event.altKey) return
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
        event.preventDefault()
        if (!props.drawingsApi.historyBusy) void (event.shiftKey ? props.drawingsApi.redo() : props.drawingsApi.undo()).catch(fail)
      } else if (!event.metaKey && !event.ctrlKey && shortcuts[event.key.toLowerCase()]) {
        event.preventDefault(); store.getState().setActiveTool(shortcuts[event.key.toLowerCase()]!); setMenu(null)
      }
    }
    document.addEventListener('pointerdown', close, true); window.addEventListener('keydown', key)
    return () => { document.removeEventListener('pointerdown', close, true); window.removeEventListener('keydown', key) }
  }, [props.drawingsApi, store])

  const chooseTool = (value: InkTool): void => { store.getState().setActiveTool(value); setMenu(null) }
  const toolButton = (value: InkTool): JSX.Element => <button key={value} type="button" aria-label={labels[value]} title={labels[value]}
    aria-pressed={tool === value} data-tool={value} onClick={() => chooseTool(value)}><PdfToolIcon name={value} /></button>
  const exportPdf = async (): Promise<void> => {
    if (exporting) return
    setExporting(true); setMessage('')
    try { await props.drawingsApi.flush?.(); await props.flushAnnotations?.(); const result = await invoke('pdf:exportAnnotated', { courseId: props.courseId, relPath: props.relPath }); if (result.savedPath !== null) setMessage('주석 포함 PDF를 저장했어요.') }
    catch (error) { fail(error) } finally { if (mounted.current) setExporting(false) }
  }
  const keyboardMove = async (key: string): Promise<void> => {
    if (!viewport || !palette.current || resizing.current) return
    const release = await acquireNativeInput(owner)
    try {
      if (!mounted.current || !palette.current) { await release(); return }
      const point = { left: placement.left + (key === 'ArrowLeft' ? -24 : key === 'ArrowRight' ? 24 : 0), top: placement.top + (key === 'ArrowUp' ? -24 : key === 'ArrowDown' ? 24 : 0) }
      const frame = palette.current.getBoundingClientRect()
      flushSync(() => store.getState().setPosition(key === 'Home' ? { x: 0.5, y: 0 } : relativePalette(viewport, frame, point)))
      await release()
    } catch (error) { failMove(error, release) }
  }
  const toggleCollapsed = async (): Promise<void> => {
    if (resizing.current || drag.current) return
    resizing.current = true
    try {
      const release = await acquireNativeInput(owner)
      try {
        if (mounted.current) {
          flushSync(() => { setMenu(null); store.getState().setCollapsed(!store.getState().collapsed) })
          const element = palette.current, view = viewportRef.current
          if (element && view) flushSync(() => setPlacement(clampPalette(view, element.getBoundingClientRect(), store.getState().position)))
        }
        await release()
      } catch (error) { failMove(error, release, '필기 도구 접기·펴기') }
    } catch (error) { fail(error) }
    finally { resizing.current = false }
  }
  const maxWidth = Math.max(0, (viewport?.width ?? 0) - 24), maxHeight = Math.max(0, (viewport?.height ?? 0) - 24)
  const compact = !collapsed && (viewport?.width ?? 1000) < 560
  const quickFavorites = !collapsed && (viewport?.width ?? 0) >= 720
  return createPortal(<>
    <div ref={palette} className={`ipad-pdf-palette${compact ? ' ipad-pdf-palette--compact' : ''}`}
      role="toolbar" aria-label="PDF 필기 도구" data-bandal-native-overlay="true" data-collapsed={collapsed} hidden={blocked}
      style={{ ...placement, maxWidth, maxHeight, ...(compact ? { gridTemplateColumns: `repeat(${Math.max(1, Math.min(6, Math.floor((maxWidth-14)/46)))}, 44px)` } : {}), visibility: viewport && maxWidth >= 58 && maxHeight >= 58 ? 'visible' : 'hidden' }}>
      <button type="button" className="ipad-pdf-palette__drag" data-ipad-palette-drag="true" aria-label="필기 도구 이동" title="끌어서 이동 · 방향키로 이동 · Home으로 위치 초기화"
        onPointerDown={startDrag} onPointerMove={dragEvent} onPointerUp={dragEvent} onPointerCancel={dragEvent} onLostPointerCapture={dragEvent}
        onKeyDown={event => { if (['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(event.key)) { event.preventDefault(); event.stopPropagation(); void keyboardMove(event.key).catch(fail) } }}>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14M16 5v14" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeDasharray="1 5" /></svg>
      </button>
      {!collapsed && <>
      {core.map(toolButton)}
      {quickFavorites && favorites.map((preset, index) => <button key={index} type="button" className="ipad-pdf-quick-favorite"
        aria-label={`즐겨찾는 펜 ${index+1} 바로 선택`} title={`즐겨찾는 펜 ${index+1}: ${colorLabels[preset.color]}`}
        aria-pressed={tool === 'pen' && samePreset(preset, { color, width, opacity })} onClick={() => { store.getState().choosePreset(preset); setMenu(null) }}>
        <span className="ipad-pdf-swatch" data-color={preset.color} /><small>{index+1}</small>
      </button>)}
      <button type="button" aria-label="되돌리기" title="되돌리기 (⌘Z)" disabled={!props.drawingsApi.canUndo || props.drawingsApi.historyBusy} onClick={() => void props.drawingsApi.undo().catch(fail)}><PdfToolIcon name="undo" /></button>
      <button type="button" aria-label="다시 실행" title="다시 실행 (⇧⌘Z)" disabled={!props.drawingsApi.canRedo || props.drawingsApi.historyBusy} onClick={() => void props.drawingsApi.redo().catch(fail)}><PdfToolIcon name="redo" /></button>
      <button type="button" aria-label="필기 스타일" title="필기 스타일" aria-expanded={menu === 'styles'} onClick={() => setMenu(menu === 'styles' ? null : 'styles')}><span className="ipad-pdf-swatch" data-color={color} /></button>
      <button type="button" aria-label="추가 필기 도구" title="추가 필기 도구" aria-expanded={menu === 'tools'} onClick={() => setMenu(menu === 'tools' ? null : 'tools')}>···</button>
      <button type="button" aria-label="PDF 문서 도구" title="페이지 · 확대 · 페이지 필기" aria-expanded={menu === 'document'} onClick={() => setMenu(menu === 'document' ? null : 'document')}><span className="ipad-pdf-palette__page">{props.currentPage}<small>/{props.numPages}</small></span></button>
      </>}
      <button type="button" aria-label={collapsed ? '필기 도구 펴기' : '필기 도구 접기'} title={collapsed ? `필기 도구 펴기 · 현재 ${labels[tool]}` : '필기 도구 접기'} aria-expanded={!collapsed} onClick={() => void toggleCollapsed()}>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d={collapsed ? 'm9 5 7 7-7 7' : 'm15 5-7 7 7 7'} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
      </button>
    </div>
    {menu && <div ref={popup} className={`ipad-pdf-popover ipad-pdf-popover--${menu}`} role="dialog" aria-modal="false"
      aria-label={menu === 'styles' ? '필기 스타일' : menu === 'tools' ? '추가 필기 도구' : 'PDF 문서 도구'} data-bandal-native-overlay="true"
      style={{ ...popupPlacement, maxWidth, maxHeight }} onKeyDown={event => { if (event.key === 'Escape') setMenu(null) }}>
      <header><strong>{menu === 'styles' ? '필기 스타일' : menu === 'tools' ? '추가 도구' : 'PDF 문서'}</strong><button type="button" aria-label="도구 메뉴 닫기" onClick={() => setMenu(null)}>×</button></header>
      {menu === 'styles' && <>
        <div className="ipad-pdf-presets" role="group" aria-label="즐겨찾는 펜 3개">{favorites.map((preset, index) => <div key={index}>
          <button type="button" aria-label={`즐겨찾는 펜 ${index+1}: ${colorLabels[preset.color]}`} onClick={() => store.getState().choosePreset(preset)}><span className="ipad-pdf-swatch" data-color={preset.color} /><small>{index+1} · {Math.round(preset.width*1000)}</small></button>
          <button type="button" className="ipad-pdf-presets__save" aria-label={`즐겨찾는 펜 ${index+1}에 현재 펜 저장`} disabled={tool !== 'pen'} onClick={() => { store.getState().saveFavorite(index); setMessage(`즐겨찾는 펜 ${index+1}에 저장했어요.`) }}>현재 펜 저장</button>
        </div>)}</div>
        <div className="ipad-pdf-colors" role="group" aria-label="필기 색상">{PDF_COLORS.map(value => <button type="button" key={value} aria-label={colorLabels[value]} aria-pressed={color === value} onClick={() => { store.getState().setColor(value); store.getState().rememberPen() }}><span className="ipad-pdf-swatch" data-color={value} /></button>)}</div>
        <label>선 굵기<input type="range" aria-label="선 굵기" aria-valuetext={`${Math.round(width * 1000)} / 25`} min="1" max="25" step="1" value={width * 1000} onChange={event => store.getState().setWidth(Number(event.target.value) / 1000)} onPointerUp={() => store.getState().rememberPen()} onBlur={() => store.getState().rememberPen()} onKeyUp={() => store.getState().rememberPen()} /></label>
        <label>불투명도<input type="range" aria-label="불투명도" aria-valuetext={`${Math.round(opacity * 100)}%`} min="10" max="100" step="5" value={opacity * 100} onChange={event => store.getState().setOpacity(Number(event.target.value) / 100)} onPointerUp={() => store.getState().rememberPen()} onBlur={() => store.getState().rememberPen()} onKeyUp={() => store.getState().rememberPen()} /></label>
      </>}
      {menu === 'tools' && <div className="ipad-pdf-extra-tools">{additional.map(value => <div key={value}>{toolButton(value)}<span>{labels[value]}</span></div>)}</div>}
      {menu === 'document' && <div className="ipad-pdf-document-menu"><OriginalPdfToolbar {...{ ...props, hideDrawingTools: true }} />
        <button type="button" className="ipad-pdf-export" disabled={exporting} onClick={() => void exportPdf()}><PdfToolIcon name="export" />{exporting ? '내보내는 중…' : '주석 포함 PDF 내보내기'}</button></div>}
      {status && <p role="status">{status}</p>}
    </div>}
    {!menu && status && <div ref={statusElement} className="ipad-pdf-input-status" role="status" data-bandal-native-overlay="true"
      style={{ left: statusPlacement.left, top: statusPlacement.top, visibility: statusPlacement.visible ? 'visible' : 'hidden' }}>{status}</div>}
  </>, document.body)
}
