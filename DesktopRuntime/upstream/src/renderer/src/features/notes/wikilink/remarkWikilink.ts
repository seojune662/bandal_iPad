/**
 * remark half of wikilinks: `[[…]]` inside text nodes becomes an mdast
 * `wikiLink` node, and that node stringifies back through `formatWikilink`.
 *
 * `[[` MUST be its own mdast node: mdast-util-to-markdown escapes `[` in
 * phrasing text, so a wikilink left as plain text would be written back as
 * `\[\[…]]` and stop being a wikilink on the next open.
 *
 * Text inside `link`, `linkReference` and `inlineCode` is left alone — a
 * normal `[label [[x]]](url)` keeps its label. Known limitation: `\[[x]]`
 * unescapes to the text `[[x]]` before this transform runs, so it is
 * promoted to a wikilink on the next round trip.
 */

import { $remark } from '@milkdown/utils'
import { findAndReplace } from 'mdast-util-find-and-replace'
import {
  formatWikilink,
  parseWikilink,
  wikilinkPattern,
  type WikilinkParts
} from '../../../../../shared/wikilink'

export const WIKILINK_MDAST_TYPE = 'wikiLink'

export type WikilinkMdastNode = WikilinkParts & { type: typeof WIKILINK_MDAST_TYPE }

interface ToMarkdownExtension {
  handlers: Record<string, (node: WikilinkMdastNode) => string>
}

/** The slice of a unified processor this plugin touches. */
interface RemarkProcessorLike {
  data: () => { toMarkdownExtensions?: ToMarkdownExtension[] }
}

const WIKILINK_TO_MARKDOWN: ToMarkdownExtension = {
  handlers: {
    [WIKILINK_MDAST_TYPE]: (node) => formatWikilink(node)
  }
}

/** Exported for the round-trip tests; `findAndReplace` calls it per match. */
export function wikilinkMdastFromMatch(match: string): WikilinkMdastNode | false {
  const parts = parseWikilink(match)
  if (parts === null) return false
  return { type: WIKILINK_MDAST_TYPE, ...parts }
}

function remarkWikilink(this: RemarkProcessorLike) {
  const data = this.data()
  const toMarkdownExtensions =
    data.toMarkdownExtensions ?? (data.toMarkdownExtensions = [])
  if (!toMarkdownExtensions.includes(WIKILINK_TO_MARKDOWN)) {
    toMarkdownExtensions.push(WIKILINK_TO_MARKDOWN)
  }
  // `@types/mdast` is not reachable from the renderer tree, so the tuple is
  // typed through the library's own parameter type instead of PhrasingContent.
  const patterns = [
    [wikilinkPattern(), wikilinkMdastFromMatch]
  ] as unknown as Parameters<typeof findAndReplace>[1]
  return (tree: Parameters<typeof findAndReplace>[0]) => {
    findAndReplace(tree, patterns, {
      ignore: ['link', 'linkReference', 'inlineCode']
    })
  }
}

export const remarkWikilinkPlugin = $remark(
  'remarkWikilink',
  () => remarkWikilink as unknown as ReturnType<Parameters<typeof $remark>[1]>
)
