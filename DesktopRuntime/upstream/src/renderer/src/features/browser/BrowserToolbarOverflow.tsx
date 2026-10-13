import { useEffect, useId, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Tooltip } from '../../components/Tooltip'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { acquirePointerPassthrough } from './webviewPassthrough'

/** Keep the address and session visible when the browser is in a narrow split. */
export function BrowserToolbarOverflow({ children, isPrivate, active }: { children: ReactNode; isPrivate: boolean; active: boolean }): JSX.Element {
  const [anchor, setAnchor] = useState<DOMRect | null>(null)
  const trigger = useRef<HTMLButtonElement>(null)
  const dialog = useRef<HTMLDivElement>(null)
  const id = useId()
  const open = active && anchor !== null
  const close = (): void => setAnchor(null)
  useFocusTrap(dialog, { active: open, onEscape: close })
  useViewportBounds(dialog)
  useEffect(() => { if (!active) close() }, [active])
  useEffect(() => {
    if (!open) return
    const release = acquirePointerPassthrough()
    const outside = (event: PointerEvent): void => {
      if (event.target instanceof Node && !dialog.current?.contains(event.target) && !trigger.current?.contains(event.target)) close()
    }
    const observer = new ResizeObserver(() => {
      if (trigger.current?.getBoundingClientRect().width === 0) close()
      else if (trigger.current) setAnchor(trigger.current.getBoundingClientRect())
    })
    const chrome = trigger.current?.closest('.browser-chrome')
    if (chrome) observer.observe(chrome)
    document.addEventListener('pointerdown', outside, true)
    return () => { release(); observer.disconnect(); document.removeEventListener('pointerdown', outside, true) }
  }, [open])
  return <>
    <div className="browser-toolbar__utilities">{children}</div>
    <Tooltip label={isPrivate ? '브라우저 도구 · 시크릿 모드 사용 중' : '브라우저 도구'} placement="bottom">
      <button ref={trigger} type="button" className="browser-nav-button browser-toolbar__more"
        aria-label="브라우저 도구 더 보기" aria-haspopup="dialog" aria-controls={open ? id : undefined}
        aria-expanded={open} data-private={isPrivate || undefined}
        onClick={event => anchor ? close() : setAnchor(event.currentTarget.getBoundingClientRect())}>
        <svg aria-hidden="true" viewBox="0 0 24 24" width="1em" height="1em" fill="currentColor"><circle cx="5" cy="12" r="1.75" /><circle cx="12" cy="12" r="1.75" /><circle cx="19" cy="12" r="1.75" /></svg>
      </button>
    </Tooltip>
    {open && anchor !== null && createPortal(<div ref={dialog} id={id} role="dialog" aria-label="브라우저 도구" className="browser-toolbar-menu"
      style={{ top: anchor.bottom + 6, left: Math.max(8, Math.min(anchor.right - 220, window.innerWidth - 228)) }}
      onClick={event => { if ((event.target as HTMLElement).closest('button:not(:disabled)')) close() }}>
      <span className="browser-toolbar-menu__title">브라우저 도구</span>
      {children}
    </div>, document.body)}
  </>
}
