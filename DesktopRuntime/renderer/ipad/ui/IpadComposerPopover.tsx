import { useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { createPortal } from 'react-dom'
import { focusableElements } from '../../../upstream/src/renderer/src/components/useFocusTrap'

/** A native-overlay-aware chat menu bounded by the keyboard's visual viewport. */
export function IpadComposerPopover({ anchor, label, onClose, children }: {
  anchor: RefObject<HTMLElement>; label: string; onClose: () => void; children: ReactNode
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const close = useRef(onClose)
  close.current = onClose
  const [position, setPosition] = useState({ left: 8, top: 8, width: 320, maxHeight: 400 })
  useLayoutEffect(() => {
    const viewport = window.visualViewport
    const container = ref.current
    const place = (): void => {
      const rect = anchor.current?.getBoundingClientRect()
      if (!rect) return
      const surface = anchor.current?.closest('.chat-tab')?.getBoundingClientRect()
      const viewportLeft = viewport?.offsetLeft ?? 0
      const viewportTop = viewport?.offsetTop ?? 0
      const viewportRight = viewportLeft + (viewport?.width ?? window.innerWidth)
      const viewportBottom = viewportTop + (viewport?.height ?? window.innerHeight)
      const leftEdge = Math.max(viewportLeft + 8, (surface?.left ?? viewportLeft) + 8)
      const rightEdge = Math.min(viewportRight - 8, (surface?.right ?? viewportRight) - 8)
      const width = Math.max(0, Math.min(360, rightEdge - leftEdge))
      const topEdge = viewportTop + 8
      const bottomEdge = viewportBottom - 8
      const above = Math.max(0, Math.min(rect.top - 8, bottomEdge) - topEdge)
      const below = Math.max(0, bottomEdge - Math.max(rect.bottom + 8, topEdge))
      const element = ref.current
      const border = element ? parseFloat(getComputedStyle(element).borderTopWidth) + parseFloat(getComputedStyle(element).borderBottomWidth) : 0
      const contentHeight = element ? Math.max(element.scrollHeight + border + 1, element.getBoundingClientRect().height) : 400
      const desired = Math.min(contentHeight, 480)
      const up = above >= desired || above > below
      const maxHeight = Math.max(0, Math.min(480, up ? above : below))
      const height = Math.min(desired, maxHeight)
      const top = up ? Math.max(topEdge, Math.min(rect.top - 8, bottomEdge) - height) : Math.min(bottomEdge - height, Math.max(topEdge, rect.bottom + 8))
      const next = { left: Math.max(leftEdge, Math.min(rect.right - width, rightEdge - width)), top, width, maxHeight }
      setPosition(previous => Object.keys(next).every(key => previous[key as keyof typeof next] === next[key as keyof typeof next]) ? previous : next)
    }
    place()
    const observer = new ResizeObserver(place)
    if (ref.current) observer.observe(ref.current)
    if (anchor.current) observer.observe(anchor.current)
    window.addEventListener('resize', place)
    viewport?.addEventListener('resize', place)
    viewport?.addEventListener('scroll', place)
    const outside = (event: PointerEvent): void => {
      if (!ref.current?.contains(event.target as Node) && !anchor.current?.contains(event.target as Node)) close.current()
    }
    const key = (event: KeyboardEvent): void => {
      const container = ref.current
      if (!container || event.defaultPrevented) return
      if (event.key === 'Escape') {
        event.preventDefault(); event.stopImmediatePropagation(); close.current(); anchor.current?.focus({ preventScroll: true })
      } else if (event.key === 'Tab') {
        const items = focusableElements(container)
        const index = items.indexOf(document.activeElement as HTMLElement)
        const next = index < 0 ? (event.shiftKey ? items.length - 1 : 0) : (index + (event.shiftKey ? -1 : 1) + items.length) % items.length
        event.preventDefault(); event.stopImmediatePropagation(); (items[next] ?? container).focus({ preventScroll: true })
      } else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key) && document.activeElement?.tagName === 'BUTTON' && container.contains(document.activeElement)) {
        const items = focusableElements(container).filter(element => element.tagName === 'BUTTON')
        const index = items.indexOf(document.activeElement as HTMLElement)
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length
        event.preventDefault(); event.stopImmediatePropagation(); items[next]?.focus({ preventScroll: true })
      }
    }
    document.addEventListener('pointerdown', outside, true)
    window.addEventListener('keydown', key, true)
    if (ref.current) (focusableElements(ref.current)[0] ?? ref.current).focus({ preventScroll: true })
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', place)
      viewport?.removeEventListener('resize', place)
      viewport?.removeEventListener('scroll', place)
      document.removeEventListener('pointerdown', outside, true)
      window.removeEventListener('keydown', key, true)
      if (container?.contains(document.activeElement)) anchor.current?.focus({ preventScroll: true })
    }
  }, [anchor])
  return createPortal(<div ref={ref} tabIndex={-1} className="chat-composer-popover" role="dialog" aria-label={label} data-bandal-native-overlay="true" style={position}>{children}</div>, document.body)
}
