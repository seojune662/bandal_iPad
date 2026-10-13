import { ensureRegularAppPresence } from './mainWindow'
import { BrowserWindow, desktopCapturer, screen, systemPreferences, dialog, shell, type NativeImage, type IpcMainInvokeEvent } from 'electron'
import { join } from 'node:path'
import type { ChatAttachment } from '../../shared/types/chat'
import { cropPixels } from '../../shared/screenGeometry'
let active: { windows: Map<number, { window: BrowserWindow; image: NativeImage; width: number; height: number }>; finish: (image: NativeImage | null) => void } | null = null
let permissionExplained = false
let capturing = false
function attachment(image: NativeImage): ChatAttachment {
  const size = image.getSize(), factor = Math.min(1, 1800 / Math.max(size.width, size.height))
  const resized = factor < 1 ? image.resize({ width: Math.round(size.width * factor), quality: 'best' }) : image
  return { mediaType: 'image/png', dataBase64: resized.toPNG().toString('base64') }
}
async function ensureScreenPermission(): Promise<void> {
  if (process.platform === 'darwin' && systemPreferences.getMediaAccessStatus('screen') === 'not-determined') {
    // Register the explicit screen action with macOS so Bandal appears in its permission settings.
    await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 1, height: 1 } }).catch(() => [])
  }
  if (process.platform === 'darwin' && systemPreferences.getMediaAccessStatus('screen') !== 'granted') {
    if (!permissionExplained) {
      permissionExplained = true
      const result = await dialog.showMessageBox({ type: 'info', title: '화면 접근 허용', message: '화면을 질문하려면 화면 기록 권한이 필요해요.', detail: '시스템 설정에서 반달을 허용한 뒤, 화면 질문을 다시 선택해 주세요.', buttons: ['설정 열기', '취소'], defaultId: 0, cancelId: 1 })
      if (result.response === 0) await shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture')
    }
    throw new Error('화면 기록 권한이 아직 없어요. 시스템 설정에서 허용한 뒤 다시 시도해 주세요.')
  }
  permissionExplained = false
}
export async function selectScreen(region: boolean): Promise<ChatAttachment | null> {
  if (active || capturing) throw new Error('이미 화면 영역을 선택하고 있어요.')
  capturing = true
  try {
    await ensureScreenPermission()
  } catch (error) { capturing = false; throw error }
  const hidden = BrowserWindow.getAllWindows().filter(window => window.isVisible() && /[?&]view=(capture)/.test(window.webContents.getURL()))
  const focused = BrowserWindow.getFocusedWindow()
  hidden.forEach(window => window.hide())
  const restore = (): void => { hidden.forEach(window => { if (!window.isDestroyed()) window.showInactive() }); if (focused && !focused.isDestroyed()) focused.focus() }
  try {
    await new Promise(resolve => setTimeout(resolve, 180))
    const displays = screen.getAllDisplays(), cursor = screen.getCursorScreenPoint()
    const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: Math.max(...displays.map(d => Math.ceil(d.size.width * d.scaleFactor))), height: Math.max(...displays.map(d => Math.ceil(d.size.height * d.scaleFactor))) } })
    const captures = displays.map(display => ({ display, image: sources.find(source => source.display_id === String(display.id))?.thumbnail })).filter(item => item.image && !item.image.isEmpty())
    if (!captures.length) throw new Error('화면을 가져오지 못했어요. 화면 접근 권한을 확인해 주세요.')
    if (!region) { const capture = captures.find(item => item.display.id === screen.getDisplayNearestPoint(cursor).id) ?? captures[0]!; return attachment(capture.image!) }
    return await new Promise<ChatAttachment | null>(resolve => {
      const windows = new Map<number, { window: BrowserWindow; image: NativeImage; width: number; height: number }>()
      const finish = (image: NativeImage | null): void => { if (!active) return; active = null; for (const entry of windows.values()) entry.window.destroy(); resolve(image ? attachment(image) : null) }
      active = { windows, finish }
      for (const { display, image } of captures) {
        const window = new BrowserWindow({ ...display.bounds, frame: false, show: false, resizable: false, movable: false, skipTaskbar: true, alwaysOnTop: true, backgroundColor: '#161616', enableLargerThanScreen: true,
          webPreferences: { preload: join(__dirname, '../preload/index.js'), sandbox: true, contextIsolation: true, nodeIntegration: false } })
        window.setAlwaysOnTop(true, 'screen-saver'); window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true })
        windows.set(window.webContents.id, { window, image: image!, width: display.bounds.width, height: display.bounds.height })
        window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
        window.webContents.on('will-navigate', e => e.preventDefault())
        window.on('close', () => finish(null))
        window.webContents.once('did-finish-load', () => { if (!active || window.isDestroyed()) return; window.showInactive(); if (display.id === screen.getDisplayNearestPoint(cursor).id) window.focus() })
        const dev = process.env.ELECTRON_RENDERER_URL
        if (dev) void window.loadURL(`${dev}/overlay.html?view=capture`).catch(() => finish(null))
        else void window.loadFile(join(__dirname, '../renderer/overlay.html'), { query: { view: 'capture' } }).catch(() => finish(null))
      }
    })
  } finally { capturing = false; restore(); ensureRegularAppPresence() }
}
export function screenSelectionRequest(event: IpcMainInvokeEvent, req: { action: 'get' | 'cancel' | 'select'; rect?: { x: number; y: number; width: number; height: number } }): { image?: string } {
  const entry = active?.windows.get(event.sender.id)
  if (!entry || event.senderFrame !== event.sender.mainFrame) return {}
  if (req.action === 'get') return { image: entry.image.toDataURL() }
  if (req.action === 'cancel') active?.finish(null)
  if (req.action === 'select' && req.rect && Object.values(req.rect).every(Number.isFinite) && req.rect.width >= 4 && req.rect.height >= 4) active?.finish(entry.image.crop(cropPixels(req.rect, entry, entry.image.getSize())))
  return {}
}
