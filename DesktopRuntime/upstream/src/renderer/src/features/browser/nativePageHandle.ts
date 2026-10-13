import { invoke, onPush } from '../../lib/ipc'
import type { BrowserPageAction, BrowserPageEvent, BrowserPageState } from '../../../../shared/types/browserNative'
import type { BrowserPageHandle } from './browserPageTypes'
import { registerBrowserAuthGuest, retireBrowserAuthGuest } from './browserAuthForwarding'
import { tabDragSession } from '../workspace/tabDragSession'

// Survives presentation remounts; native IDs guard recreated pages.
let ownershipRevision = 0

/** A native page transport with an independent, presentation-only DOM anchor. */
export function attachNativePage(element: HTMLElement, tabId: string, isPrivate: boolean, courseId: string | null, profileId = 'default') {
  const events = new EventTarget()
  let current: BrowserPageState = { id: 0, url: '', title: '', loading: false, canGoBack: false, canGoForward: false }
  let adopted = false, disposed = false, boundsSerial = 0
  let nativeId: number | undefined
  const pendingEvents: BrowserPageEvent[] = []
  let pendingBounds: { bounds: { x: number; y: number; width: number; height: number } | null; preview: boolean; serial: number } | null = null
  let creationError: unknown
  const emit = (name: string, detail: Record<string, unknown> = {}): void => {
    events.dispatchEvent(Object.assign(new Event(name), detail))
  }
  const unsubscribe = onPush('browser:page-event', (event) => {
    if (disposed || event.tabId !== tabId) return
    if (nativeId === undefined) {
      pendingEvents.push(event)
      if (pendingEvents.length > 64) pendingEvents.shift()
      return
    }
    if (event.state.id !== nativeId || (current.stateRevision !== undefined &&
      event.state.stateRevision !== undefined && event.state.stateRevision <= current.stateRevision)) return
    current = event.state
    registerBrowserAuthGuest(tabId, nativeId, current.authDocumentId)
    emit(event.name, event.detail)
  })
  const ready = invoke('browser:createPage', { tabId, isPrivate, courseId, profileId }).then(result => {
    current = result.state
    if (disposed) return
    nativeId = current.id
    const buffered: BrowserPageEvent[] = []
    for (const event of pendingEvents) {
      if (event.state.id !== nativeId || (current.stateRevision !== undefined &&
        event.state.stateRevision !== undefined && event.state.stateRevision <= current.stateRevision)) continue
      current = event.state
      buffered.push(event)
    }
    pendingEvents.length = 0
    registerBrowserAuthGuest(tabId, nativeId, current.authDocumentId)
    adopted = result.adopted
    emit('native-ready')
    if (adopted && current.url) {
      emit('did-navigate', { url: current.url, httpResponseCode: current.httpStatus ?? 0, isSnapshot: true })
      emit('page-title-updated', { title: current.title })
      emit('dom-ready')
      if (!current.loading) emit('did-stop-loading')
    }
    // The handle already exposes the newest state when ready listeners run.
    // Events received before the create reply still deliver their details.
    for (const event of buffered) emit(event.name, event.detail)
  }).catch(error => {
    creationError = error
    if (!disposed) emit('did-fail-load', {
      errorCode: -2, errorDescription: '페이지를 열지 못했어요.', validatedURL: '', isMainFrame: true
    })
  })
  const call = async <T = void>(action: BrowserPageAction, args: unknown[] = []): Promise<T> => {
    await ready
    if (disposed) throw new Error('Browser page closed')
    if (creationError) throw creationError
    return await invoke('browser:pageAction', { tabId, action, args }) as T
  }
  const flushBounds = (): void => {
    const pending = pendingBounds
    if (!pending || tabDragSession.isHeaderPressed()) return
    void ready.then(async () => {
      if (disposed || creationError || pendingBounds !== pending || tabDragSession.isHeaderPressed()) return
      pendingBounds = null
      const { bounds, preview, serial } = pending
      const result = await invoke('browser:pageBounds', { tabId, bounds, preview })
      if (!disposed && serial === boundsSerial && result.snapshot) {
        element.style.backgroundImage = `url("${result.snapshot}")`
        element.style.backgroundSize = '100% 100%'
      }
    }).catch(() => undefined)
  }
  // Inactive-tab selection hides/shows native views before dragstart. On
  // Windows that can interrupt the pressed pointer, so retain their placement
  // until release or actual dragstart; drag previews then update normally.
  const unsubscribePress = tabDragSession.subscribe(flushBounds)
  const handle: BrowserPageHandle = {
    element,
    addEventListener: events.addEventListener.bind(events),
    removeEventListener: events.removeEventListener.bind(events),
    dispatchEvent: events.dispatchEvent.bind(events),
    getURL: () => current.url,
    getWebContentsId: () => current.id,
    canGoBack: () => current.canGoBack,
    canGoForward: () => current.canGoForward,
    isLoadingMainFrame: () => current.loading,
    loadURL: url => call('loadURL', [url]),
    executeJavaScript: (source, userGesture) => call('executeJavaScript', [source, userGesture === true]),
    printToPDF: options => call('printToPDF', [options]),
    findInPage: (text, options) => call('findInPage', [text, options]),
    goBack: () => call('goBack'),
    goForward: () => call('goForward'),
    reload: () => call('reload'),
    reloadIgnoringCache: () => call('reloadIgnoringCache'),
    stop: () => call('stop'),
    setZoomLevel: level => call('setZoomLevel', [level]),
    stopFindInPage: action => call('stopFindInPage', [action]),
    downloadURL: url => call('downloadURL', [url]),
    copy: () => call('copy'),
    cut: () => call('cut'),
    paste: () => call('paste'),
    selectAll: () => call('selectAll'),
    undo: () => call('undo'),
    redo: () => call('redo'),
    copyImageAt: (x, y) => call('copyImageAt', [x, y]),
    openDevTools: () => call('openDevTools'),
    focus: async shouldFocus => {
      await ready
      if (disposed) throw new Error('Browser page closed')
      if (creationError) throw creationError
      if (shouldFocus && !shouldFocus()) return
      await invoke('browser:pageAction', { tabId, action: 'focus', args: [] })
    }
  }
  return {
    handle,
    course: (nextCourseId: string | null) => {
      const revision = ++ownershipRevision
      return ready.then(() => {
        if (disposed || creationError) return
        return invoke('browser:setCourse', {
          tabId, courseId: nextCourseId, expectedWebContentsId: current.id, revision
        })
      })
    },
    isAdopted: () => adopted,
    bounds: (bounds: { x: number; y: number; width: number; height: number } | null, preview = false) => {
      const serial = ++boundsSerial
      if (bounds) element.style.backgroundImage = ''
      pendingBounds = { bounds, preview, serial }
      flushBounds()
    },
    dispose: () => {
      disposed = true
      pendingEvents.length = 0
      if (nativeId !== undefined) retireBrowserAuthGuest(tabId, nativeId)
      pendingBounds = null
      unsubscribePress()
      unsubscribe()
      void ready.then(() => {
        if (current.id > 0) return invoke('browser:destroyPage', { tabId, expectedWebContentsId: current.id })
      }).catch(() => undefined)
    }
  }
}
