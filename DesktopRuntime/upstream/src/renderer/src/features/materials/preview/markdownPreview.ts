import type { Node as ProseNode } from '@milkdown/prose/model'
import type { MarkdownCodec } from '../../notes/markdownCodec'

let codecPromise: Promise<MarkdownCodec> | undefined

/** Keep document formatting, but never fetch embedded URLs or create links on hover. */
export async function markdownPreviewFragment(markdown: string): Promise<DocumentFragment> {
  codecPromise ??= import('../../notes/markdownCodec').then(({ createMarkdownCodec }) => createMarkdownCodec())
  const [codec, { DOMSerializer, Fragment }] = await Promise.all([
    codecPromise,
    import('@milkdown/prose/model')
  ])
  const parsed = codec.parse(markdown.slice(0, 1200))
  const safeNode = (node: ProseNode): ProseNode | null => {
    if (node.type.name === 'image') {
      const label = String(node.attrs['alt'] ?? '').trim()
      return label.length > 0 ? node.type.schema.text(`[${label}]`) : null
    }
    if (node.isText) return node.mark(node.marks.filter((mark) => mark.type.name !== 'link'))
    const children: ProseNode[] = []
    node.forEach((child) => {
      const safe = safeNode(child)
      if (safe !== null) children.push(safe)
    })
    return node.copy(Fragment.from(children))
  }
  const safe = safeNode(parsed) ?? parsed
  const fragment = document.createDocumentFragment()
  DOMSerializer.fromSchema(safe.type.schema).serializeFragment(safe.content, {}, fragment)
  for (const element of fragment.querySelectorAll('a, input, button')) {
    element.setAttribute('tabindex', '-1')
    if (element instanceof HTMLInputElement || element instanceof HTMLButtonElement) element.disabled = true
    element.removeAttribute('href')
  }
  return fragment
}
