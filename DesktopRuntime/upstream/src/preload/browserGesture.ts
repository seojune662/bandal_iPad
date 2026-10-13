import { ipcRenderer } from 'electron'
import { BROWSER_SWIPE_IDLE_MS, waitForSwipe, type BrowserSwipeState } from './browserSwipe'
import { createParentSwipePolicy } from './browserSwipeParents'

// This isolated preload exposes no functions to websites and accepts only
// trusted wheel input. It never loads the privileged app preload.
let state: BrowserSwipeState = { canBack: false, canForward: false, enabled: false, theme: 'light' }
const parentPolicy = createParentSwipePolicy()
let lastRefresh = -Infinity
let lastWheel = -Infinity
let refreshVersion = 0
function refreshState(): void {
  lastRefresh = performance.now()
  const version = ++refreshVersion
  void ipcRenderer.invoke('browser-gesture:state')
    .then(next => { if (version === refreshVersion) state = next })
    .catch(() => { if (version === refreshVersion) state = { ...state, enabled: false } })
}
window.addEventListener('wheel', event => {
  if (!event.isTrusted) return
  const now = performance.now()
  const startsGesture = now - lastWheel >= BROWSER_SWIPE_IDLE_MS
  lastWheel = now
  if (startsGesture || now - lastRefresh >= 200) refreshState()
}, { capture: true, passive: true })
async function listen(): Promise<void> {
  while (true) {
    const action = await waitForSwipe(() => state, parentPolicy.checkParents)
    ipcRenderer.send('browser-gesture:navigate', action)
  }
}
window.addEventListener('DOMContentLoaded', () => { refreshState(); void listen() }, { once: true })
