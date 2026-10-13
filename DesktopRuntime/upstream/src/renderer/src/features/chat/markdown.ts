/**
 * CommonMark / GFM parser for chat answers. Raw HTML stays inert React text.
 * TeX delimiters used by ChatGPT are normalized outside code before remark
 * parses the answer, so formulas work in prose, lists and tables alike.
 */
import { remark } from 'remark'
import remarkGfm from 'remark-gfm'
import remarkMath from 'remark-math'

export type MdInline =
  | { kind: 'text'; text: string }
  | { kind: 'code'; text: string }
  | { kind: 'math'; text: string; display: boolean; pending: boolean }
  | { kind: 'break' }
  | { kind: 'strong' | 'em' | 'delete'; children: MdInline[] }
  | { kind: 'link'; href: string; children: MdInline[] }

export type MdBlockNode =
  | { kind: 'paragraph'; children: MdInline[] }
  | { kind: 'heading'; level: 1 | 2 | 3 | 4 | 5 | 6; children: MdInline[] }
  | { kind: 'code-block'; lang: string | null; text: string }
  | { kind: 'math-block'; text: string; pending: boolean }
  | { kind: 'list'; ordered: boolean; start: number; items: MdListItem[] }
  | { kind: 'quote'; children: MdBlockNode[] }
  | { kind: 'table'; align: Array<'left' | 'center' | 'right' | null>; rows: MdInline[][][] }
  | { kind: 'hr' }

interface MdListItem {
  children: MdBlockNode[]
  checked: boolean | null
}

interface MarkdownNode {
  type: string
  value?: string | undefined
  children?: MarkdownNode[] | undefined
  depth?: number | undefined
  lang?: string | null | undefined
  ordered?: boolean | null | undefined
  start?: number | null | undefined
  checked?: boolean | null | undefined
  align?: Array<'left' | 'center' | 'right' | null> | null | undefined
  url?: string | undefined
  identifier?: string | undefined
  alt?: string | null | undefined
  position?: { start: { offset?: number | undefined }; end: { offset?: number | undefined } } | undefined
}

interface Formula {
  text: string
  display: boolean
  pending: boolean
}

interface PreparedMarkdown {
  text: string
  formulas: Map<string, Formula>
}

const processor = remark().use(remarkGfm).use(remarkMath, { singleDollarTextMath: false })
const SAFE_LINK_PROTOCOLS = ['http:', 'https:', 'mailto:']

export function isSafeLinkHref(href: string): boolean {
  try {
    return SAFE_LINK_PROTOCOLS.includes(new URL(href).protocol)
  } catch {
    return false
  }
}

/**
 * Protect formulas with code placeholders before parsing Markdown. In
 * particular, literal | inside a TeX expression must not split a GFM table.
 * Formula source never becomes HTML; the renderer alone passes it to KaTeX.
 */
function prepareMarkdown(source: string, streaming: boolean): PreparedMarkdown {
  const formulas = new Map<string, Formula>()
  let marker = '\uE000bandal-math:'
  while (source.includes(marker)) marker += ':'
  let text = ''
  let cursor = 0
  while (cursor < source.length) {
    const atLineStart = cursor === 0 || source[cursor - 1] === '\n'
    if (atLineStart) {
      const remaining = source.slice(cursor)
      const fence = /^[ \t>]*(?:[-+*] |\d+[.)] )?(`{3,}|~{3,})[^\n]*(?:\n|$)/.exec(remaining)
      if (fence !== null) {
        const markerRun = fence[1] ?? '```'
        const close = new RegExp(`^[ \\t>]*${markerRun[0]}{${markerRun.length},}[ \\t]*(?:\\n|$)`, 'm')
        const rest = remaining.slice(fence[0].length)
        const end = close.exec(rest)
        const length = end === null ? remaining.length : fence[0].length + end.index + end[0].length
        text += remaining.slice(0, length)
        cursor += length
        continue
      }
      // CommonMark indented code has no inline Markdown or math.
      if (/^(?: {4}|\t)\S/.test(remaining) && (cursor === 0 || source.slice(0, cursor).endsWith('\n\n'))) {
        const code = /^(?:(?: {4}|\t)[^\n]*(?:\n|$)|\n)+/.exec(remaining)?.[0]
        if (code !== undefined) {
          text += code
          cursor += code.length
          continue
        }
      }
    }

    if (source[cursor] === '`') {
      const run = /^`+/.exec(source.slice(cursor))?.[0] ?? '`'
      let closing = source.indexOf(run, cursor + run.length)
      while (closing >= 0 && (source[closing - 1] === '`' || source[closing + run.length] === '`')) {
        closing = source.indexOf(run, closing + run.length)
      }
      const end = closing < 0 ? source.length : closing + run.length
      text += source.slice(cursor, end)
      cursor = end
      continue
    }

    const escaped = source[cursor] === '\\'
    const opener = source.startsWith('\\(', cursor) ? '\\('
      : source.startsWith('\\[', cursor) ? '\\['
        : source.startsWith('$$', cursor) ? '$$'
          : source[cursor] === '$' && !/\s/.test(source[cursor + 1] ?? ' ') ? '$' : null
    if (opener !== null) {
      const closer = opener === '\\(' ? '\\)' : opener === '\\[' ? '\\]' : opener
      const bodyStart = cursor + opener.length
      let end = source.indexOf(closer, bodyStart)
      // Escaped dollars belong to the formula itself, and a currency amount
      // followed by another price is not a math expression.
      while (end >= 0 && (source[end - 1] === '\\' || (opener === '$' && (/\s/.test(source[end - 1] ?? '') || /\d/.test(source[end + 1] ?? ''))))) {
        end = source.indexOf(closer, end + closer.length)
      }
      const pending = end < 0
      const body = source.slice(bodyStart, pending ? source.length : end)
      const isFormula = opener !== '$' || (!body.includes('\n\n') && (pending ? /[\\^_=]/.test(body) : true))
      if (isFormula && (!pending || streaming)) {
        const display = opener === '\\[' || opener === '$$'
        const key = `${marker}${formulas.size}\uE001`
        formulas.set(key, { text: body.trim(), display, pending })
        const linePrefix = source.slice(source.lastIndexOf('\n', cursor - 1) + 1, cursor)
        const afterEnd = pending ? source.length : end + closer.length
        const lineSuffix = source.slice(afterEnd, source.indexOf('\n', afterEnd) < 0 ? source.length : source.indexOf('\n', afterEnd))
        const standalone = display && linePrefix.trim() === '' && lineSuffix.trim() === ''
        text += standalone ? `\`\`\`${key}\n${linePrefix}\`\`\`` : `\`${key}\``
        cursor = afterEnd
        continue
      }
    }

    // Preserve escaped Markdown (including \\$) without treating it as math.
    const count = escaped && cursor + 1 < source.length ? 2 : 1
    text += source.slice(cursor, cursor + count)
    cursor += count
  }
  return { text, formulas }
}

interface ParseContext extends PreparedMarkdown {
  definitions: Map<string, string>
}

function sourceOf(node: MarkdownNode, context: ParseContext): string {
  return context.text.slice(node.position?.start.offset ?? 0, node.position?.end.offset ?? 0)
}

function mergeTextNodes(nodes: MdInline[]): MdInline[] {
  const merged: MdInline[] = []
  for (const node of nodes) {
    const previous = merged[merged.length - 1]
    if (node.kind === 'text' && previous?.kind === 'text') previous.text += node.text
    else merged.push(node)
  }
  return merged
}

function inlineNodes(nodes: MarkdownNode[], context: ParseContext): MdInline[] {
  return mergeTextNodes(nodes.flatMap((node): MdInline[] => {
    const children = (): MdInline[] => inlineNodes(node.children ?? [], context)
    switch (node.type) {
      case 'text':
      case 'html':
        return [{ kind: 'text', text: node.value ?? '' }]
      case 'inlineCode': {
        const formula = context.formulas.get(node.value ?? '')
        return formula === undefined
          ? [{ kind: 'code', text: node.value ?? '' }]
          : [{ kind: 'math', ...formula }]
      }
      case 'inlineMath':
        return [{ kind: 'math', text: node.value ?? '', display: false, pending: false }]
      case 'strong': return [{ kind: 'strong', children: children() }]
      case 'emphasis': return [{ kind: 'em', children: children() }]
      case 'delete': return [{ kind: 'delete', children: children() }]
      case 'break': return [{ kind: 'break' }]
      case 'link':
      case 'linkReference': {
        const href = node.url ?? context.definitions.get(node.identifier ?? '') ?? ''
        return isSafeLinkHref(href)
          ? [{ kind: 'link', href, children: children() }]
          : [{ kind: 'text', text: sourceOf(node, context) }]
      }
      // Do not fetch arbitrary remote images emitted by a model.
      case 'image':
      case 'imageReference':
        return [{ kind: 'text', text: node.alt || sourceOf(node, context) }]
      default:
        return node.children === undefined ? [{ kind: 'text', text: sourceOf(node, context) }] : children()
    }
  }))
}

function blockNode(node: MarkdownNode, context: ParseContext): MdBlockNode | null {
  const children = (): MdInline[] => inlineNodes(node.children ?? [], context)
  switch (node.type) {
    case 'paragraph': return { kind: 'paragraph', children: children() }
    case 'heading': return { kind: 'heading', level: node.depth as 1 | 2 | 3 | 4 | 5 | 6, children: children() }
    case 'code': {
      const formula = context.formulas.get(node.lang ?? '')
      return formula === undefined
        ? { kind: 'code-block', lang: node.lang ?? null, text: node.value ?? '' }
        : { kind: 'math-block', text: formula.text, pending: formula.pending }
    }
    case 'math': return { kind: 'math-block', text: node.value ?? '', pending: false }
    case 'list':
      return {
        kind: 'list', ordered: node.ordered ?? false, start: node.start ?? 1,
        items: (node.children ?? []).map((item) => ({
          children: blockNodes(item.children ?? [], context), checked: item.checked ?? null
        }))
      }
    case 'blockquote': return { kind: 'quote', children: blockNodes(node.children ?? [], context) }
    case 'table': return {
      kind: 'table', align: node.align ?? [],
      rows: (node.children ?? []).map((row) => (row.children ?? []).map((cell) => inlineNodes(cell.children ?? [], context)))
    }
    case 'thematicBreak': return { kind: 'hr' }
    case 'html': return { kind: 'paragraph', children: [{ kind: 'text', text: node.value ?? '' }] }
    case 'definition': return null
    default: return { kind: 'paragraph', children: children() }
  }
}

function blockNodes(nodes: MarkdownNode[], context: ParseContext): MdBlockNode[] {
  return nodes.flatMap((node) => {
    const block = blockNode(node, context)
    return block === null ? [] : [block]
  })
}

function parseDocument(text: string, streaming: boolean): { root: MarkdownNode; context: ParseContext } {
  const prepared = prepareMarkdown(text, streaming)
  const root: MarkdownNode = processor.parse(prepared.text)
  const definitions = new Map<string, string>()
  const collect = (node: MarkdownNode): void => {
    if (node.type === 'definition' && node.identifier !== undefined && node.url !== undefined && !definitions.has(node.identifier)) {
      definitions.set(node.identifier, node.url)
    }
    node.children?.forEach(collect)
  }
  collect(root)
  return { root, context: { ...prepared, definitions } }
}

export function parseInline(text: string): MdInline[] {
  const { root, context } = parseDocument(text, false)
  return inlineNodes(root.children?.[0]?.children ?? [], context)
}

export function parseMarkdown(text: string, streaming = false): MdBlockNode[] {
  const { root, context } = parseDocument(text, streaming)
  return blockNodes(root.children ?? [], context)
}

interface CachedBlock {
  key: string
  node: MdBlockNode
}

type BlockParsedListener = (node: MdBlockNode) => void

/**
 * Keep rendered block identity during streaming. CommonMark parsing considers
 * the whole answer (reference definitions and nested lists can affect earlier
 * nodes), but unchanged blocks never reconvert or rerender. Open code fences
 * append their body directly until a closing fence arrives.
 */
export class IncrementalMarkdownParser {
  private text = ''
  private streaming = false
  private blocks: MdBlockNode[] = []
  private cache: CachedBlock[] = []
  private openFence: { marker: string; lastLine: string; bodyPrefix: string } | null = null

  constructor(private readonly onBlockParsed?: BlockParsedListener) {}

  parse(text: string, streaming = false): MdBlockNode[] {
    if (text === this.text && streaming === this.streaming) return this.blocks
    if (this.openFence !== null && text.startsWith(this.text) && streaming === this.streaming) {
      const previous = this.blocks[this.blocks.length - 1]
      const appended = text.slice(this.text.length)
      const changedLines = this.openFence.lastLine + appended
      const closing = new RegExp(`^[ \\t]*${this.openFence.marker[0]}{${this.openFence.marker.length},}[ \\t]*$`, 'm')
      if (previous?.kind === 'code-block' && !closing.test(changedLines) && !changedLines.includes('\r')) {
        // remark drops the final newline from code, so only use the shortcut
        // when no line boundary is being added to the body.
        if (!appended.includes('\n')) {
          const node: MdBlockNode = { ...previous, text: previous.text + this.openFence.bodyPrefix + appended }
          this.blocks = [...this.blocks.slice(0, -1), node]
          this.text = text
          this.openFence.lastLine += appended
          this.openFence.bodyPrefix = ''
          return this.blocks
        }
      }
    }
    const { root, context } = parseDocument(text, streaming)
    const definitionsKey = JSON.stringify([...context.definitions])
    const previousCache = text.startsWith(this.text) ? this.cache : []
    const cache: CachedBlock[] = []
    for (const raw of root.children ?? []) {
      if (raw.type === 'definition') continue
      const source = sourceOf(raw, context)
      const formulasKey = source.includes('\uE000bandal-math:')
        ? JSON.stringify([...context.formulas].filter(([key]) => source.includes(key))) : ''
      const key = `${raw.type}:${source}:${definitionsKey}${formulasKey}`
      const previous = previousCache[cache.length]
      const node = previous?.key === key ? previous.node : blockNode(raw, context)
      if (node === null) continue
      if (node !== previous?.node) this.onBlockParsed?.(node)
      cache.push({ key, node })
    }
    this.text = text
    this.streaming = streaming
    this.cache = cache
    this.blocks = cache.map(({ node }) => node)
    this.openFence = null
    const last = root.children?.at(-1)
    if (last?.type === 'code' && !context.formulas.has(last.lang ?? '')) {
      const source = sourceOf(last, context)
      const opening = /^ {0,3}(`{3,}|~{3,})[^\n]*\n/.exec(source)
      if (opening !== null) {
        const marker = opening[1] ?? '```'
        const closing = new RegExp(`^[ \\t]*${marker[0]}{${marker.length},}[ \\t]*$`, 'm')
        if (!closing.test(source.slice(opening[0].length))) {
          this.openFence = { marker, lastLine: text.slice(text.lastIndexOf('\n') + 1), bodyPrefix: source.endsWith('\n') && source.length > opening[0].length ? '\n' : '' }
        }
      }
    }
    return this.blocks
  }
}
