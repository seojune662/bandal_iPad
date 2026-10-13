import { useEffect, useId, useLayoutEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import './pageImageCopy.css'

export function PageImageContextMenu({ x, y, label, disabledReason, inkDisabledReason, onCopy, onClose }: {
  x: number
  y: number
  label: string
  disabledReason?: string | undefined
  inkDisabledReason?: string | undefined
  onCopy: (includeInk: boolean) => void
  onClose: (restoreFocus?: boolean) => void
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const reasonId = useId()
  const reason = disabledReason ?? inkDisabledReason
  useLayoutEffect(() => {
    const node = ref.current
    if (!node) return
    node.style.left = `${Math.max(8, Math.min(x, window.innerWidth - node.offsetWidth - 8))}px`
    node.style.top = `${Math.max(8, Math.min(y, window.innerHeight - node.offsetHeight - 8))}px`
    ;(node.querySelector<HTMLButtonElement>('button:not(:disabled)') ?? node).focus({ preventScroll: true })
  }, [x, y])
  useEffect(() => {
    const dismiss = (event: PointerEvent): void => { if (!ref.current?.contains(event.target as Node)) onClose(false) }
    const close = (): void => onClose(false)
    window.addEventListener('pointerdown', dismiss)
    window.addEventListener('blur', close)
    window.addEventListener('resize', close)
    return () => {
      window.removeEventListener('pointerdown', dismiss)
      window.removeEventListener('blur', close)
      window.removeEventListener('resize', close)
    }
  }, [onClose])
  return createPortal(<div ref={ref} role="menu" tabIndex={-1} aria-label={`${label} 메뉴`} aria-describedby={reason ? reasonId : undefined} className="page-image-menu" onKeyDown={(event) => {
    if (event.key === 'Escape' || event.key === 'Tab') { event.preventDefault(); event.stopPropagation(); onClose() }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || event.key === 'Home' || event.key === 'End') {
      event.preventDefault()
      const buttons = Array.from(ref.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? [])
      const index = buttons.indexOf(document.activeElement as HTMLButtonElement)
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : buttons.length - 1)) % buttons.length
      buttons[next]?.focus({ preventScroll: true })
    }
  }}>
    <button role="menuitem" type="button" disabled={!!(disabledReason ?? inkDisabledReason)} onClick={() => onCopy(true)}>이미지로 복사</button>
    <button role="menuitem" type="button" disabled={!!disabledReason} onClick={() => onCopy(false)}>원본만 이미지로 복사</button>
    {reason && <p id={reasonId} className="page-image-menu__reason">{reason}</p>}
  </div>, document.body)
}
