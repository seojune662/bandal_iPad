import { BrowserWindow } from 'electron'
import { join } from 'node:path'
import { macPanelOptions } from './panelOptions'

export const MINI_PLAYER_TOOLBAR_HEIGHT = 36

export function createMiniPlayerToolbar(opts: {
  pipWindow: BrowserWindow
  preload: string
}): BrowserWindow {
  const parentBounds = opts.pipWindow.getBounds()
  const toolbar = new BrowserWindow({
    parent: opts.pipWindow,
    x: parentBounds.x,
    y: parentBounds.y,
    width: parentBounds.width,
    height: MINI_PLAYER_TOOLBAR_HEIGHT,
    show: false,
    transparent: true,
    frame: false,
    focusable: false,
    resizable: false,
    movable: false,
    hasShadow: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    ...macPanelOptions(),
    webPreferences: {
      preload: opts.preload,
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false
    }
  })

  toolbar.setAlwaysOnTop(true, 'floating')
  toolbar.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  toolbar.webContents.on('will-navigate', (event) => event.preventDefault())

  const position = (): void => {
    if (opts.pipWindow.isDestroyed() || toolbar.isDestroyed()) return
    const bounds = opts.pipWindow.getBounds()
    toolbar.setBounds({
      x: bounds.x,
      y: bounds.y,
      width: bounds.width,
      height: MINI_PLAYER_TOOLBAR_HEIGHT
    })
  }
  opts.pipWindow.on('move', position)
  opts.pipWindow.on('resize', position)

  const rendererUrl = process.env['ELECTRON_RENDERER_URL']
  if (rendererUrl !== undefined) {
    void toolbar.loadURL(`${rendererUrl}/pip.html?view=toolbar`)
  } else {
    void toolbar.loadFile(join(__dirname, '../renderer/pip.html'), {
      query: { view: 'toolbar' }
    })
  }

  return toolbar
}
