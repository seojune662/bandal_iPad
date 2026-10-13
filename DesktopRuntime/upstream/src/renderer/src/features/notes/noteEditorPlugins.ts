/**
 * The Milkdown plugin set every note editor loads, in order.
 *
 * Kept out of NoteTab.tsx so the composition is assertable without mounting an
 * editor — notably that `history` is present, since without it ⌘Z on the note
 * surface does nothing at all (backlog §4.1).
 */

import type { MilkdownPlugin } from '@milkdown/ctx'
import { history } from '@milkdown/plugin-history'
import { commonmark } from '@milkdown/preset-commonmark'
import { gfm } from '@milkdown/preset-gfm'
import { calloutEditor } from './callout'
import { NOTE_MARKDOWN_EXTENSIONS } from './noteMarkdownExtensions'
import { slashMenu } from './slashMenuPlugin'
import { wikilinkEditor } from './wikilink'

export const NOTE_EDITOR_PLUGINS: readonly (MilkdownPlugin | MilkdownPlugin[])[] = [
  commonmark,
  gfm,
  // Obsidian-flavoured syntax (callouts, wikilinks) — schemas + remark only.
  NOTE_MARKDOWN_EXTENSIONS,
  ...calloutEditor,
  // Wikilink chip node view + its course context slice (editor only).
  wikilinkEditor,
  // Direct ProseMirror plugin: placeholder and slash-triggered block menu.
  slashMenu,
  // undo/redo — also supplies the Mod-z / Shift-Mod-z / Mod-y keymap.
  history
]

let highlightedPluginsPromise:
  | Promise<readonly (MilkdownPlugin | MilkdownPlugin[])[]>
  | undefined
let prismPluginsPromise: Promise<MilkdownPlugin[]> | undefined

export function loadNotePrismPlugins(): Promise<MilkdownPlugin[]> {
  if (prismPluginsPromise === undefined) {
    // ⚠ plugin-prism MUST resolve the exact same @milkdown/core instance as
    // the app: Slice/Timer identity is a per-module Symbol, so a second core
    // copy makes editor.create() reject silently and every toolbar command
    // no-op (the v0.13.0 dead-toolbar bug). Versions are pinned + overridden
    // in package.json and deduped in electron.vite.config.ts — keep all three.
    prismPluginsPromise = import('@milkdown/plugin-prism').then(({ prism }) => [...prism])
  }
  return prismPluginsPromise
}

/** Prism is split from the initial notes bundle and loaded before editor creation. */
export function loadNoteEditorPlugins(): Promise<
  readonly (MilkdownPlugin | MilkdownPlugin[])[]
> {
  if (highlightedPluginsPromise === undefined) {
    highlightedPluginsPromise = loadNotePrismPlugins().then(
      (prismPlugins) => [...NOTE_EDITOR_PLUGINS, prismPlugins]
    )
  }
  return highlightedPluginsPromise
}
