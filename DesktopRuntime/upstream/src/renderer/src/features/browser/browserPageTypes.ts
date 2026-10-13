/**
 * Explicit asynchronous transport for a page owned by main.
 * EventTarget carries browser events; element is only its DOM position anchor.
 */

export interface BrowserPageHandle extends EventTarget {
  /** Position/snapshot anchor only. No browser API is attached to the DOM. */
  readonly element: HTMLElement
  loadURL(url: string): Promise<void>
  getURL(): string
  goBack(): Promise<void>
  goForward(): Promise<void>
  reload(): Promise<void>
  reloadIgnoringCache(): Promise<void>
  stop(): Promise<void>
  /** Reapply the stored zoom after navigation creates a new page context. */
  setZoomLevel(level: number): Promise<void>
  /**
   * Resolves the Chromium request id; matches arrive later as a page
   * `found-in-page` event. Call with NO options to start a fresh search and
   * `{ findNext: true, forward }` to step — an explicit `{ findNext: false }`
   * silently emits no event at all (measured).
   */
  findInPage(text: string, options?: FindInPageOptions): Promise<number>
  /** Must be called when the bar closes or the highlight stays forever. */
  stopFindInPage(action: 'clearSelection' | 'keepSelection' | 'activateSelection'): Promise<void>
  canGoBack(): boolean
  isLoadingMainFrame(): boolean
  canGoForward(): boolean
  getWebContentsId(): number
  executeJavaScript(code: string, userGesture?: boolean): Promise<unknown>
  /** Same `will-download` path a real click takes — cookies, redirects, name. */
  downloadURL(url: string): Promise<void>
  focus(shouldFocus?: () => boolean): Promise<void>
  copy(): Promise<void>
  cut(): Promise<void>
  paste(): Promise<void>
  selectAll(): Promise<void>
  undo(): Promise<void>
  redo(): Promise<void>
  copyImageAt(x: number, y: number): Promise<void>
  /**
   * The only way to find out why a site is broken from inside a release
   * build. `browserAgent/cdp.ts` already expects a student to have DevTools
   * attached and yields the debugger to them, so nothing else has to change.
   */
  openDevTools(): Promise<void>
  /** Resolves with the page rendered to PDF bytes. */
  printToPDF(options: Record<string, unknown>): Promise<Uint8Array>
}

export interface DidNavigateEvent extends Event {
  httpResponseCode?: number
  /** Existing document state replayed when a native page gains a renderer. */
  isSnapshot?: boolean
  url: string
}

export interface DidNavigateInPageEvent extends Event {
  url: string
  isMainFrame: boolean
}

export interface PageTitleUpdatedEvent extends Event {
  title: string
}

/** `did-fail-load`. Subframe failures also arrive here — check `isMainFrame`. */
export interface DidFailLoadEvent extends Event {
  errorCode: number
  errorDescription: string
  validatedURL: string
  isMainFrame: boolean
}

export interface FindInPageOptions {
  forward?: boolean
  findNext?: boolean
  matchCase?: boolean
}

export interface FoundInPageEvent extends Event {
  result: {
    requestId: number
    activeMatchOrdinal: number
    matches: number
    finalUpdate: boolean
  }
}

/**
 * `context-menu`. Coordinates are GUEST-viewport relative, so a host-rendered
 * menu has to offset them by the webview element's bounding rect.
 */
export interface ContextMenuEvent extends Event {
  params: {
    x: number
    y: number
    linkURL: string
    srcURL: string
    mediaType: 'none' | 'image' | 'audio' | 'video' | 'canvas' | 'file' | 'plugin'
    selectionText: string
    isEditable: boolean
    pageURL: string
  }
}

/** `page-favicon-updated`. Chromium reports every declared icon, best last. */
export interface PageFaviconUpdatedEvent extends Event {
  favicons: string[]
}
