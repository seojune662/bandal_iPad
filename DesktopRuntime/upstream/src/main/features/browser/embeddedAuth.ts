import { randomUUID } from 'node:crypto'
import type { WebContents } from 'electron'
import { externalAuthRestartUrl, isBrowserAuthFlowUrl, isEmbeddedAuthProviderUrl } from '../../../shared/browserAuth'
import type { BrowserAuthReason, BrowserAuthStatus } from '../../../shared/types/browserAuth'

const sources = new WeakMap<WebContents, string>()
const documents = new WeakMap<WebContents, string>()
export const EMBEDDED_AUTH_STATUS_PREFIX = '__bandalEmbeddedAuthStatus__'
const OBSERVER_GLOBAL = '__bandalEmbeddedAuthObserver'

export function browserAuthDocumentId(page: WebContents): string {
  let id = documents.get(page)
  if (!id) { id = randomUUID(); documents.set(page, id) }
  return id
}

/** Only reason codes leave the document. Help links and hidden templates are not evidence. */
export function createEmbeddedAuthObserver(documentId: string): string {
  return String.raw`(() => {
    const key = ${JSON.stringify(OBSERVER_GLOBAL)}, documentId = ${JSON.stringify(documentId)};
    const previous = window[key];
    if (previous?.documentId === documentId) return previous.snapshot();
    previous?.dispose();
    let disposed = false, timer = 0;
    const visible = element => {
      for (let current = element; current; current = current.parentElement) {
        if (current.matches('script,style,noscript,template,[hidden],[aria-hidden="true"]')) return false;
        const style = getComputedStyle(current);
        if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
      }
      return true;
    };
    const textOf = root => {
      if (!root) return '';
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      let text = '', node;
      while ((node = walker.nextNode()) && text.length < 40000) {
        if (node.parentElement && !node.parentElement.closest('a') && visible(node.parentElement)) text += ' ' + node.textContent;
      }
      return text.slice(0, 40000);
    };
    const readSnapshot = () => {
      const main = document.querySelector('main,[role="main"]') || document.body;
      const text = textOf(main);
      const headings = Array.from((main || document).querySelectorAll('h1,h2,[role="heading"]')).map(textOf).join(' ');
      const rejectedPage = /\/(?:rejected|denied|error)(?:\/|$)/i.test(location.pathname);
      const rejectedHeading = /couldn['’]?t sign (?:you )?in|can(?:not|'t) sign in|로그인할 수 없|액세스.{0,4}(?:차단|거부)|access (?:blocked|denied)|error\s*403/i.test(headings);
      const explicitError = new URL(location.href).searchParams.get('error') === 'disallowed_useragent';
      let reason = null;
      if (explicitError || ((rejectedPage || rejectedHeading) && /\bdisallowed[_ -]?useragent\b/i.test(text))) reason = 'disallowed-useragent';
      else if ((rejectedPage || rejectedHeading) && /browser or app may not be secure|브라우저 또는 앱이 안전하지 않을 수/i.test(text)) reason = 'insecure-browser';
      else if ((rejectedPage || rejectedHeading) && /Family\s*Link/i.test(text) && /여기에서 로그인할 수 없|can(?:not|['’]t) sign in here|can(?:not|['’]t) be signed in here/i.test(text)) reason = 'supervised-account';
      return { documentId, reason };
    };
    let lastReason = readSnapshot().reason;
    // Main also reads after same-document URL changes, which do not necessarily
    // mutate the DOM. Keep subsequent mutation comparisons at that observed state.
    const snapshot = () => {
      const current = readSnapshot();
      lastReason = current.reason;
      return current;
    };
    const observer = new MutationObserver(() => {
      if (disposed || timer) return;
      timer = setTimeout(() => {
        timer = 0;
        if (disposed || window[key]?.documentId !== documentId) return;
        const reason = readSnapshot().reason;
        if (reason !== lastReason) {
          lastReason = reason;
          console.debug(${JSON.stringify(EMBEDDED_AUTH_STATUS_PREFIX)} + documentId);
        }
      }, 100);
    });
    observer.observe(document.documentElement, {
      childList: true, subtree: true, characterData: true, attributes: true,
      attributeFilter: ['hidden', 'aria-hidden', 'class', 'style']
    });
    window[key] = {
      documentId, snapshot,
      dispose() { disposed = true; clearTimeout(timer); observer.disconnect(); }
    };
    return snapshot();
  })()`
}

const SNAPSHOT_SOURCE = `window[${JSON.stringify(OBSERVER_GLOBAL)}]?.snapshot()`

export function inheritEmbeddedAuthSource(child: WebContents, parent: WebContents): void {
  const source = sources.get(parent) ?? parent.getURL()
  if (source) sources.set(child, source)
}

function address(value: string): { origin: string; path: string } {
  try {
    const url = new URL(value)
    if (url.protocol === 'https:' || url.protocol === 'http:') return { origin: url.origin, path: url.pathname }
  } catch { /* A closing page may no longer have a URL. */ }
  return { origin: '', path: '' }
}

export function attachEmbeddedAuthFallback(page: WebContents, onStatus: (status: BrowserAuthStatus) => void): void {
  let documentId = browserAuthDocumentId(page)
  let ready = false, navigating = false, revision = 0
  let lastReason: BrowserAuthReason | null = null
  let lastAddress = address(page.getURL())
  const remember = (url: string): void => {
    if (!isBrowserAuthFlowUrl(url) && /^https?:\/\//.test(url)) sources.set(page, url)
  }
  const emit = (reason: BrowserAuthReason | null, url: string): void => {
    lastReason = reason
    lastAddress = address(url)
    onStatus({ status: reason ? 'blocked' : 'clear', documentId, ...lastAddress,
      ...(reason ? { reason, restartUrl: externalAuthRestartUrl(url, sources.get(page)) } : {}) })
  }
  const invalidate = (url: string): void => {
    ready = false
    revision++
    documentId = randomUUID()
    documents.set(page, documentId)
    emit(null, url)
  }
  const inspect = (install = false): void => {
    if (!ready || page.isDestroyed() || !isEmbeddedAuthProviderUrl(page.getURL())) return
    const expectedDocument = documentId, expectedRevision = ++revision
    void page.executeJavaScript(install ? createEmbeddedAuthObserver(documentId) : SNAPSHOT_SOURCE).then((value: unknown) => {
      if (!ready || page.isDestroyed() || documentId !== expectedDocument || revision !== expectedRevision ||
        !isEmbeddedAuthProviderUrl(page.getURL()) || !value || typeof value !== 'object') return
      const snapshot = value as { documentId?: unknown; reason?: unknown }
      if (snapshot.documentId !== documentId || (snapshot.reason !== null && snapshot.reason !== 'insecure-browser' && snapshot.reason !== 'disallowed-useragent' && snapshot.reason !== 'supervised-account')) return
      const reason = snapshot.reason as BrowserAuthReason | null
      if (reason !== lastReason) emit(reason, page.getURL())
    }).catch(() => undefined)
  }
  const resumeRetainedDocument = (): void => {
    // A canceled navigation can retain its document without another dom-ready.
    // Wait until a replacement navigation has also stopped before reattaching.
    if (ready || !navigating || page.isDestroyed() || page.isLoadingMainFrame()) return
    navigating = false
    ready = true
    inspect(true)
  }
  remember(page.getURL())
  // This listener runs before native page-state events: their document ID is authoritative.
  page.on('did-start-navigation', (details, url, isInPlace, isMainFrame) => {
    if (!(details.isMainFrame ?? isMainFrame) || (details.isSameDocument ?? isInPlace)) return
    remember(page.getURL())
    navigating = true
    invalidate(details.url ?? url)
  })
  page.on('did-navigate', (_event, url) => {
    if (!navigating) invalidate(url)
    navigating = false
    remember(url)
  })
  page.on('will-navigate', () => remember(page.getURL()))
  page.on('dom-ready', () => { ready = true; inspect(true) })
  page.on('did-stop-loading', resumeRetainedDocument)
  page.on('did-fail-load', (_event, code, _description, _url, isMainFrame) => {
    if (isMainFrame && code === -3) resumeRetainedDocument()
  })
  page.on('did-navigate-in-page', (_event, _url, isMainFrame) => { if (isMainFrame) inspect() })
  page.on('console-message', (details, _level, message) => {
    // A subframe or a previous document cannot change the current page's status.
    if (details.frame !== page.mainFrame || (details.message ?? message) !== EMBEDDED_AUTH_STATUS_PREFIX + documentId) return
    inspect()
  })
  page.once('destroyed', () => {
    ready = false
    revision++
    // Standalone login windows report into their parent tab. Closing a window
    // must withdraw its notice without reading an already destroyed WebContents.
    if (lastReason) onStatus({ status: 'clear', documentId, ...lastAddress })
    lastReason = null
  })
}
