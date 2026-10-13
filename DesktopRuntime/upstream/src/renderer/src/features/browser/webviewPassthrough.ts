/**
 * [M3-F] Pointer-passthrough signal for the webview layer.
 *
 * A <webview> swallows the pointer stream, which breaks any app-owned
 * overlay/menu/drag happening above it. While at least one passthrough
 * token is held, BrowserWebviewLayer sets `pointer-events: none` on every
 * guest. The layer itself wires dockview drags (HTML5 dnd + sash pointer
 * drags) and the new-tab menu; other features may acquire a token here
 * without importing anything browser-specific beyond this module.
 */

import { setNativeHostBlocked } from './nativeHostVisibility'

type PassthroughListener = (active: boolean) => void

let tokenCount = 0
const listeners = new Set<PassthroughListener>()

function notify(): void {
  const active = tokenCount > 0
  setNativeHostBlocked('passthrough', active)
  for (const listener of listeners) listener(active)
}

/** Hold pointer passthrough; call the returned release exactly once. */
export function acquirePointerPassthrough(): () => void {
  tokenCount += 1
  if (tokenCount === 1) notify()
  let released = false
  return () => {
    if (released) return
    released = true
    tokenCount -= 1
    if (tokenCount === 0) notify()
  }
}

export function isPointerPassthroughActive(): boolean {
  return tokenCount > 0
}

export function onPointerPassthrough(
  listener: PassthroughListener
): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
