import { BrowserWindow, dialog, shell } from 'electron'
import type { WebContents } from 'electron'
import { isCleanBrowserAuthProbe } from './authProbe'

const downloadOnly = new Map<number, () => Promise<void>>()

/** A confirmed DownloadItem, never ERR_ABORTED alone, triggers cleanup. */
export function finishDownloadNavigation(id: number | null): void {
  if (id !== null) void downloadOnly.get(id)?.()
}

export function trackPopupDownload(
  window: BrowserWindow, opener: WebContents, host: WebContents
): void {
  const child = window.webContents
  let committed = false
  let failedUrl = ''
  let prompting = false
  const title = (loading = false): void => {
    if (window.isDestroyed()) return
    let address = child.getURL()
    try {
      const url = new URL(address)
      // Auth URLs can contain credentials in their query/fragment.
      address = `${url.origin}${url.pathname}`
    } catch { /* about:blank has no origin */ }
    window.setTitle(`${loading ? '불러오는 중 · ' : ''}${address || '새 창'} — 반달`)
  }
  child.on('page-title-updated', (event) => { event.preventDefault(); title() })
  child.on('did-start-loading', () => title(true))
  child.on('did-stop-loading', () => title())
  child.on('did-navigate', (_event, url) => {
    if (url !== 'about:blank' && url !== '') committed = true
    title()
  })
  child.on('did-fail-load', (_event, code, _description, url, isMainFrame) => {
    if (!isMainFrame || code === -3 || prompting || window.isDestroyed()) return
    prompting = true
    failedUrl = url
    void dialog.showMessageBox(window, {
      type: 'error', message: '페이지를 열지 못했어요.',
      detail: '다시 시도하거나 기본 브라우저에서 열 수 있어요.',
      buttons: ['닫기', '다시 시도', '기본 브라우저에서 열기'], cancelId: 0
    }).then(({ response }) => {
      if (window.isDestroyed()) return
      if (response === 1) void child.loadURL(failedUrl).catch(() => undefined)
      if (response === 2 && /^https?:\/\//.test(failedUrl)) void shell.openExternal(failedUrl)
    }).finally(() => { prompting = false })
  })
  downloadOnly.set(child.id, async () => {
    if (committed || child.isDestroyed() || isCleanBrowserAuthProbe()) return
    // about:blank may contain a document written by its opener (reports,
    // authentication). Never close that document just because its URL is blank.
    const empty = await child.mainFrame.executeJavaScript(
      "!document.body || document.body.children.length === 0 && !document.body.textContent.trim()"
    ).catch(() => false)
    if (!empty || committed || window.isDestroyed()) return
    window.close()
    if (!host.isDestroyed()) BrowserWindow.fromWebContents(host)?.focus()
    if (!opener.isDestroyed()) opener.focus()
  })
  window.once('closed', () => downloadOnly.delete(child.id))
}

/** Download-only site tabs disappear; written about:blank documents survive. */
export function trackTabDownload(child: WebContents, close: () => void): void {
  let committed = false
  child.on('did-navigate', (_event, url) => { if (url && url !== 'about:blank') committed = true })
  downloadOnly.set(child.id, async () => {
    if (committed || child.isDestroyed() || isCleanBrowserAuthProbe()) return
    const empty = await child.mainFrame.executeJavaScript("!document.body || document.body.children.length === 0 && !document.body.textContent.trim()").catch(() => false)
    if (empty && !committed && !child.isDestroyed()) close()
  })
  child.once('destroyed', () => downloadOnly.delete(child.id))
}
