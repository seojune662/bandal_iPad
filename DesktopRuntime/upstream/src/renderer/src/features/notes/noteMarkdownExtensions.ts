/**
 * Obsidian-flavoured markdown extensions shared by the editor AND the headless
 * codec: callouts (`> [!tip] 제목`) and wikilinks (`[[노트]]`).
 *
 * Only schemas + `$remark` plugins belong here — no node views, no ProseMirror
 * plugins. The codec (`markdownCodec.ts`) spreads this list too, so a note
 * containing one of these constructs parses identically with or without an
 * editor; leaving a schema out of the codec throws `parserMatchError` on the
 * unknown mdast node type.
 *
 * Each extension lives in its own folder and appends its markdown-only plugins
 * to this array. Ordering: after `gfm` (its autolink literal runs first) and
 * before the slash menu.
 */

import type { MilkdownPlugin } from '@milkdown/ctx'
import { calloutMarkdown } from './callout'
import { wikilinkMarkdown } from './wikilink'

export const NOTE_MARKDOWN_EXTENSIONS: MilkdownPlugin[] = [
  ...calloutMarkdown,
  ...wikilinkMarkdown
]
