export const PROGRESS_DELAY_MS = 250

interface MainFrameLoadingTarget {
  isLoadingMainFrame(): boolean
}

/**
 * `did-stop-loading` is also emitted when a subframe finishes. While the main
 * frame is still loading, that event must not turn off the tab's load state.
 * A detached guest cannot answer, so preserve the event's normal stop
 * semantics and let the next navigation event repair the state.
 */
export function shouldFinishMainFrameLoading(
  target: MainFrameLoadingTarget
): boolean {
  try {
    return !target.isLoadingMainFrame()
  } catch {
    return true
  }
}

export function shouldHandleLoadFailure(isMainFrame: boolean): boolean {
  return isMainFrame
}

/**
 * Delays only the rising edge. The falling edge is immediate and CSS owns the
 * 180ms opacity fade, so a load shorter than the delay never flashes a bar.
 */
export function scheduleProgressVisibility(
  loading: boolean,
  setVisible: (visible: boolean) => void
): () => void {
  if (!loading) {
    setVisible(false)
    return () => undefined
  }

  const timer = globalThis.setTimeout(
    () => setVisible(true),
    PROGRESS_DELAY_MS
  )
  return () => globalThis.clearTimeout(timer)
}
