import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserGuestView } from '../../upstream/src/renderer/src/features/browser/BrowserGuestView'
import { BrowserErrorPage, BrowserCrashPage } from '../../upstream/src/renderer/src/features/browser/BrowserErrorPage'
import { useBrowserGuests } from '../../upstream/src/renderer/src/features/browser/browserGuestsStore'
import { setIpcAdapter, type IpcAdapter } from '../../upstream/src/renderer/src/lib/ipc'
import { ensureSettingsLoaded } from '../../upstream/src/renderer/src/stores/settingsSnapshot'
import { DEFAULT_SETTINGS } from '../../upstream/src/shared/types/settings'
import type { BrowserPageState } from '../../upstream/src/shared/types/browserNative'
import type { RecoveryNavState } from './recoverySupport'
import { attachNativePage } from './nativePageHandle'
import { guestActions } from '../../upstream/src/renderer/src/features/browser/guestActions'

const calls: Array<{ channel: string; request: Record<string, unknown> }> = []
const listeners = new Map<string, Set<(value: unknown) => void>>()
const native = new Map<string, BrowserPageState & RecoveryNavState>()
const failCreate = new Set<string>(), rejectRetry = new Set<string>(), rejectReload = new Set<string>()
const deferredCreate = new Set<string>(), resolveCreate = new Map<string, () => void>()
const deferredCourse = new Set<string>(), resolveCourse = new Map<string, () => void>()
const deferredLoad = new Set<string>(), queuedLoad = new Map<string, string>()
let nativeSequence = 0
const publish = (channel: string, value: unknown): void => { listeners.get(channel)?.forEach(listener => listener(value)) }
function event(id: string, name: string, detail: Record<string, unknown> = {}, patch: Partial<BrowserPageState & RecoveryNavState> = {}): void {
  const old = native.get(id)!
  const state = { ...old, ...patch, stateRevision: (old.stateRevision ?? 0) + 1 }
  native.set(id, state)
  publish('browser:page-event', { tabId: id, name, state, detail })
}
function start(id: string, url: string, navigationId?: number): void {
  event(id, 'did-start-loading', {}, { url, loading: true, estimatedProgress: 0.1, navigationId: navigationId ?? (native.get(id)?.navigationId ?? 0) + 1 })
}
const api = {
  async invoke(channel: string, raw: unknown = {}): Promise<unknown> {
    const request = raw as Record<string, unknown>, id = String(request.tabId)
    calls.push({ channel, request: structuredClone(request) })
    if (channel === 'settings:get') return DEFAULT_SETTINGS
    if (channel === 'browser:createPage') {
      if (deferredCreate.delete(id)) await new Promise<void>(resolve => resolveCreate.set(id, resolve))
      if (failCreate.delete(id)) throw new Error('Fixture: initialization failed')
      const state = { id: ++nativeSequence, url: 'about:blank', title: 'Fixture', loading: false, canGoBack: false, canGoForward: false, stateRevision: 1, navigationId: 0, estimatedProgress: 0 }
      native.set(id, state); return { state, adopted: false }
    }
    if (channel === 'browser:courseForUrl') {
      if (deferredCourse.delete(String(request.url))) await new Promise<void>(resolve => resolveCourse.set(String(request.url), resolve))
      return { courseId: null }
    }
    if (channel === 'browser:pageBounds') return { snapshot: null }
    if (channel === 'browser:retryNavigation') {
      if (rejectRetry.delete(id)) throw new Error('연결을 시작하지 못했어요.')
      if (request.navigationId !== native.get(id)?.navigationId) throw new Error('이미 다른 페이지로 이동했어요.')
    }
    if (channel === 'browser:returnToForm') event(id, 'navigation-recovered', {}, { url: 'https://a.test/form', loading: false })
    if (channel === 'browser:pageAction' && request.action === 'loadURL') {
      const url = String((request.args as unknown[])[0])
      if (deferredLoad.has(id)) queuedLoad.set(id, url)
      else start(id, url)
    }
    if (channel === 'browser:pageAction' && request.action === 'reload' && rejectReload.delete(id)) throw new Error('페이지를 다시 불러오지 못했어요.')
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
const direct = new Map<string, ReturnType<typeof attachNativePage>>()
const exposed = {
  directCreate: (id: string) => {
    const anchor = document.createElement('div')
    document.body.append(anchor)
    const handle = attachNativePage(anchor, id, false, 'original-course')
    handle.bounds({ x: 10, y: 20, width: 600, height: 800 })
    direct.set(id, handle)
  },
  directCourse: (id: string, course: string) => direct.get(id)?.course(course),
  directReload: (id: string) => direct.get(id)?.handle.reload(),
  directDispose: (id: string) => direct.get(id)?.dispose(),
  calls, add: (_id: string) => {}, remove: (_id: string) => {},
  deferLoad: (id: string) => deferredLoad.add(id),
  finishLoad: (id: string) => { deferredLoad.delete(id); const url = queuedLoad.get(id); if (url) start(id, url) },
  deferCourse: (id: string) => deferredCourse.add(`https://${id}.test/first`),
  finishCourse: (id: string) => resolveCourse.get(`https://${id}.test/first`)?.(),
  failCreate: (id: string) => failCreate.add(id), deferCreate: (id: string) => deferredCreate.add(id),
  finishCreate: (id: string) => resolveCreate.get(id)?.(),
  rejectRetry: (id: string) => rejectRetry.add(id), rejectReload: (id: string) => rejectReload.add(id),
  start, event, reload: guestActions.reload, navigate: guestActions.navigate, stop: guestActions.stop,
  nav: (id: string) => useBrowserGuests.getState().nav[id],
  overlay: (id: string) => useBrowserGuests.getState().overlay[id],
  addressFocus: (id: string) => useBrowserGuests.getState().addressFocusSeq[id],
  course: (id: string, courseId: string) => useBrowserGuests.getState().setGuestCourse(id, courseId),
  fail: (id: string, url: string, detail: Record<string, unknown> = {}) => event(id, 'did-fail-load', {
    isMainFrame: true, errorKind: 'offline', errorDomain: 'NSURLErrorDomain', errorCode: -1009,
    errorDescription: '인터넷 연결이 끊겼습니다.', validatedURL: url,
    navigationId: native.get(id)?.navigationId, retryable: true, requestMethod: 'GET', ...detail
  }, { loading: false }),
  commit: (id: string, url: string) => {
    event(id, 'did-navigate', { url }, { url, loading: false, estimatedProgress: 1, canGoBack: true })
    event(id, 'did-stop-loading')
  }
}
Object.assign(window, { recoveryFixture: exposed })
function Tab({ id }: { id: string }): JSX.Element {
  const overlay = useBrowserGuests(state => state.overlay[id])
  return <section data-recovery-tab={id}>
    <BrowserGuestView tabId={id} src={`https://${id}.test/first`} isPrivate={false} profileId="default" suppressed={false} occlusions={[]} />
    {overlay?.kind === 'error' && <BrowserErrorPage tabId={id} overlay={overlay} />}
    {overlay?.kind === 'crashed' && <BrowserCrashPage tabId={id} overlay={overlay} />}
  </section>
}
function Fixture(): JSX.Element {
  const [tabs, setTabs] = useState<string[]>([])
  exposed.add = id => { useBrowserGuests.getState().ensureGuest(id, `https://${id}.test/first`); setTabs(current => [...current, id]) }
  exposed.remove = id => setTabs(current => current.filter(tab => tab !== id))
  return <>{tabs.map(id => <Tab key={id} id={id} />)}</>
}
await ensureSettingsLoaded()
createRoot(document.getElementById('root')!).render(<Fixture />)
