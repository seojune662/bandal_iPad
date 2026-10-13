import { tabDragSession } from '../workspace/tabDragSession'
import { guestActions } from './guestActions'
import { isNativeHostBlocked, onNativeHostBlocked } from './nativeHostVisibility'

/** Tab activation may happen on pointerdown, before native DnD owns the press. */
export function scheduleBrowserAutofocus(tabId: string, isCurrent: () => boolean): () => void {
  let pending = true
  let frame: number | null = null
  const eligible = (): boolean => pending && isCurrent() && !tabDragSession.isFocusBlocked() && !isNativeHostBlocked()
  const request = (): void => {
    if (frame !== null || !eligible()) return
    frame = window.requestAnimationFrame(() => {
      frame = null
      if (!eligible()) return
      guestActions.focus(tabId, () => {
        // Page creation is asynchronous. Recheck when the native focus IPC is
        // actually sent, including after this panel has hidden or unmounted.
        if (!eligible()) return false
        pending = false
        return true
      })
    })
  }
  const cancel = (): void => {
    pending = false
    if (frame !== null) window.cancelAnimationFrame(frame)
    frame = null
  }
  const stopSession = tabDragSession.subscribe(request)
  const stopHost = onNativeHostBlocked(request)
  // Losing the app window cancels this activation's focus request; releasing
  // a tab inside the window can resume it through the session subscription.
  window.addEventListener('blur', cancel)
  request()
  return () => { cancel(); stopSession(); stopHost(); window.removeEventListener('blur', cancel) }
}
