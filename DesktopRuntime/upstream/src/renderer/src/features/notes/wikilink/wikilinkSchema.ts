/**
 * ProseMirror node for a wikilink. Inline atom: the whole `[[…]]` is one
 * selectable unit so typing next to it never edits the target by accident.
 *
 * The DOM shape (`span[data-wikilink]`) is shared with the node view so a
 * copy/paste of the rendered chip parses back into the same node.
 */

import { $nodeSchema } from '@milkdown/utils'
import type { Node as ProseNode } from '@milkdown/prose/model'
import type { WikilinkParts } from '../../../../../shared/wikilink'
import { WIKILINK_MDAST_TYPE } from './remarkWikilink'

export const WIKILINK_NODE = 'wikilink'
export const WIKILINK_EMBED_LABEL = '임베드'

export function wikilinkPartsFromNode(node: ProseNode): WikilinkParts {
  const attrs = node.attrs
  return {
    target: typeof attrs['target'] === 'string' ? attrs['target'] : '',
    heading: typeof attrs['heading'] === 'string' ? attrs['heading'] : null,
    alias: typeof attrs['alias'] === 'string' ? attrs['alias'] : null,
    embed: attrs['embed'] === true
  }
}

/** What the chip shows: alias, else `target › heading`, else target. */
export function wikilinkLabel(parts: WikilinkParts): string {
  if (parts.alias !== null) return parts.alias
  return parts.heading === null ? parts.target : `${parts.target} › ${parts.heading}`
}

function optionalAttr(value: string | null): string | undefined {
  return value === null ? undefined : value
}

export const wikilinkSchema = $nodeSchema(WIKILINK_NODE, () => ({
  inline: true,
  group: 'inline',
  atom: true,
  selectable: true,
  draggable: false,
  marks: '',
  attrs: {
    target: { default: '' },
    heading: { default: null },
    alias: { default: null },
    embed: { default: false }
  },
  parseDOM: [
    {
      tag: 'span[data-wikilink]',
      getAttrs: (dom) => {
        if (!(dom instanceof HTMLElement)) return false
        return {
          target: dom.getAttribute('data-wikilink') ?? '',
          heading: dom.getAttribute('data-heading'),
          alias: dom.getAttribute('data-alias'),
          embed: dom.getAttribute('data-embed') === 'true'
        }
      }
    }
  ],
  toDOM: (node) => {
    const parts = wikilinkPartsFromNode(node)
    return [
      'span',
      {
        class: 'note-wikilink',
        'data-wikilink': parts.target,
        'data-heading': optionalAttr(parts.heading),
        'data-alias': optionalAttr(parts.alias),
        'data-embed': parts.embed ? 'true' : undefined
      },
      wikilinkLabel(parts)
    ]
  },
  parseMarkdown: {
    match: ({ type }) => type === WIKILINK_MDAST_TYPE,
    runner: (state, node, type) => {
      state.addNode(type, {
        target: typeof node['target'] === 'string' ? node['target'] : '',
        heading: typeof node['heading'] === 'string' ? node['heading'] : null,
        alias: typeof node['alias'] === 'string' ? node['alias'] : null,
        embed: node['embed'] === true
      })
    }
  },
  toMarkdown: {
    match: (node) => node.type.name === WIKILINK_NODE,
    runner: (state, node) => {
      state.addNode(WIKILINK_MDAST_TYPE, undefined, undefined, {
        ...wikilinkPartsFromNode(node)
      })
    }
  }
}))
