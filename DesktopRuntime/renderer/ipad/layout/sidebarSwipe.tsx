import { useCallback, useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import { beginSidebarSwipe, moveSidebarSwipe, shouldCommitSidebarSwipe, sidebarSwipeThreshold, type SidebarSwipe } from './sidebarSwipePolicy'

type SidebarSwipeProps = {
  open: boolean
  disabled?: boolean
  /** The outer right edge of the mini rail, or the visible course sidebar. */
  boundary: number
  onOpen(): void
  onClose(): void
}

/** A touch-only swipe affordance inside the sidebar, clear of native document surfaces. */
export function IpadSidebarSwipe({ open, disabled = false, boundary, onOpen, onClose }: SidebarSwipeProps): JSX.Element | null {
  const root = useRef<HTMLButtonElement>(null)
  const gesture = useRef<{ pointerId: number; swipe: SidebarSwipe; viewportWidth: number; viewportHeight: number } | null>(null)
  const suppressClick = useRef(false)
  const [progress, setProgress] = useState<number | null>(null)
  const reset = useCallback(() => {
    const active = gesture.current
    gesture.current = null
    if (active && root.current?.hasPointerCapture(active.pointerId)) root.current.releasePointerCapture(active.pointerId)
    setProgress(null)
  }, [])
  const cancel = useCallback(() => {
    if (gesture.current) suppressClick.current = true
    reset()
  }, [reset])

  useEffect(() => {
    cancel()
  }, [open, disabled, boundary, cancel])
  useEffect(() => {
    const anotherPointer = (event: PointerEvent) => {
      if (gesture.current && event.pointerType === 'touch' && event.pointerId !== gesture.current.pointerId) cancel()
    }
    window.addEventListener('pointerdown', anotherPointer, true)
    window.addEventListener('resize', cancel)
    window.addEventListener('blur', cancel)
    return () => {
      window.removeEventListener('pointerdown', anotherPointer, true)
      window.removeEventListener('resize', cancel)
      window.removeEventListener('blur', cancel)
      gesture.current = null
    }
  }, [cancel])

  const start = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (disabled) return
    if (event.pointerType !== 'touch') { suppressClick.current = false; return }
    if (!event.isPrimary) return
    suppressClick.current = false
    event.stopPropagation()
    gesture.current = { pointerId: event.pointerId, swipe: beginSidebarSwipe(open, event.clientX, event.clientY, event.timeStamp),
      viewportWidth: window.innerWidth, viewportHeight: window.innerHeight }
    try { event.currentTarget.setPointerCapture(event.pointerId) } catch { /* Synthetic events do not own a platform pointer. */ }
  }
  const move = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const active = gesture.current
    if (!active || active.pointerId !== event.pointerId) return
    if (active.viewportWidth !== window.innerWidth || active.viewportHeight !== window.innerHeight) { cancel(); return }
    active.swipe = moveSidebarSwipe(active.swipe, event.clientX, event.clientY, event.timeStamp)
    if (active.swipe.phase === 'cancelled') { cancel(); return }
    if (active.swipe.phase === 'dragging') {
      event.preventDefault()
      event.stopPropagation()
      suppressClick.current = true
      setProgress(Math.min(1, active.swipe.distance / sidebarSwipeThreshold))
    }
  }
  const finish = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const active = gesture.current
    if (!active || active.pointerId !== event.pointerId) return
    if (active.viewportWidth !== window.innerWidth || active.viewportHeight !== window.innerHeight) { cancel(); return }
    const swipe = moveSidebarSwipe(active.swipe, event.clientX, event.clientY, event.timeStamp)
    const commit = shouldCommitSidebarSwipe(swipe, event.timeStamp)
    if (swipe.phase !== 'pending') {
      event.preventDefault()
      event.stopPropagation()
      suppressClick.current = true
    }
    reset()
    if (commit) (open ? onClose : onOpen)()
  }
  if (disabled) return null
  return <button ref={root} type="button" className="ipad-sidebar-swipe" data-bandal-native-overlay="true"
    data-ipad-sidebar-swipe={open ? 'close' : 'open'} data-swipe-active={progress !== null ? 'true' : 'false'}
    aria-label={open ? '사이드바 닫기' : '사이드바 열기'} aria-expanded={open}
    title={open ? '왼쪽으로 밀어 사이드바 닫기' : '오른쪽으로 밀어 사이드바 열기'}
    style={{ position: 'fixed', left: boundary - 16, top: 'calc(50% - 56px)', width: 16, height: 112,
      minWidth: 0, minHeight: 0, padding: 0, border: 0, borderRadius: 8, zIndex: 210,
      display: 'grid', placeItems: 'center', background: progress === null ? 'transparent' : 'var(--bg-hover, rgba(128,128,128,.12))',
      color: 'var(--text-muted, #8c8c8c)', touchAction: 'pan-y pinch-zoom', userSelect: 'none', WebkitUserSelect: 'none' }}
    onPointerDown={start} onPointerMove={move} onPointerUp={finish} onPointerCancel={cancel}
    onLostPointerCapture={event => { if (gesture.current?.pointerId === event.pointerId) cancel() }}
    onClick={event => {
      if (suppressClick.current && event.detail !== 0) { event.preventDefault(); event.stopPropagation(); suppressClick.current = false; return }
      suppressClick.current = false
      const toggle = open ? onClose : onOpen
      toggle()
    }}>
    <span aria-hidden="true" style={{ width: progress === null ? 3 : 4, height: 32 + (progress ?? 0) * 32,
      borderRadius: 4, background: 'currentColor', opacity: progress === null ? 0.45 : 0.85,
      pointerEvents: 'none', transition: progress === null ? 'height 120ms ease, opacity 120ms ease' : 'none' }} />
  </button>
}
