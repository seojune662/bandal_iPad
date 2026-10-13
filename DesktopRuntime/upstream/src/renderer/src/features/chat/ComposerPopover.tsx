import { useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { createPortal } from 'react-dom'

/** A viewport-bounded popup. Escape closes the active menu. */
export function ComposerPopover({ anchor, label, onClose, children }: {
  anchor: RefObject<HTMLElement>; label: string; onClose: () => void; children: ReactNode
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState({ left: 8, top: 8, width: 320, maxHeight: 400 })
  useLayoutEffect(() => {
    const place = (): void => {
      const rect = anchor.current?.getBoundingClientRect()
      if (!rect) return
      const surface = anchor.current?.closest('.chat-tab')?.getBoundingClientRect()
      const leftEdge = Math.max(8, (surface?.left ?? 0) + 8)
      const rightEdge = Math.min(window.innerWidth - 8, (surface?.right ?? window.innerWidth) - 8)
      const width = Math.min(360, rightEdge - leftEdge)
      const above = rect.top - 16, below = window.innerHeight - rect.bottom - 16
      const up = above >= Math.min(ref.current?.scrollHeight ?? 400, 400) || above > below
      const maxHeight = Math.max(80, Math.min(480, up ? above : below))
      const height = Math.min(ref.current?.scrollHeight ?? 400, maxHeight)
      setPosition({ left: Math.max(leftEdge, Math.min(rect.right - width, rightEdge - width)), top: up ? Math.max(8, rect.top - height - 8) : rect.bottom + 8, width, maxHeight })
    }
    place()
    const observer = new ResizeObserver(place)
    if (ref.current) observer.observe(ref.current)
    window.addEventListener('resize', place)
    const outside = (event: PointerEvent): void => {
      if (!ref.current?.contains(event.target as Node) && !anchor.current?.contains(event.target as Node)) onClose()
    }
    const key = (event: KeyboardEvent): void => {
      if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key) && document.activeElement?.tagName === 'BUTTON' && ref.current?.contains(document.activeElement)) {
        const items = [...ref.current.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')]
        const index = items.indexOf(document.activeElement as HTMLButtonElement)
        const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length
        event.preventDefault(); event.stopImmediatePropagation(); items[next]?.focus()
      }
      if (event.key === 'Escape') {
        event.preventDefault(); event.stopImmediatePropagation(); onClose(); anchor.current?.focus()
      }
    }
    document.addEventListener('pointerdown', outside, true)
    window.addEventListener('keydown', key, true)
    ref.current?.querySelector<HTMLElement>('button:not(:disabled),select,input')?.focus()
    return () => { observer.disconnect(); window.removeEventListener('resize', place); document.removeEventListener('pointerdown', outside, true); window.removeEventListener('keydown', key, true) }
  }, [anchor, onClose])
  return createPortal(<div ref={ref} className="chat-composer-popover" role="dialog" aria-label={label} style={position}>{children}</div>, document.body)
}
