import { app, BrowserWindow } from 'electron'
import { join } from 'node:path'
import { isAppRendererSender } from './rendererSender'

/** Run before reading a request or invoking any app capability. */
export function assertAppRendererSender(event: Pick<Electron.IpcMainEvent, 'sender' | 'senderFrame'>): void {
  if (!isAppRendererSender(event, sender => BrowserWindow.fromWebContents(sender), {
    rendererDirectory: join(__dirname, '../renderer'),
    ...(!app.isPackaged && process.env['ELECTRON_RENDERER_URL'] !== undefined
      ? { developmentUrl: process.env['ELECTRON_RENDERER_URL'] } : {})
  })) throw new Error('IPC sender is not an app renderer')
}
