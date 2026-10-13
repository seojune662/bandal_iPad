/**
 * Obsidian-style wikilinks for notes.
 *
 * - `wikilinkMarkdown`: schema + remark plugin. Shared by the editor and the
 *   headless codec through `noteMarkdownExtensions.ts`.
 * - `wikilinkEditor`: node view + its context slice. Editor only.
 * - `createWikilinkPickerPlugin`: the `[[` picker, registered per editor via
 *   `prosePluginsCtx` next to the `@` mention plugin.
 */

import type { MilkdownPlugin } from '@milkdown/ctx'
import { remarkWikilinkPlugin } from './remarkWikilink'
import { wikilinkSchema } from './wikilinkSchema'
import { wikilinkContextCtx, wikilinkView } from './wikilinkView'

export const wikilinkMarkdown: MilkdownPlugin[] = [
  ...wikilinkSchema,
  ...remarkWikilinkPlugin
]

export const wikilinkEditor: MilkdownPlugin[] = [wikilinkContextCtx, wikilinkView]

export { createWikilinkPickerPlugin } from './wikilinkPickerPlugin'
export { wikilinkContextCtx } from './wikilinkView'
