import { useEffect, type RefObject } from 'react'
import { focusableElements } from './useFocusTrap'

/** Consistent keyboard entry, dismissal and focus return for floating menus. */
export function useDismissableMenu(
  active: boolean,
  ref: RefObject<HTMLElement>,
  dismiss: () => void
): void {
  useEffect(() => {
    if (!active) return
    const trigger = document.activeElement
    const frame = requestAnimationFrame(() => {
      if (ref.current) focusableElements(ref.current)[0]?.focus()
    })
    const pointer = (event: PointerEvent): void => {
      const target = event.target as Node
      if (
        !ref.current?.contains(target) &&
        !(trigger instanceof HTMLElement && trigger.contains(target))
      )
        dismiss()
    }
    const keyboard = (event: KeyboardEvent): void => {
      if (event.key === 'Escape' && !event.defaultPrevented) {
        event.preventDefault()
        event.stopPropagation()
        dismiss()
        if (trigger instanceof HTMLElement && trigger.isConnected)
          trigger.focus()
      }
    }
    window.addEventListener('pointerdown', pointer)
    window.addEventListener('keydown', keyboard, true)
    window.addEventListener('blur', dismiss)
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('pointerdown', pointer)
      window.removeEventListener('keydown', keyboard, true)
      window.removeEventListener('blur', dismiss)
    }
  }, [active, ref, dismiss])
}
