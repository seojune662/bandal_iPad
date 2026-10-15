import { fileURLToPath } from 'node:url'
const nativeHandle = fileURLToPath(new URL('./nativePageHandle.ts', import.meta.url))
const recoveryPage = fileURLToPath(new URL('./BrowserRecoveryPage.tsx', import.meta.url))
const support = fileURLToPath(new URL('./recoverySupport.ts', import.meta.url))
function replace(source, needle, replacement) {
  if (source.split(needle).length !== 2) throw new Error(`iPad browser recovery anchor changed: ${needle}`)
  return source.replace(needle, replacement)
}
export function adaptBrowserRecoverySource(source, id) {
  let code = source
  if (id.endsWith('/features/browser/nativePageHandle.ts')) return { code: `export { attachNativePage } from ${JSON.stringify(nativeHandle)}`, map: null }
  if (id.endsWith('/features/browser/BrowserErrorPage.tsx')) return { code: `export { BrowserErrorPage, BrowserCrashPage } from ${JSON.stringify(recoveryPage)}`, map: null }
  if (id.endsWith('/features/browser/browserGuestsStore.ts')) {
    code = replace(code, 'export interface BrowserNavState {', 'export interface BrowserNavState {\n  navigationId?: number\n  estimatedProgress?: number')
  }
  if (id.endsWith('/features/browser/loadError.ts')) {
    code = `import type { RecoveryMetadata } from ${JSON.stringify(support)}\n` + code
    code = replace(code, 'export interface BrowserLoadErrorOverlay {', 'export interface BrowserLoadErrorOverlay extends RecoveryMetadata {')
  }
  if (id.endsWith('/features/browser/browserPageTypes.ts')) {
    code = `import type { RecoveryMetadata } from ${JSON.stringify(support)}\n` + code
    code = replace(code, 'export interface BrowserPageHandle extends EventTarget {', 'export interface BrowserPageHandle extends EventTarget {\n  getNavigationIntentRevision?(): number')
    code = replace(code, 'export interface DidFailLoadEvent extends Event {', 'export interface DidFailLoadEvent extends Event, RecoveryMetadata {')
  }
  if (id.endsWith('/features/browser/BrowserGuestView.tsx')) {
    code = replace(code, "import { ABORTED_ERROR_CODE } from './loadError'", `import { ignoredRecoveryFailure, type RecoveryNavState } from ${JSON.stringify(support)}`)
    code = replace(code, '    let initialNavigationStarted = false', '    let initialNavigationStarted = false\n    let latestNavigationId: number | undefined')
    code = replace(code, '    const listeners: ReadonlyArray<[string, EventListener]> = [', `    const listeners: ReadonlyArray<[string, EventListener]> = [
      ['browser-state-changed', ((event: Event & RecoveryNavState) => {
        if (event.navigationId !== undefined) latestNavigationId = event.navigationId
        update({ ...(event.navigationId === undefined ? {} : { navigationId: event.navigationId }),
          ...(event.estimatedProgress === undefined ? {} : { estimatedProgress: event.estimatedProgress }) })
      }) as EventListener],
      ['navigation-recovered', () => {
        useBrowserGuests.getState().setOverlay(tabId, null)
        update({ url: element.getURL(), loading: element.isLoadingMainFrame(), ...historyState() })
      }],`)
    code = replace(code, '          update({ loading: false, ...historyState() })', `          const stoppedURL = element.getURL()
          update({ loading: false, ...historyState(), ...(stoppedURL && stoppedURL !== 'about:blank' ? { url: stoppedURL } : {}) })`)
    code = replace(code, '          update({ loading: true, httpStatus: 0 })', "          update({ loading: true, httpStatus: 0, ...(element.getURL() && element.getURL() !== 'about:blank' ? { url: element.getURL() } : {}) })")
    code = replace(code, `          if (!shouldHandleLoadFailure(event.isMainFrame)) return
          update({ loading: false })
          if (event.errorCode === ABORTED_ERROR_CODE) return`, `          if (!shouldHandleLoadFailure(event.isMainFrame) || ignoredRecoveryFailure(event, latestNavigationId)) return
          const failedURL = event.validatedURL || useBrowserGuests.getState().nav[tabId]?.url || src
          update({ loading: false, url: failedURL, ...historyState() })`)
    code = replace(code, '            url: event.validatedURL', `            url: failedURL,
            ...(event.errorKind === undefined ? {} : { errorKind: event.errorKind }),
            ...(event.errorDomain === undefined ? {} : { errorDomain: event.errorDomain }),
            ...(event.navigationId === undefined ? {} : { navigationId: event.navigationId }),
            ...(event.requestMethod === undefined ? {} : { requestMethod: event.requestMethod }),
            ...(event.retryable === undefined ? {} : { retryable: event.retryable }),
            ...(event.canReturnToForm === undefined ? {} : { canReturnToForm: event.canReturnToForm })`)
    code = replace(code, `        'native-ready',
        () => {`, `        'native-ready',
        (readyEvent) => {`)
    code = replace(code, '          if (!initialNavigationStarted && !nativeRef.current?.isAdopted()) {', '          if (!initialNavigationStarted && !nativeRef.current?.isAdopted() && !(readyEvent as Event & { initialNavigationSuppressed?: boolean }).initialNavigationSuppressed) {')
    code = replace(code, '            initialNavigationStarted = true', `            initialNavigationStarted = true
            const initialURL = (readyEvent as Event & { initialURLOverride?: string }).initialURLOverride ?? src
            const initialId = latestNavigationId
            let initialIntent = element.getNavigationIntentRevision?.()
            const initialNativeId = element.getWebContentsId()
            const initialIsCurrent = (): boolean => !disposed && latestNavigationId === initialId && element.getNavigationIntentRevision?.() === initialIntent && element.getWebContentsId() === initialNativeId`)
    code = replace(code, "invoke('browser:courseForUrl', { url: src })", "invoke('browser:courseForUrl', { url: initialURL })")
    code = replace(code, '              if (disposed) return', '              if (!initialIsCurrent()) return')
    code = replace(code, "              if (!disposed) await element.loadURL(src).catch(() => undefined)", `              if (initialIsCurrent()) {
                const loading = element.loadURL(initialURL)
                initialIntent = element.getNavigationIntentRevision?.()
                await loading
              }`)
    code = replace(code, "errorDescription: '페이지를 열지 못했어요.', url: src", "errorDescription: '페이지를 열지 못했어요.', url: initialURL")
    code = replace(code, "              if (!disposed) useBrowserGuests.getState().setOverlay(tabId, {\n                kind: 'error', errorCode: -2,", "              if (!initialIsCurrent()) return\n              initialNavigationStarted = false\n              if (!useBrowserGuests.getState().overlay[tabId]) useBrowserGuests.getState().setOverlay(tabId, {\n                kind: 'error', errorKind: 'initialization', retryable: true, requestMethod: 'GET', errorCode: -2,")
  }
  if (id.endsWith('/features/browser/BrowserWebviewLayer.tsx')) {
    code = replace(code, "      if (outcome !== 'no-handler') return\n      showToast('이 프로그램이 설치되어 있지 않아요.')", "      if (outcome === 'blocked') showToast('이 앱 연결은 허용되지 않아 열 수 없어요.')\n      else if (outcome === 'no-handler') showToast('이 프로그램이 설치되어 있지 않아요.')")
  }
  return code === source ? null : { code, map: null }
}
