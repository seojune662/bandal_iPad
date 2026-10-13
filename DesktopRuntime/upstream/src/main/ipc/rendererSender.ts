import { resolve, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const APP_PAGES = ['index.html', 'settings.html', 'overlay.html', 'pip.html'] as const
export interface RendererLocationPolicy {
  rendererDirectory: string
  developmentUrl?: string
}

/** Exact app documents only; sharing an origin or a filename is insufficient. */
export function isAppRendererUrl(value: string, policy: RendererLocationPolicy): boolean {
  let url: URL
  try { url = new URL(value) } catch { return false }
  if (url.username || url.password) return false
  if (url.protocol === 'file:') {
    try {
      const path = resolve(fileURLToPath(url))
      return APP_PAGES.some(page => path === resolve(join(policy.rendererDirectory, page)))
    } catch { return false }
  }
  if (!policy.developmentUrl || !['http:', 'https:'].includes(url.protocol)) return false
  try {
    return APP_PAGES.some(page => {
      const allowed = new URL(`${policy.developmentUrl}/${page}`)
      return !allowed.username && !allowed.password && url.origin === allowed.origin && url.pathname === allowed.pathname
    })
  } catch { return false }
}

interface RendererFrame { url: string }
interface RendererContents { mainFrame: RendererFrame; isDestroyed(): boolean }
interface RendererWindow<T> { webContents: T; isDestroyed(): boolean }
interface RendererIpcEvent<T> { sender: T; senderFrame: RendererFrame | null }

/** Capability belongs to the BrowserWindow's own top frame, never its guests. */
export function isAppRendererSender<T extends RendererContents>(
  event: RendererIpcEvent<T>,
  ownerFor: (sender: T) => RendererWindow<T> | null,
  policy: RendererLocationPolicy
): boolean {
  try {
    if (event.sender.isDestroyed() || event.senderFrame === null || event.senderFrame !== event.sender.mainFrame) return false
    const owner = ownerFor(event.sender)
    return owner !== null && !owner.isDestroyed() && owner.webContents === event.sender && isAppRendererUrl(event.senderFrame.url, policy)
  } catch { return false }
}
