/**
 * The desktop shortcuts and editor handlers require KeyboardEvent.key to be a
 * string. Keep malformed keydown events out of those handlers at the iPad
 * platform boundary. This does not cancel the browser's default editing action
 * or alter composition/beforeinput/input events.
 *
 * This is defensive compatibility, not evidence that an observed renderer
 * exception was caused by a malformed native keyboard event.
 */
const reportedWindows = new WeakSet<Window>()

export function installNativeKeyboardCompatibility(target: Window = window, onMalformedKey?: () => void): () => void {
  const capture = (event: KeyboardEvent): void => {
    if (typeof event.key === 'string') return
    event.stopImmediatePropagation()
    if (onMalformedKey && !reportedWindows.has(target)) {
      reportedWindows.add(target)
      onMalformedKey()
    }
  }
  target.addEventListener('keydown', capture, true)
  return () => target.removeEventListener('keydown', capture, true)
}
