import { useLayoutEffect, useState } from 'react'

/** Retain state during an exit transition; reopening cancels the pending exit. */
export function usePresence(open: boolean, duration: number): boolean {
  const [retained, setRetained] = useState(open)
  useLayoutEffect(() => {
    if (open) { setRetained(true); return }
    const media = window.matchMedia('(prefers-reduced-motion: reduce)')
    if (media.matches) { setRetained(false); return }
    const timer = window.setTimeout(() => setRetained(false), duration)
    const changed = (): void => { if (media.matches) setRetained(false) }
    media.addEventListener('change', changed)
    return () => { clearTimeout(timer); media.removeEventListener('change', changed) }
  }, [open, duration])
  return open || retained
}
