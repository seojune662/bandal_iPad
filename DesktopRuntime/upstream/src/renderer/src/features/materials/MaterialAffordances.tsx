import { cloneElement, createContext, lazy, Suspense, useCallback, useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ButtonHTMLAttributes, type ReactElement, type ReactNode } from 'react'
import { createPortal, flushSync } from 'react-dom'
import type { MaterialNode } from '../../../../shared/types/materials'
import type { PersonalBoard } from '../../../../shared/types/whiteboard'
import type { RecordingSession } from '../../../../shared/recording'
import { invoke, onPush } from '../../lib/ipc'
import { retainedTabDescriptors, useWorkspaceStore } from '../../stores/workspaceStore'
import { isRecentMaterial, MATERIAL_NEW_DURATION_MS, materialStatusKey, openMaterialKeys, whiteboardStatusKey } from './materialStatus'
import './materialAffordances.css'

export const MATERIAL_HOVER_DELAY_MS = 450
type PreviewTarget = { courseId: string; node: MaterialNode; board?: never } | { courseId: string; board: PersonalBoard; node?: never }
interface HoverState { target: PreviewTarget; anchor: HTMLElement }
interface AffordancesContextValue {
  openKeys: ReadonlySet<string>
  activeAnchor: HTMLElement | null
  tooltipId: string
  show: (target: PreviewTarget, anchor: HTMLElement) => void
  hide: (anchor?: HTMLElement) => void
}
const AffordancesContext = createContext<AffordancesContextValue | null>(null)
const MaterialPreviewContent = lazy(() => import('./preview/MaterialPreviewContent').then(module => ({ default: module.MaterialPreviewContent })))
const WhiteboardPreviewContent = lazy(() => import('./preview/MaterialPreviewContent').then(module => ({ default: module.WhiteboardPreviewContent })))

function unavailableAnchor(anchor: HTMLElement): boolean {
  return !anchor.isConnected || anchor.closest('[inert], [hidden], [aria-hidden="true"]') !== null
}

function targetKey(target: PreviewTarget): string {
  return target.board ? whiteboardStatusKey(target.courseId, target.board.id) : materialStatusKey(target.courseId, target.node.relPath)
}

function useRecent(addedAt: number | undefined): boolean {
  const [now, setNow] = useState(Date.now)
  useEffect(() => {
    const current = Date.now()
    setNow(current)
    if (addedAt === undefined || !Number.isFinite(addedAt)) return
    const delay = addedAt > current ? addedAt - current : addedAt + MATERIAL_NEW_DURATION_MS - current
    if (delay <= 0) return
    const timer = window.setTimeout(() => setNow(Date.now()), Math.min(delay, 2_147_483_647))
    return () => window.clearTimeout(timer)
  }, [addedAt, now >= (addedAt ?? 0)])
  return isRecentMaterial(addedAt, now)
}

function StateIcons({ open, recent }: { open: boolean; recent: boolean }): JSX.Element {
  const label = [open && '탭에 열림', recent && '최근 추가됨'].filter(Boolean).join(' · ')
  return <span className="material-state" role={label ? 'img' : undefined} aria-label={label || undefined} aria-hidden={!label || undefined}>
    <svg className="material-state__tab" data-visible={open} viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.25" aria-hidden="true">
      <path d="M2.5 13.5h11v-10h-5l-1-1h-5zM2.5 6h11" strokeLinejoin="round" />
    </svg>
    <span className="material-state__new" data-visible={recent} />
  </span>
}

/** Augment the existing button without adding a hit target or changing drag behavior. */
export function MaterialRowAffordance({ target, children }: { target: PreviewTarget; children: ReactElement<ButtonHTMLAttributes<HTMLButtonElement>> }): JSX.Element {
  const context = useContext(AffordancesContext)
  const anchor = useRef<HTMLButtonElement | null>(null)
  const suppressFocus = useRef(false)
  const recent = useRecent(target.board?.addedAt ?? target.node?.addedAt)
  const open = context?.openKeys.has(targetKey(target)) ?? false
  const hide = context?.hide
  useEffect(() => () => { if (anchor.current) hide?.(anchor.current) }, [hide])
  if (target.node?.kind === 'dir') return children
  const props = children.props
  return cloneElement(children, {
    title: undefined,
    'aria-describedby': context?.activeAnchor === anchor.current && anchor.current ? context.tooltipId : props['aria-describedby'],
    ...({ 'data-material-open': open || undefined, 'data-material-new': recent || undefined } as Record<string, unknown>),
    onPointerEnter: event => { props.onPointerEnter?.(event); anchor.current = event.currentTarget; if (!event.buttons && !event.currentTarget.disabled) context?.show(target, event.currentTarget) },
    onPointerLeave: event => { props.onPointerLeave?.(event); context?.hide(event.currentTarget) },
    onPointerDown: event => { suppressFocus.current = true; context?.hide(); props.onPointerDown?.(event) },
    onFocus: event => { props.onFocus?.(event); anchor.current = event.currentTarget; if (!suppressFocus.current) context?.show(target, event.currentTarget); suppressFocus.current = false },
    onBlur: event => { suppressFocus.current = false; context?.hide(event.currentTarget); props.onBlur?.(event) },
    onClick: event => { context?.hide(); props.onClick?.(event) },
    onContextMenu: event => { context?.hide(); props.onContextMenu?.(event) },
    onDragStart: event => { flushSync(() => context?.hide()); props.onDragStart?.(event) },
    onKeyDown: event => { if (event.key === 'Escape') context?.hide(); props.onKeyDown?.(event) }
  }, <>{props.children}<StateIcons open={open} recent={recent} /></>)
}

export function MaterialAffordancesProvider({ courseId, children }: { courseId: string | null; children: ReactNode }): JSX.Element {
  const openTabs = useWorkspaceStore(state => state.openTabs)
  const tabs = useMemo(() => retainedTabDescriptors(), [openTabs, courseId])
  const hasRecording = tabs.some(tab => tab.kind === 'recording' && tab.payload.courseId === courseId)
  const [recordings, setRecordings] = useState<RecordingSession[]>([])
  const [hover, setHover] = useState<HoverState | null>(null)
  const pending = useRef<HoverState | null>(null)
  const timer = useRef<number | null>(null)
  const tooltipId = useId()
  const hide = useCallback((anchor?: HTMLElement): void => {
    if (anchor && pending.current?.anchor !== anchor) return
    if (timer.current !== null) window.clearTimeout(timer.current)
    timer.current = null
    pending.current = null
    setHover(null)
  }, [])
  const show = useCallback((target: PreviewTarget, anchor: HTMLElement): void => {
    if (unavailableAnchor(anchor)) return
    if (pending.current?.anchor === anchor) return
    hide()
    const next = { target, anchor }
    pending.current = next
    timer.current = window.setTimeout(() => {
      timer.current = null
      if (pending.current === next && !unavailableAnchor(anchor)) setHover(next)
    }, MATERIAL_HOVER_DELAY_MS)
  }, [hide])
  useEffect(() => {
    hide()
    return hide
  }, [courseId, hide])
  useEffect(() => {
    let cancelled = false
    setRecordings([])
    const refresh = (): void => {
      if (!courseId || !hasRecording) return
      void invoke('recordings:list', { courseId }).then(sessions => { if (!cancelled) setRecordings(sessions) }).catch(() => {})
    }
    refresh()
    const offChanged = onPush('materials:changed', event => { if (event.courseId === courseId) { hide(); refresh() } })
    const offRecording = onPush('recordings:event', event => {
      if (event.session.courseId !== courseId) return
      setRecordings(current => [...current.filter(item => item.id !== event.session.id), event.session])
    })
    return () => { cancelled = true; offChanged(); offRecording() }
  }, [courseId, hasRecording, hide])
  useEffect(() => {
    const dismiss = (): void => hide()
    const dismissHiddenAnchor = (): void => {
      if (pending.current && (unavailableAnchor(pending.current.anchor) || document.visibilityState === 'hidden')) hide()
    }
    const observer = new MutationObserver(dismissHiddenAnchor)
    observer.observe(document.body, { subtree: true, attributes: true, attributeFilter: ['inert', 'hidden', 'aria-hidden'] })
    const keydown = (event: KeyboardEvent): void => { if (event.key === 'Escape') hide() }
    window.addEventListener('scroll', dismiss, true)
    window.addEventListener('resize', dismiss)
    window.addEventListener('blur', dismiss)
    window.addEventListener('keydown', keydown)
    document.addEventListener('pointerdown', dismiss, true)
    document.addEventListener('contextmenu', dismiss, true)
    document.addEventListener('dragstart', dismiss, true)
    document.addEventListener('visibilitychange', dismissHiddenAnchor)
    return () => {
      observer.disconnect()
      window.removeEventListener('scroll', dismiss, true)
      window.removeEventListener('resize', dismiss)
      window.removeEventListener('blur', dismiss)
      window.removeEventListener('keydown', keydown)
      document.removeEventListener('pointerdown', dismiss, true)
      document.removeEventListener('contextmenu', dismiss, true)
      document.removeEventListener('dragstart', dismiss, true)
      document.removeEventListener('visibilitychange', dismissHiddenAnchor)
    }
  }, [hide])
  const openKeys = useMemo(() => openMaterialKeys(tabs, recordings), [tabs, recordings])
  const value = useMemo(() => ({ openKeys, activeAnchor: hover?.anchor ?? null, tooltipId, show, hide }), [openKeys, hover, tooltipId, show, hide])
  return <AffordancesContext.Provider value={value}>{children}{hover && createPortal(
    <MaterialHoverCard key={targetKey(hover.target)} hover={hover} id={tooltipId} open={openKeys.has(targetKey(hover.target))} />,
    document.body
  )}</AffordancesContext.Provider>
}

export function positionMaterialPreview(anchor: Pick<DOMRect, 'left' | 'right' | 'top'>, width: number, height: number, viewportWidth: number, viewportHeight: number): { left: number; top: number } {
  const margin = 8
  const preferred = anchor.left - width - margin
  const left = preferred >= margin ? preferred : anchor.right + margin
  return { left: Math.max(margin, Math.min(left, viewportWidth - width - margin)), top: Math.max(margin, Math.min(anchor.top, viewportHeight - height - margin)) }
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function MaterialHoverCard({ hover: { target, anchor }, id, open }: { hover: HoverState; id: string; open: boolean }): JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState<{ left: number; top: number } | null>(null)
  const [metadata, setMetadata] = useState<{ size: number; mtime: number } | null>(null)
  const recent = useRecent(target.board?.addedAt ?? target.node?.addedAt)
  const name = target.board?.title ?? target.node!.name
  const path = target.node?.relPath
  const size = metadata?.size ?? target.node?.size
  const mtime = metadata?.mtime ?? target.node?.mtime ?? (target.board ? Date.parse(target.board.updatedAt) : undefined)
  const type = target.board ? '화이트보드' : (name.includes('.') ? name.split('.').at(-1)!.toUpperCase() : '파일')
  useLayoutEffect(() => {
    const element = ref.current
    if (!element) return
    const update = (): void => {
      const rect = element.getBoundingClientRect()
      setPosition(positionMaterialPreview(anchor.getBoundingClientRect(), rect.width, rect.height, window.innerWidth, window.innerHeight))
    }
    update()
    const observer = new ResizeObserver(update)
    observer.observe(element)
    return () => observer.disconnect()
  }, [anchor])
  return <div ref={ref} id={id} role="tooltip" className="material-preview" data-positioned={position !== null} style={position ?? { left: 0, top: 0 }}>
    <div className="material-preview__heading">{name}</div>
    {path?.includes('/') && <div className="material-preview__path">{path}</div>}
    <div className="material-preview__body">
      <Suspense fallback={<span>미리보기 불러오는 중…</span>}>
      {target.board ? <WhiteboardPreviewContent courseId={target.courseId} board={target.board} /> : <MaterialPreviewContent courseId={target.courseId} node={target.node} onMetadata={setMetadata} />}
      </Suspense>
    </div>
    <div className="material-preview__metadata">{[type, size !== undefined ? formatBytes(size) : null, mtime ? `${new Date(mtime).toLocaleDateString('ko-KR')} 수정` : null].filter(Boolean).join(' · ')}</div>
    {(recent || open) && <div className="material-preview__status">{[recent && '최근 추가됨 · 24시간 유지', open && '탭에 열림'].filter(Boolean).join(' · ')}</div>}
  </div>
}
