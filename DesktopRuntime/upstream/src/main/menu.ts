import { iPadCompanionMenu } from './features/ipadSync/runtime'
/**
 * [M6-A] Application menu.
 *
 * Exists mostly so the DEFAULT macOS menu does not: the default File menu
 * binds ⌘W to "Close Window", which swallows the chord at the menu layer —
 * the renderer would never see it. Bandal treats ⌘W as "close active tab"
 * (renderer keydown, src/renderer/src/app/shortcuts.ts), so here:
 *  - window close moves to ⇧⌘W,
 *  - 설정… gets the standard ⌘, slot,
 *  - Edit/View/Window keep their roles (copy/paste/reload/minimize).
 */

import { BrowserWindow, Menu } from 'electron'
import type { MenuItemConstructorOptions } from 'electron'
import {
  parseChord,
  printChord,
  resolveKeymap,
  type ShortcutActionId
} from '../shared/keymap'
import { openSettingsInApp } from './windows/settingsWindow'

const PRINT_MENU_ITEM_ID = 'print'
let printMenuEnabled = false

function chordForAction(
  keymap: ReadonlyMap<string, ShortcutActionId>,
  action: ShortcutActionId
): string | null {
  for (const [chord, mappedAction] of keymap) {
    if (mappedAction === action) return chord
  }
  return null
}

/** Converts a platform-neutral shared chord into Electron accelerator syntax. */
export function electronAcceleratorForChord(
  value: string | null
): string | undefined {
  if (value === null) return undefined
  const chord = parseChord(value)
  if (chord === null) return undefined
  const namedKeys: Readonly<Record<string, string>> = {
    arrowdown: 'Down',
    arrowleft: 'Left',
    arrowright: 'Right',
    arrowup: 'Up',
    escape: 'Esc',
    pagedown: 'PageDown',
    pageup: 'PageUp',
    space: 'Space'
  }
  const key =
    namedKeys[chord.key] ??
    (chord.key.length === 1 ? chord.key.toUpperCase() : chord.key)
  return [
    chord.mod ? 'CmdOrCtrl' : null,
    chord.alt ? 'Alt' : null,
    chord.shift ? 'Shift' : null,
    key
  ].filter((part): part is string => part !== null).join('+')
}

function requestPrint(): void {
  const target =
    BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0]
  if (target === undefined || target.isDestroyed()) return
  target.webContents.send('ui:print', {})
}

/**
 * Turns 파일 ▸ 인쇄… on and off as the active tab changes.
 *
 * This is not decoration — it is how ⌘P means two things. A macOS menu
 * accelerator is consumed by `performKeyEquivalent:` before the event reaches
 * the window, so as long as the item is ENABLED it owns ⌘P. A DISABLED item
 * does not perform its key equivalent, and the event falls through the
 * responder chain to the renderer, where ⌘P is still 빠른 파일 검색.
 *
 * Mutates the live item rather than rebuilding the menu: rebuilding on every
 * tab change would drop open submenus and re-register every accelerator.
 */
export function setPrintMenuEnabled(enabled: boolean): void {
  printMenuEnabled = enabled
  const item = Menu.getApplicationMenu()?.getMenuItemById(PRINT_MENU_ITEM_ID)
  if (item === null || item === undefined) return
  item.enabled = enabled
}

export function installApplicationMenu(
  keymap: ReadonlyMap<string, ShortcutActionId> = resolveKeymap({})
): void {
  const isMac = process.platform === 'darwin'
  const settingsAccelerator = electronAcceleratorForChord(
    chordForAction(keymap, 'settings')
  )
  const printAccelerator = electronAcceleratorForChord(printChord(keymap))

  const template: MenuItemConstructorOptions[] = [
    ...(isMac
      ? ([
          {
            label: 'Bandal',
            submenu: [
              { role: 'about' },
              { type: 'separator' },
              {
                label: '설정…',
                ...(settingsAccelerator === undefined
                  ? {}
                  : { accelerator: settingsAccelerator }),
                click: () => {
                  openSettingsInApp()
                }
              },
              { type: 'separator' },
              { role: 'services' },
              { type: 'separator' },
              { role: 'hide' },
              { role: 'hideOthers' },
              { role: 'unhide' },
              { type: 'separator' },
              { role: 'quit' }
            ]
          }
        ] satisfies MenuItemConstructorOptions[])
      : []),
    {
      label: '파일',
      submenu: [
        // Starts disabled: nothing is printable until a browser or PDF tab is
        // focused, and while it is disabled ⌘P falls through to the renderer
        // as 빠른 파일 검색. See setPrintMenuEnabled above.
        {
          id: PRINT_MENU_ITEM_ID,
          label: '인쇄…',
          ...(printAccelerator === undefined
            ? {}
            : { accelerator: printAccelerator }),
          enabled: printMenuEnabled,
          click: requestPrint
        },
        { type: 'separator' },
        // ⌘W is deliberately NOT bound here — the renderer uses it to close
        // the active workspace tab. Window close lives on ⇧⌘W instead.
        { label: '창 닫기', accelerator: 'Shift+CmdOrCtrl+W', role: 'close' }
      ]
    },
    { label: '편집', role: 'editMenu' },
    { label: '보기', role: 'viewMenu' },
    iPadCompanionMenu(),
    { label: '윈도우', role: 'windowMenu' }
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}
