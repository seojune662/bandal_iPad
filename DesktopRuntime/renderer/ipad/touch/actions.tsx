import { useRef, type ReactNode } from 'react'
import './touch.css'

/** A sibling target leaves the original row's opening/drag/menu handlers intact. */
export function WhiteboardTouchActions({ label, disabled, children }: { label: string; disabled: boolean; children: ReactNode }): JSX.Element {
  const root = useRef<HTMLDivElement>(null)
  return <div className="ipad-whiteboard-actions" ref={root}>{children}<button type="button" className="ipad-touch-more"
    aria-label={`${label} 더 보기`} aria-haspopup="menu" disabled={disabled} onClick={event => {
      event.preventDefault(); event.stopPropagation()
      const row = root.current?.querySelector<HTMLButtonElement>('.whiteboards-group__row')
      if (!row || row.disabled) return
      const rect = event.currentTarget.getBoundingClientRect()
      row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: rect.left, clientY: rect.bottom }))
    }}>•••</button></div>
}

/** The card menu callback is also the desktop context-menu owner. */
export function BoardTouchActions({ label, disabled, onMenu, children }: {
  label: string; disabled: boolean; onMenu(x: number, y: number): void; children: ReactNode
}): JSX.Element {
  return <div className="ipad-board-actions">{children}<button type="button" className="ipad-touch-more"
    aria-label={`${label} 더 보기`} aria-haspopup="menu" disabled={disabled} onClick={event => {
      event.preventDefault(); event.stopPropagation()
      const rect = event.currentTarget.getBoundingClientRect()
      onMenu(rect.left, rect.bottom)
    }}>•••</button></div>
}
