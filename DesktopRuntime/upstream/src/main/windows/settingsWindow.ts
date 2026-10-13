import { BrowserWindow } from 'electron'

/**
 * Settings no longer opens as its own BrowserWindow — it renders as a
 * full-window overlay inside the main window. This asks the main window's
 * renderer to show that overlay (and surfaces the window first, so ⌘, from
 * the app menu works while Bandal is minimized or unfocused).
 */
export function openSettingsInApp(): void {
  const target =
    BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
  if (target === undefined || target.isDestroyed()) return
  if (target.isMinimized()) target.restore()
  target.show()
  target.webContents.send('ui:openSettings', {})
}
