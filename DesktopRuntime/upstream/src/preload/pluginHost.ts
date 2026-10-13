/** Fixed-channel JSON bridge for the sandboxed plugin execution renderer. */
import { contextBridge, ipcRenderer } from 'electron'

const CHANNEL = 'bandal-plugin-host:message'
const MAX_MESSAGE_BYTES = 1024 * 1024
const listeners = new Set<(json: string) => void>()
let windowStartedAt = Date.now()
let messagesInWindow = 0
let stopped = false

ipcRenderer.on(CHANNEL, (_event, json: unknown) => {
  if (typeof json !== 'string') return
  for (const listener of listeners) listener(json)
})

contextBridge.exposeInMainWorld('__bandalHost', Object.freeze({
  post(json: unknown) {
    // Accept primitives only. Neither Electron event objects nor Node objects
    // ever cross the bridge into plugin code, including errors and promises.
    if (stopped || typeof json !== 'string' || Buffer.byteLength(json, 'utf8') > MAX_MESSAGE_BYTES) return
    if (Date.now() - windowStartedAt >= 1_000) { windowStartedAt = Date.now(); messagesInWindow = 0 }
    if (++messagesInWindow > 200) {
      stopped = true
      ipcRenderer.send(CHANNEL, JSON.stringify({ t: 'sandboxError', error: 'Plugin exceeded the transport message budget' }))
      return
    }
    ipcRenderer.send(CHANNEL, json)
  },
  subscribe(listener: unknown) {
    if (typeof listener === 'function' && listeners.size === 0) listeners.add(listener as (json: string) => void)
  }
}))
