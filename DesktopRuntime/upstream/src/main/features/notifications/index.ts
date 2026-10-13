import { BrowserWindow, Notification } from 'electron'
import { createMainWindow, getMainWindow } from '../../windows/mainWindow'
import { createNotifier, type Notifier } from './notifier'

function focusMainWindow(): void {
  const main = getMainWindow() ?? createMainWindow()
  if (main.isDestroyed()) return
  if (main.isMinimized()) main.restore()
  main.show()
  main.focus()
}

export function createSystemNotifier(
  getSettings: Parameters<typeof createNotifier>[0]['getSettings']
): Notifier {
  return createNotifier({
    getSettings,
    isSupported: () => Notification.isSupported(),
    isAppFocused: () => BrowserWindow.getFocusedWindow() !== null,
    show: (options, onClick) => {
      const notification = new Notification(options)
      notification.on('click', () => {
        focusMainWindow()
        onClick?.()
      })
      notification.show()
    }
  })
}

export { createDeadlineScheduler } from './deadlineScheduler'
