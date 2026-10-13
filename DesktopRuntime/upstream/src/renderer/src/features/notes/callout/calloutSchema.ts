import { $nodeSchema } from '@milkdown/utils'
import { normalizeCalloutType } from './calloutTypes'

function stringAttr(value: unknown, fallback: string): string {
  return typeof value === 'string' ? value : fallback
}

function booleanAttr(value: unknown): boolean {
  return value === true || value === 'true'
}

export const calloutSchema = $nodeSchema('callout', () => ({
  content: 'block+',
  group: 'block',
  defining: true,
  attrs: {
    type: { default: 'note' },
    title: { default: '' },
    collapsed: { default: false }
  },
  parseDOM: [
    {
      tag: 'div[data-callout]',
      getAttrs: (dom) => {
        if (!(dom instanceof HTMLElement)) return false
        return {
          type: dom.dataset.calloutType ?? dom.dataset.callout ?? 'note',
          title: dom.dataset.calloutTitle ?? '',
          collapsed: dom.dataset.calloutCollapsed === 'true'
        }
      }
    }
  ],
  toDOM: (node) => {
    const sourceType = stringAttr(node.attrs['type'], 'note')
    const title = stringAttr(node.attrs['title'], '')
    const collapsed = booleanAttr(node.attrs['collapsed'])
    return [
      'div',
      {
        'data-callout': normalizeCalloutType(sourceType),
        'data-callout-type': sourceType,
        'data-callout-title': title,
        'data-callout-collapsed': String(collapsed),
        class: 'note-callout'
      },
      0
    ]
  },
  parseMarkdown: {
    match: ({ type }) => type === 'callout',
    runner: (state, node, type) => {
      state
        .openNode(type, {
          type: stringAttr(node.calloutType, 'note'),
          title: stringAttr(node.title, ''),
          collapsed: booleanAttr(node.collapsed)
        })
        .next(node.children)
        .closeNode()
    }
  },
  toMarkdown: {
    match: (node) => node.type.name === 'callout',
    runner: (state, node) => {
      state
        .openNode('callout', undefined, {
          calloutType: stringAttr(node.attrs['type'], 'note'),
          title: stringAttr(node.attrs['title'], ''),
          collapsed: booleanAttr(node.attrs['collapsed'])
        })
        .next(node.content)
        .closeNode()
    }
  }
}))
