import { useEffect, type RefObject } from 'react'
import type { BrowserPageHandle } from './browserPageTypes'

const CONSOLE_PREFIX = '__bandal_sel__'
export const BROWSER_SELECTION_EVENT = 'bandal:browser-selection'
let selectionOwner: BrowserPageHandle | null = null

export interface BrowserSelectionRect {
  left: number
  top: number
  width: number
  height: number
}

export interface BrowserSelectionDetail {
  text: string
  rect: BrowserSelectionRect
  title: string
  url: string
}

interface GuestSelectionPayload {
  text: string
  rect: BrowserSelectionRect | null
  title: string
  url: string
}

interface SelectionWebview extends BrowserPageHandle {
  executeJavaScript(code: string, userGesture?: boolean): Promise<unknown>
}

interface WebviewConsoleMessageEvent extends Event {
  message: string
}

const REPORTER_SOURCE = `(() => {
  if (window.__bandalSelectionReporterInstalledV1__ === true) return;
  Object.defineProperty(window, '__bandalSelectionReporterInstalledV1__', {
    value: true,
    configurable: false,
    enumerable: false,
    writable: false
  });
  const prefix = ${JSON.stringify(CONSOLE_PREFIX)};
  let timer = 0;
  const emit = () => {
    timer = 0;
    const selection = window.getSelection();
    const text = selection && !selection.isCollapsed ? selection.toString().trim() : '';
    let rect = null;
    if (text && selection && selection.rangeCount > 0) {
      const range = selection.getRangeAt(0);
      const rects = Array.from(range.getClientRects()).filter(
        (item) => item.width > 0 || item.height > 0
      );
      const end = rects.length > 0 ? rects[rects.length - 1] : range.getBoundingClientRect();
      if (Number.isFinite(end.left) && Number.isFinite(end.top)) {
        rect = { left: end.left, top: end.top, width: end.width, height: end.height };
      }
    }
    console.log(prefix + JSON.stringify({
      text,
      rect,
      title: document.title || '',
      url: location.href
    }));
  };
  const schedule = () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(emit, 120);
  };
  document.addEventListener('selectionchange', schedule, true);
  document.addEventListener('mouseup', schedule, true);
  document.addEventListener('keyup', (event) => {
    if (event.key !== 'Escape') schedule();
  }, true);
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    window.clearTimeout(timer);
    console.log(prefix + JSON.stringify({
      text: '', rect: null, title: document.title || '', url: location.href
    }));
  }, true);
  window.addEventListener('scroll', () => {
    window.clearTimeout(timer);
    console.log(prefix + JSON.stringify({
      text: '', rect: null, title: document.title || '', url: location.href
    }));
  }, true);
})();`

function finiteRect(value: unknown): value is BrowserSelectionRect {
  if (typeof value !== 'object' || value === null) return false
  const rect = value as BrowserSelectionRect
  return (
    Number.isFinite(rect.left) &&
    Number.isFinite(rect.top) &&
    Number.isFinite(rect.width) &&
    Number.isFinite(rect.height) &&
    rect.width >= 0 &&
    rect.height >= 0
  )
}

function parsePayload(message: string): GuestSelectionPayload | null {
  if (!message.startsWith(CONSOLE_PREFIX)) return null
  try {
    const parsed: unknown = JSON.parse(message.slice(CONSOLE_PREFIX.length))
    if (typeof parsed !== 'object' || parsed === null) return null
    const candidate = parsed as Record<string, unknown>
    if (
      typeof candidate['text'] !== 'string' ||
      typeof candidate['title'] !== 'string' ||
      typeof candidate['url'] !== 'string' ||
      candidate['text'].length > 100_000 ||
      candidate['title'].length > 10_000 ||
      candidate['url'].length > 20_000 ||
      (candidate['rect'] !== null && !finiteRect(candidate['rect']))
    ) {
      return null
    }
    return {
      text: candidate['text'],
      rect: candidate['rect'] as BrowserSelectionRect | null,
      title: candidate['title'],
      url: candidate['url']
    }
  } catch {
    return null
  }
}

function announce(
  source: BrowserPageHandle,
  detail: BrowserSelectionDetail | null
): void {
  if (detail === null) {
    if (selectionOwner !== source) return
    selectionOwner = null
  } else {
    selectionOwner = source
  }
  window.dispatchEvent(
    new CustomEvent<BrowserSelectionDetail | null>(BROWSER_SELECTION_EVENT, {
      detail
    })
  )
}

/**
 * Injects a console-only reporter after each guest navigation. No preload,
 * Electron API, Node integration, or sandbox relaxation is involved.
 */
export function useBrowserSelectionBridge(
  webviewRef: RefObject<BrowserPageHandle | null>
): void {
  useEffect(() => {
    const webview = webviewRef.current as SelectionWebview | null
    if (webview === null) return

    const inject = (): void => {
      try {
        void webview.executeJavaScript(REPORTER_SOURCE).catch(() => {
          // Pages can disappear between dom-ready and injection; navigation
          // supplies another dom-ready, so this is intentionally silent.
        })
      } catch {
        // The guest is not attached yet; dom-ready will retry.
      }
    }
    const onConsoleMessage = (rawEvent: Event): void => {
      const event = rawEvent as WebviewConsoleMessageEvent
      if (typeof event.message !== 'string') return
      const payload = parsePayload(event.message)
      if (payload === null) return
      if (payload.text === '' || payload.rect === null) {
        announce(webview, null)
        return
      }
      const guestRect = webview.element.getBoundingClientRect()
      announce(webview, {
        text: payload.text,
        rect: {
          left: guestRect.left + payload.rect.left,
          top: guestRect.top + payload.rect.top,
          width: payload.rect.width,
          height: payload.rect.height
        },
        title: payload.title,
        url: payload.url
      })
    }
    const onStartLoading = (): void => announce(webview, null)

    webview.addEventListener('dom-ready', inject)
    webview.addEventListener('did-start-loading', onStartLoading)
    webview.addEventListener('console-message', onConsoleMessage)
    inject()
    return () => {
      webview.removeEventListener('dom-ready', inject)
      webview.removeEventListener('did-start-loading', onStartLoading)
      webview.removeEventListener('console-message', onConsoleMessage)
      announce(webview, null)
    }
  }, [webviewRef])
}
