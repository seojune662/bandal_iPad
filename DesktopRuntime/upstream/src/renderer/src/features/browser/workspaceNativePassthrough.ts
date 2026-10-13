import { tabDragSession } from '../workspace/tabDragSession'
import { acquirePointerPassthrough } from './webviewPassthrough'

/** Hide native pages in the dragstart dispatch, before a held tab crosses them. */
export function installWorkspaceNativePassthrough(): () => void {
  let release: (() => void) | null = null
  const reflect = (): void => {
    if (tabDragSession.getSnapshot() !== null) {
      release ??= acquirePointerPassthrough()
    } else {
      release?.()
      release = null
    }
  }
  // The native drag must own the pointer before any WebContentsView is hidden.
  // Hiding it on pointerdown can cancel Windows' pressed-pointer stream before
  // Chromium emits dragstart. Subscribe directly instead of awaiting React's
  // render/layout effect so suppression still begins during dragstart itself.
  const unsubscribe = tabDragSession.subscribe(reflect)
  reflect()
  return () => {
    unsubscribe()
    release?.()
  }
}
