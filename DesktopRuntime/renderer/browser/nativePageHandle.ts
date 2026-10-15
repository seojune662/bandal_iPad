import { invoke, onPush } from '../../upstream/src/renderer/src/lib/ipc'
import type { BrowserPageAction, BrowserPageEvent, BrowserPageState } from '../../upstream/src/shared/types/browserNative'
import type { BrowserPageHandle } from '../../upstream/src/renderer/src/features/browser/browserPageTypes'
import { registerBrowserAuthGuest, retireBrowserAuthGuest } from '../../upstream/src/renderer/src/features/browser/browserAuthForwarding'
import { tabDragSession } from '../../upstream/src/renderer/src/features/workspace/tabDragSession'

import { ignoredRecoveryFailure, recoveryRequest, registerRecoveryHandle, type RecoveryFailure, type RecoveryNavState } from './recoverySupport'

// Survives presentation remounts; native IDs guard recreated pages.
let ownershipRevision = 0

/** A native page transport with an independent, presentation-only DOM anchor. */
export function attachNativePage(element: HTMLElement, tabId: string, isPrivate: boolean, courseId: string | null, profileId = 'default') {
  const events = new EventTarget()
  let current: BrowserPageState & RecoveryNavState = { id: 0, url: '', title: '', loading: false, canGoBack: false, canGoForward: false }
  let adopted = false, disposed = false, boundsSerial = 0
  let nativeId: number | undefined
  const pendingEvents: BrowserPageEvent[] = []
  type Placement = { bounds: { x: number; y: number; width: number; height: number } | null; preview: boolean; serial: number }
  let pendingBounds: Placement | null = null
  let creationError: unknown
  let generation = 0
  let desiredCourse = courseId
  let creationInFlight = false
  let initialURLOverride: string | undefined
  // Renderer intent changes immediately, before asynchronous native state arrives.
  let navigationIntentRevision = 0
  let initialNavigationSuppressed = false
  let ready: Promise<void>
  let lastPlacement: Placement | null = null
  const acceptEvent = (event: BrowserPageEvent): boolean => {
    const state = event.state as BrowserPageState & RecoveryNavState
    if (state.id !== nativeId || (current.stateRevision !== undefined &&
      state.stateRevision !== undefined && state.stateRevision <= current.stateRevision)) return false
    if (state.navigationId !== undefined && current.navigationId !== undefined && state.navigationId < current.navigationId) return false
    if (event.name === 'did-fail-load' && ignoredRecoveryFailure(event.detail as unknown as RecoveryFailure, current.navigationId)) return false
    return true
  }
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
    if (!acceptEvent(event)) return
    current = event.state
    registerBrowserAuthGuest(tabId, nativeId, current.authDocumentId)
    emit('browser-state-changed', { ...current })
    emit(event.name, event.detail)
  })
  const create = (): Promise<void> => {
    if (creationInFlight) return ready
    creationInFlight = true
    creationError = undefined
    const attempt = ++generation
    ready = invoke('browser:createPage', { tabId, isPrivate, courseId: desiredCourse, profileId }).then(result => {
      if (disposed || attempt !== generation) {
        void invoke('browser:destroyPage', { tabId, expectedWebContentsId: result.state.id }).catch(() => undefined)
        return
      }
      current = result.state
      nativeId = current.id
      const buffered: BrowserPageEvent[] = []
      for (const event of pendingEvents) {
        if (!acceptEvent(event)) continue
        current = event.state
        buffered.push(event)
      }
      pendingEvents.length = 0
      registerBrowserAuthGuest(tabId, nativeId, current.authDocumentId)
      adopted = result.adopted
      // Restore presentation and the latest owner, including changes made while
      // initialization was unavailable. native-ready starts the first URL load.
      pendingBounds = lastPlacement
      flushBounds()
      void invoke('browser:setCourse', {
        tabId, courseId: desiredCourse, expectedWebContentsId: current.id, revision: ++ownershipRevision
      }).catch(() => undefined)
      emit('browser-state-changed', { ...current })
      emit('native-ready', { ...(initialURLOverride === undefined ? {} : { initialURLOverride }), initialNavigationSuppressed })
      initialURLOverride = undefined
      if (adopted && current.url) {
        emit('did-navigate', { url: current.url, httpResponseCode: current.httpStatus ?? 0, isSnapshot: true })
        emit('page-title-updated', { title: current.title })
        emit('dom-ready')
        if (!current.loading) emit('did-stop-loading')
      }
      // A failure that raced the creation reply must retain its actual target.
      for (const event of buffered) emit(event.name, event.detail)
    }).catch(error => {
      if (disposed || attempt !== generation) return
      creationError = error
      pendingEvents.length = 0
      emit('did-fail-load', {
        errorKind: 'initialization', retryable: true, requestMethod: 'GET',
        errorCode: -2, errorDescription: '브라우저를 준비하지 못했어요.', validatedURL: '', isMainFrame: true
      })
    }).finally(() => { if (attempt === generation) creationInFlight = false })
    return ready
  }
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
  ready = create()
  const reload = async (ignoreCache: boolean): Promise<void> => {
    ++navigationIntentRevision
    initialNavigationSuppressed = false
    if (nativeId === undefined) {
      await create()
      if (creationError) throw creationError
      return // native-ready owns the initial navigation, exactly once.
    }
    await call(ignoreCache ? 'reloadIgnoringCache' : 'reload')
  }
  const unregisterRecovery = registerRecoveryHandle(tabId, {
    reload: () => reload(false),
    retry: async (navigationId, url, initialization) => {
      if (disposed) throw new Error('Browser page closed')
      ++navigationIntentRevision
      if (nativeId === undefined) { await reload(false); return }
      if (initialization) { await call('loadURL', [url]); return }
      if (navigationId === undefined) throw new Error('페이지 정보를 확인하지 못했어요. 주소를 다시 입력해 주세요.')
      await ready
      if (disposed || creationError) throw new Error('페이지를 찾을 수 없어요.')
      await recoveryRequest('browser:retryNavigation', { tabId, navigationId })
    },
    returnToForm: async navigationId => {
      ++navigationIntentRevision
      await ready
      if (disposed || creationError) throw new Error('페이지를 찾을 수 없어요.')
      await recoveryRequest('browser:returnToForm', { tabId, navigationId })
    }
  })
  const handle: BrowserPageHandle & { getNavigationIntentRevision: () => number } = {
    element,
    addEventListener: events.addEventListener.bind(events),
    removeEventListener: events.removeEventListener.bind(events),
    dispatchEvent: events.dispatchEvent.bind(events),
    getURL: () => current.url,
    getNavigationIntentRevision: () => navigationIntentRevision,
    getWebContentsId: () => current.id,
    canGoBack: () => current.canGoBack,
    canGoForward: () => current.canGoForward,
    isLoadingMainFrame: () => current.loading,
    loadURL: async url => {
      ++navigationIntentRevision
      initialNavigationSuppressed = false
      if (nativeId === undefined) {
        if (disposed) throw new Error('Browser page closed')
        initialURLOverride = url
        await create()
        if (creationError) throw creationError
        return // The successful native-ready listener loads the latest address.
      }
      await call('loadURL', [url])
    },
    executeJavaScript: (source, userGesture) => call('executeJavaScript', [source, userGesture === true]),
    printToPDF: options => call('printToPDF', [options]),
    findInPage: (text, options) => call('findInPage', [text, options]),
    goBack: () => { ++navigationIntentRevision; return call('goBack') },
    goForward: () => { ++navigationIntentRevision; return call('goForward') },
    reload: () => reload(false),
    reloadIgnoringCache: () => reload(true),
    stop: () => { ++navigationIntentRevision; initialNavigationSuppressed = true; return call('stop') },
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
      desiredCourse = nextCourseId
      const attempt = generation
      const revision = ++ownershipRevision
      return ready.then(() => {
        if (disposed || creationError || attempt !== generation) return
        return invoke('browser:setCourse', {
          tabId, courseId: nextCourseId, expectedWebContentsId: current.id, revision
        })
      })
    },
    isAdopted: () => adopted,
    bounds: (bounds: { x: number; y: number; width: number; height: number } | null, preview = false) => {
      const serial = ++boundsSerial
      if (bounds) element.style.backgroundImage = ''
      lastPlacement = pendingBounds = { bounds, preview, serial }
      flushBounds()
    },
    dispose: () => {
      disposed = true
      ++generation
      unregisterRecovery()
      pendingEvents.length = 0
      if (nativeId !== undefined) retireBrowserAuthGuest(tabId, nativeId)
      lastPlacement = pendingBounds = null
      unsubscribePress()
      unsubscribe()
      if (nativeId !== undefined) void invoke('browser:destroyPage', { tabId, expectedWebContentsId: nativeId }).catch(() => undefined)
    }
  }
}
