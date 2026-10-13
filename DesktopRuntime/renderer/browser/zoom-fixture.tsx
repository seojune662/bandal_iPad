import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserGuestView } from '../../upstream/src/renderer/src/features/browser/BrowserGuestView'
import { useBrowserGuests } from '../../upstream/src/renderer/src/features/browser/browserGuestsStore'
import { setIpcAdapter, type IpcAdapter } from '../../upstream/src/renderer/src/lib/ipc'
import { ensureSettingsLoaded } from '../../upstream/src/renderer/src/stores/settingsSnapshot'
import { DEFAULT_SETTINGS } from '../../upstream/src/shared/types/settings'
import { guestActions } from '../../upstream/src/renderer/src/features/browser/guestActions'
import { ToastHost } from '../../upstream/src/renderer/src/app/toast'
import type { BrowserPageState } from '../../upstream/src/shared/types/browserNative'

const calls: Array<{ channel: string; request: Record<string, unknown> }> = []
const listeners = new Map<string, Set<(value: unknown) => void>>()
const native = new Map<string, BrowserPageState>()
const failZoom = new Set<string>()
const deferZoom = new Set<string>(), rejectZoom = new Map<string, (error: Error) => void>()
let settings = { ...DEFAULT_SETTINGS, browser: { ...DEFAULT_SETTINGS.browser,
  defaultZoomLevel: Number(localStorage.getItem('default-zoom') ?? 1.22) } }
const publish = (channel: string, value: unknown): void => { listeners.get(channel)?.forEach(listener => listener(value)) }
const api = {
  async invoke(channel: string, raw: unknown = {}): Promise<unknown> {
    const request = raw as Record<string, unknown>
    calls.push({ channel, request: structuredClone(request) })
    if (channel === 'settings:get') return settings
    if (channel === 'settings:set') {
      settings = { ...settings, browser: { ...settings.browser, ...(request.browser as Partial<typeof settings.browser>) } }
      localStorage.setItem('default-zoom', String(settings.browser.defaultZoomLevel))
      publish('settings:changed', { settings }); return settings
    }
    if (channel === 'browser:createPage') {
      const tabId = String(request.tabId), state = { id: native.size+1, url: 'about:blank', title: 'Fixture', loading: false, canGoBack: false, canGoForward: false, stateRevision: 1 }
      native.set(tabId, state); return { state, adopted: false }
    }
    if (channel === 'browser:courseForUrl') return { courseId: null }
    if (channel === 'browser:pageBounds') return { snapshot: null }
    if (channel === 'browser:pageAction' && request.action === 'setZoomLevel' && deferZoom.delete(String(request.tabId))) return await new Promise((_resolve, reject) => rejectZoom.set(String(request.tabId), reject))
    if (channel === 'browser:pageAction' && request.action === 'setZoomLevel' && failZoom.delete(String(request.tabId))) throw new Error('Fixture: native zoom failed')
    return { ok: true }
  },
  on(channel: string, listener: (value: unknown) => void): () => void {
    if (!listeners.has(channel)) listeners.set(channel, new Set())
    listeners.get(channel)!.add(listener)
    return () => { listeners.get(channel)?.delete(listener) }
  }
}
Object.assign(window, { bandal: { ...api, platform: 'ipad', browserAuthProbe: 'clean' } })
setIpcAdapter(api as IpcAdapter)
const exposed = { calls, add: (_id: string) => {}, remove: (_id: string) => {},
  failOnce: (id: string): void => { failZoom.add(id) },
  deferOnce: (id: string): void => { deferZoom.add(id) },
  rejectDeferred: (id: string): void => { rejectZoom.get(id)?.(new Error('Fixture: stale default response')); rejectZoom.delete(id) },
  settings: (level: number) => api.invoke('settings:set', { browser: { defaultZoomLevel: level } }),
  zoom: (id: string, level: number): void => { useBrowserGuests.getState().setZoom(id, level); guestActions.setZoom(id, level) },
  navigate: (id: string): void => {
    const old = native.get(id)!
    const state = { ...old, stateRevision: (old.stateRevision ?? 0)+1 }
    native.set(id, state); publish('browser:page-event', { tabId: id, name: 'dom-ready', state, detail: {} })
  }, levels: () => useBrowserGuests.getState().zoom }
Object.assign(window, { zoomFixture: exposed })
function Fixture(): JSX.Element {
  const [tabs, setTabs] = useState(['first'])
  exposed.add = id => setTabs(current => [...current, id])
  exposed.remove = id => setTabs(current => current.filter(tab => tab !== id))
  return <><ToastHost />{tabs.map(tab => <BrowserGuestView key={tab} tabId={tab} src="about:blank" isPrivate={tab.startsWith('private')}
    profileId="default" suppressed={false} occlusions={[]} />)}</>
}
await ensureSettingsLoaded()
createRoot(document.getElementById('root')!).render(<Fixture />)
