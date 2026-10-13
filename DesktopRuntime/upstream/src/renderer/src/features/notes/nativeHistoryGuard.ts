/**
 * Keeps ⌘Z / ⇧⌘Z on the note editor inside ProseMirror.
 *
 * `main/menu.ts` builds the Edit menu with `role: 'editMenu'`, which binds ⌘Z
 * and ⇧⌘Z to Electron's native `webContents.undo()` / `.redo()`. On macOS the
 * NSMenu key equivalent is consumed before the key event reaches the page, so
 * prosemirror-history's own `Mod-z` keymap never gets a chance to run — and the
 * native undo then rewrites the contenteditable behind ProseMirror's back,
 * which desynchronizes the document from the editor state.
 *
 * `webContents.undo()` is `document.execCommand('undo')`, and Chromium fires a
 * *cancelable* `beforeinput` with `inputType: 'historyUndo'` at the editable
 * before applying it. Catching that event lets us cancel the native edit and
 * route the intent into prosemirror-history instead.
 *
 * Replacing the `editMenu` role with custom undo/redo items in `main/menu.ts`
 * would be the tidier other half of this fix; the guard is worth keeping
 * regardless, because it also covers the native context menu's 실행 취소 item.
 */

import { redo, undo } from '@milkdown/prose/history'
import { Plugin } from '@milkdown/prose/state'
import type { Command } from '@milkdown/prose/state'
import type { EditorView } from '@milkdown/prose/view'

export interface HistoryCommands {
  undo: Command
  redo: Command
}

const DEFAULT_COMMANDS: HistoryCommands = { undo, redo }

/**
 * `beforeinput` handler that converts native history input types into
 * ProseMirror history commands. Returns true when it took over the event.
 */
export function createHistoryBeforeInputHandler(
  commands: HistoryCommands = DEFAULT_COMMANDS
): (view: EditorView, event: InputEvent) => boolean {
  return (view, event) => {
    const command =
      event.inputType === 'historyUndo'
        ? commands.undo
        : event.inputType === 'historyRedo'
          ? commands.redo
          : null
    if (command === null) return false

    // Cancel unconditionally — even with nothing left to undo, letting the
    // native edit through would mutate the DOM out from under ProseMirror.
    event.preventDefault()
    command(view.state, view.dispatch, view)
    return true
  }
}

/** ProseMirror plugin form, for `prosePluginsCtx`. */
export function nativeHistoryGuard(commands?: HistoryCommands): Plugin {
  const handler = createHistoryBeforeInputHandler(commands)
  return new Plugin({
    props: {
      handleDOMEvents: {
        beforeinput: (view, event) => handler(view, event as InputEvent)
      }
    }
  })
}
