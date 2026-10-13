import type {
  MarkdownNode,
  RemarkParser,
  RemarkPluginRaw
} from '@milkdown/transformer'
import { $remark } from '@milkdown/utils'
import { visit } from 'unist-util-visit'
import { CALLOUT_LINE } from './calloutTypes'

interface MarkdownTracker {
  move: (value: string) => unknown
  shift: (size: number) => unknown
  current: () => unknown
}

interface MarkdownHandlerState {
  containerFlow: (node: MarkdownNode, info: unknown) => string
  createTracker: (info: unknown) => MarkdownTracker
  enter: (name: string) => () => void
  indentLines: (
    value: string,
    map: (line: string, index: number, blank: boolean) => string
  ) => string
}

type MarkdownHandler = (
  node: MarkdownNode,
  parent: MarkdownNode | undefined,
  state: MarkdownHandlerState,
  info: unknown
) => string

interface RemarkProcessorData {
  toMarkdownExtensions?: Array<{
    handlers: Record<string, MarkdownHandler>
  }>
}

function textValue(node: MarkdownNode | undefined): string | null {
  if (node?.type !== 'text' || typeof node.value !== 'string') return null
  return node.value
}

/** Converts blockquotes whose first text line is an Obsidian callout header. */
export function transformCallouts(tree: MarkdownNode): void {
  visit(tree, (visited) => {
    if (visited.type !== 'blockquote') return
    const node = visited as MarkdownNode
    const paragraph = node.children?.[0]
    if (paragraph?.type !== 'paragraph') return

    const firstInline = paragraph.children?.[0]
    const value = textValue(firstInline)
    if (value === null) return

    const firstLineEnd = value.indexOf('\n')
    const firstLine = firstLineEnd < 0 ? value : value.slice(0, firstLineEnd)
    const match = CALLOUT_LINE.exec(firstLine)
    if (match === null) return

    const sourceType = match[1]
    if (sourceType === undefined) return

    node.type = 'callout'
    node.calloutType = sourceType
    node.title = match[3] ?? ''
    node.collapsed = match[2] === '-'

    const remainder = firstLineEnd < 0 ? '' : value.slice(firstLineEnd + 1)
    if (remainder.length > 0 && firstInline !== undefined) {
      firstInline.value = remainder
    } else {
      paragraph.children?.shift()
    }

    if ((paragraph.children?.length ?? 0) === 0) node.children?.shift()
  })
}

function calloutHandler(
  node: MarkdownNode,
  _parent: MarkdownNode | undefined,
  state: MarkdownHandlerState,
  info: unknown
): string {
  const exit = state.enter('blockquote')
  const tracker = state.createTracker(info)
  tracker.move('> ')
  tracker.shift(2)

  const sourceType =
    typeof node.calloutType === 'string' && node.calloutType.length > 0
      ? node.calloutType
      : 'note'
  const title = typeof node.title === 'string' ? node.title : ''
  const marker = `[!${sourceType}]${node.collapsed === true ? '-' : ''}`
  const header = title.length > 0 ? `${marker} ${title}` : marker

  try {
    const body = state.containerFlow(node, tracker.current())
    if (body.length === 0) return `> ${header}`
    const quotedBody = state.indentLines(
      body,
      (line, _index, blank) => `>${blank ? '' : ' '}${line}`
    )
    return `> ${header}\n${quotedBody}`
  } finally {
    exit()
  }
}

/** Remark plugin used by both the editor and the headless markdown codec. */
function remarkCalloutAttacher(
  this: RemarkParser
): (tree: MarkdownNode) => void {
  const data = this.data() as RemarkProcessorData
  const extensions = data.toMarkdownExtensions ?? []
  if (data.toMarkdownExtensions === undefined) {
    data.toMarkdownExtensions = extensions
  }
  extensions.push({ handlers: { callout: calloutHandler } })

  return transformCallouts
}

export const remarkCallout = remarkCalloutAttacher as unknown as RemarkPluginRaw<
  Record<string, never>
>

export const remarkCalloutPlugin = $remark(
  'remarkCallout',
  () => remarkCallout,
  {}
)
