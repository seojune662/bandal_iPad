/**
 * Why this page is broken.
 *
 * The OZ Report Viewer failure took a codebase archaeology session to reason
 * about, because the app knew exactly what it had blocked and told nobody.
 * This is the affordance that makes the next one a paste instead of an
 * investigation — and it works in a release build, where DevTools is the only
 * other option and a student cannot be walked through it over KakaoTalk.
 *
 * Third instance of the console-bridge pattern (`selectionBridge.ts`,
 * `loginBridge.ts`): a reporter injected with `executeJavaScript` on
 * `dom-ready`, read back through the DOM `console-message` event behind a
 * `__bandal_*__` prefix. No preload, no Electron API in the guest, no sandbox
 * relaxation.
 *
 * The environment probe is the valuable half. It answers, in one line, every
 * question we had to answer by reading source: is the PDF viewer on, did
 * `window.open` return null, what actually threw.
 */

import { useEffect, type RefObject } from 'react'
import type { BrowserPageHandle } from './browserPageTypes'

const CONSOLE_PREFIX = '__bandal_diag__'
/** Enough to see a failure and its aftermath; small enough to paste. */
const MAX_ENTRIES = 100

export interface DiagnosticEntry {
  kind: 'error' | 'rejection' | 'console' | 'open-null' | 'env' | 'blocked' | 'http'
  message: string
  at: string
}

export interface TabDiagnostics {
  url: string
  entries: DiagnosticEntry[]
}

const byTab = new Map<string, TabDiagnostics>()

export const BROWSER_DIAGNOSTICS_EVENT = 'bandal:browser-diagnostics'
export const OPEN_DIAGNOSTICS_EVENT = 'bandal:open-diagnostics'

/** Asks the panel that owns this tab to show its diagnostics. */
export function openDiagnostics(tabId: string): void {
  window.dispatchEvent(new CustomEvent(OPEN_DIAGNOSTICS_EVENT, { detail: tabId }))
}

function diagnosticAddress(value: string): string {
  try { const url = new URL(value); return `${url.origin}${url.pathname}` } catch { return 'unknown' }
}

export function recordHttpResponse(tabId: string, url: string, status: number): void {
  if (!Number.isInteger(status) || status < 100) return
  record(tabId, url, { kind: 'http', message: `HTTP ${status}${status === 503 ? ' · 서버가 서비스를 제공하지 못했어요. 로그인 요청은 자동으로 재전송하지 않습니다.' : ''}`, at: new Date().toISOString() })
}

function record(tabId: string, url: string, entry: DiagnosticEntry): void {
  const current = byTab.get(tabId) ?? { url, entries: [] }
  const entries = [...current.entries, entry].slice(-MAX_ENTRIES)
  byTab.set(tabId, { url: diagnosticAddress(url), entries })
  window.dispatchEvent(new CustomEvent(BROWSER_DIAGNOSTICS_EVENT, { detail: tabId }))
}

export function diagnosticsFor(tabId: string): TabDiagnostics | null {
  return byTab.get(tabId) ?? null
}

export function clearDiagnostics(tabId: string): void {
  byTab.delete(tabId)
}

/** Everything the student can paste into an issue. */
export function diagnosticsReport(tabId: string): string {
  const diagnostics = byTab.get(tabId)
  if (diagnostics === null || diagnostics === undefined) return ''
  return [
    `URL: ${diagnostics.url}`,
    '',
    ...diagnostics.entries.map(
      (entry) => `[${entry.kind}] ${entry.at} ${entry.message}`
    )
  ].join('\n')
}

const REPORTER_SOURCE = `(() => {
  if (window.__bandalDiagReporterInstalledV1__ === true) return;
  Object.defineProperty(window, '__bandalDiagReporterInstalledV1__', {
    value: true, configurable: false, enumerable: false, writable: false
  });
  const prefix = ${JSON.stringify(CONSOLE_PREFIX)};
  const send = (kind, message) => {
    try {
      console.log(prefix + JSON.stringify({
        kind,
        message: String(message).slice(0, 2000),
        url: location.origin + location.pathname
      }));
    } catch (ignored) { /* a message we cannot serialise is not worth throwing over */ }
  };
  // Never collect console arguments, rejection values, credentials or auth payloads.
  window.addEventListener('error', () => send('error', 'Page script error'), true);
  window.addEventListener('unhandledrejection', () => send('rejection', 'Unhandled page promise rejection'));
  // The single most useful signal: a page whose window.open came back null is
  // a page our popup policy just broke.
  const nativeOpen = window.open.bind(window);
  window.open = (...args) => {
    const result = nativeOpen(...args);
    if (result === null) send('open-null', 'window.open returned null');
    return result;
  };
  // One-shot environment probe — answers the questions we previously had to
  // answer by reading our own source.
  send('env', JSON.stringify({
    plugins: navigator.plugins ? navigator.plugins.length : 0,
    pdfViewerEnabled: navigator.pdfViewerEnabled === true,
    pdfMime: !!(navigator.mimeTypes && navigator.mimeTypes['application/pdf']),
    cookieEnabled: navigator.cookieEnabled,
    contentType: document.contentType,
    frames: window.frames.length
  }));
})();`

interface ConsoleMessageEvent extends Event {
  message: string
}

function parse(
  message: string
): { kind: DiagnosticEntry['kind']; message: string; url: string } | null {
  if (!message.startsWith(CONSOLE_PREFIX)) return null
  try {
    const parsed: unknown = JSON.parse(message.slice(CONSOLE_PREFIX.length))
    if (typeof parsed !== 'object' || parsed === null) return null
    const candidate = parsed as Record<string, unknown>
    const kind = candidate['kind']
    const text = candidate['message']
    const url = candidate['url']
    if (typeof kind !== 'string' || typeof text !== 'string') return null
    if (typeof url !== 'string' || url.length > 20_000) return null
    if (
      kind !== 'error' &&
      kind !== 'rejection' &&
      kind !== 'console' &&
      kind !== 'open-null' &&
      kind !== 'env'
    ) {
      return null
    }
    if (kind === 'env') {
      const env = JSON.parse(text) as Record<string, unknown>
      const summary = { pdfViewerEnabled: env['pdfViewerEnabled'] === true, cookieEnabled: env['cookieEnabled'] === true }
      return { kind, message: JSON.stringify(summary), url: diagnosticAddress(url) }
    }
    const labels = { error: 'Page script error', rejection: 'Unhandled page promise rejection', console: 'Page console error', 'open-null': 'window.open returned null' }
    return { kind, message: labels[kind], url: diagnosticAddress(url) }
  } catch {
    return null
  }
}

export function useBrowserDiagnosticsBridge(
  tabId: string,
  webviewRef: RefObject<BrowserPageHandle | null>
): void {
  useEffect(() => {
    const webview = webviewRef.current
    if (webview === null) return

    const inject = (): void => {
      try {
        void webview.executeJavaScript(REPORTER_SOURCE).catch(() => {
          // Cross-origin or gone. Navigation supplies another dom-ready.
        })
      } catch {
        // Not attached yet.
      }
    }
    const onConsoleMessage = (rawEvent: Event): void => {
      const event = rawEvent as ConsoleMessageEvent
      if (typeof event.message !== 'string') return
      const payload = parse(event.message)
      if (payload === null) return
      record(tabId, payload.url, {
        kind: payload.kind,
        message: payload.message,
        at: new Date().toISOString()
      })
    }
    // A fresh document is a fresh investigation; keeping the old entries
    // would attribute the last page's errors to this one.
    const onStartLoading = (): void => clearDiagnostics(tabId)

    webview.addEventListener('dom-ready', inject)
    webview.addEventListener('did-start-loading', onStartLoading)
    webview.addEventListener('console-message', onConsoleMessage)
    inject()
    return () => {
      webview.removeEventListener('dom-ready', inject)
      webview.removeEventListener('did-start-loading', onStartLoading)
      webview.removeEventListener('console-message', onConsoleMessage)
    }
  }, [tabId, webviewRef])
}
