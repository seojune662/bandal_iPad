import {
  forwardRef,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  type CSSProperties,
  type FocusEvent as ReactFocusEvent
} from 'react'
import { toggleMark } from '@milkdown/prose/commands'
import { history, redo, undo } from '@milkdown/prose/history'
import { keymap } from '@milkdown/prose/keymap'
import {
  Fragment,
  Mark,
  Schema,
  Slice,
  type MarkType,
  type Node as ProseNode
} from '@milkdown/prose/model'
import { EditorState, TextSelection, type Transaction } from '@milkdown/prose/state'
import { EditorView } from '@milkdown/prose/view'
import type {
  DrawingInlineStyle,
  DrawingStyle,
  DrawingTextRun
} from '../../../../shared/types/drawing'
import { normalizeTextRuns } from '../../../../shared/textRuns'
import { TEXT_DEFAULT_FONT_PT, textBoxFontPx } from '../../../../shared/textBoxMetrics'
import type { TextStylePatch } from './textFormatStore'

const INLINE_FIELDS = [
  'color',
  'fontSizePt',
  'bold',
  'italic',
  'underline',
  'strike'
] as const satisfies readonly (keyof DrawingInlineStyle)[]

const BOOLEAN_MARKS = {
  bold: 'strong',
  italic: 'em',
  underline: 'underline',
  strike: 'strike'
} as const

function createSchema(): Schema {
  return new Schema({
    nodes: {
      doc: { content: 'inline*' },
      text: { group: 'inline' },
      hard_break: {
        inline: true,
        group: 'inline',
        selectable: false,
        leafText: () => '\n',
        parseDOM: [{ tag: 'br' }],
        toDOM: () => ['br']
      }
    },
    marks: {
      color: {
        attrs: { color: {} },
        parseDOM: [{
          tag: 'span[data-text-color]',
          getAttrs: (node) => ({ color: (node as HTMLElement).dataset.textColor })
        }],
        toDOM: (mark) => ['span', { 'data-text-color': mark.attrs.color }, 0]
      },
      fontSize: {
        attrs: { pt: {} },
        parseDOM: [{
          tag: 'span[data-font-size-pt]',
          getAttrs: (node) => ({ pt: Number((node as HTMLElement).dataset.fontSizePt) })
        }],
        toDOM: (mark) => ['span', { 'data-font-size-pt': String(mark.attrs.pt) }, 0]
      },
      strong: {
        parseDOM: [{ tag: 'strong' }, { tag: 'b' }],
        toDOM: () => ['strong', 0]
      },
      em: {
        parseDOM: [{ tag: 'em' }, { tag: 'i' }],
        toDOM: () => ['em', 0]
      },
      underline: {
        parseDOM: [{ tag: 'u' }],
        toDOM: () => ['u', 0]
      },
      strike: {
        parseDOM: [{ tag: 's' }, { tag: 'strike' }],
        toDOM: () => ['s', 0]
      }
    }
  })
}

function marksForStyle(schema: Schema, style: DrawingInlineStyle): Mark[] {
  const marks: Mark[] = []
  if (style.color !== undefined) marks.push(schema.marks.color!.create({ color: style.color }))
  if (style.fontSizePt !== undefined) {
    marks.push(schema.marks.fontSize!.create({ pt: style.fontSizePt }))
  }
  if (style.bold === true) marks.push(schema.marks.strong!.create())
  if (style.italic === true) marks.push(schema.marks.em!.create())
  if (style.underline === true) marks.push(schema.marks.underline!.create())
  if (style.strike === true) marks.push(schema.marks.strike!.create())
  return marks
}

function initialDoc(
  schema: Schema,
  text: string,
  sourceRuns: readonly DrawingTextRun[] | undefined,
  base: DrawingStyle
): ProseNode {
  const runs = normalizeTextRuns(text, sourceRuns)
  const nodes: ProseNode[] = []
  let offset = 0

  const baseMarks = marksForStyle(schema, booleanStyle(base))

  for (const run of runs) {
    if (run.from > offset) nodes.push(...textNodes(schema, text.slice(offset, run.from), baseMarks))
    nodes.push(...textNodes(
      schema,
      text.slice(run.from, run.to),
      marksForStyle(schema, { ...booleanStyle(base), ...run.style })
    ))
    offset = run.to
  }
  if (offset < text.length) nodes.push(...textNodes(schema, text.slice(offset), baseMarks))
  return schema.topNodeType.create(null, nodes)
}

function booleanStyle(style: DrawingInlineStyle): DrawingInlineStyle {
  return {
    bold: style.bold === true,
    italic: style.italic === true,
    underline: style.underline === true,
    strike: style.strike === true
  }
}

function textNodes(schema: Schema, text: string, marks: readonly Mark[]): ProseNode[] {
  const nodes: ProseNode[] = []
  for (const [index, part] of text.split('\n').entries()) {
    if (index > 0) nodes.push(schema.nodes.hard_break!.create(null, null, marks))
    if (part.length > 0) nodes.push(schema.text(part, marks))
  }
  return nodes
}

const CLIPBOARD_BLOCKS = 'p, div, li, blockquote, h1, h2, h3, h4, h5, h6, tr'

function clipboardInlineHtml(html: string): string {
  // The textbox schema has one inline document. ProseMirror otherwise drops
  // external paragraph wrappers and joins their text without a line break.
  const template = document.createElement('template')
  template.innerHTML = html
  const root = template.content
  for (const metadata of root.querySelectorAll('meta, script, style, link, head, title')) {
    metadata.remove()
  }
  const meaningfulSibling = (node: Node, direction: 'nextSibling' | 'previousSibling'): Node | null => {
    for (let current: Node | null = node; current !== null && current !== root; current = current.parentNode) {
      let sibling = current[direction]
      while (
        sibling?.nodeType === Node.COMMENT_NODE ||
        (sibling?.nodeType === Node.TEXT_NODE && !sibling.textContent?.trim())
      ) {
        sibling = sibling[direction]
      }
      if (sibling !== null) return sibling
    }
    return null
  }
  const endsWithBreak = (node: Node): boolean => {
    let last: Node | null = node
    while (last !== null && last.nodeType !== Node.TEXT_NODE) {
      if (last instanceof HTMLElement && last.tagName === 'BR') return true
      last = last.lastChild
    }
    return false
  }
  for (const block of [...root.querySelectorAll(CLIPBOARD_BLOCKS)].reverse()) {
    for (const direction of ['previousSibling', 'nextSibling'] as const) {
      while (block[direction]?.nodeType === Node.TEXT_NODE && !block[direction]?.textContent?.trim()) {
        block[direction]?.parentNode?.removeChild(block[direction]!)
      }
    }
    const before = meaningfulSibling(block, 'previousSibling')
    if (
      before !== null &&
      !(before instanceof HTMLElement && before.matches(CLIPBOARD_BLOCKS)) &&
      !endsWithBreak(before)
    ) {
      block.prepend(document.createElement('br'))
    }
    if (meaningfulSibling(block, 'nextSibling') !== null && !endsWithBreak(block)) {
      block.append(document.createElement('br'))
    }
    block.replaceWith(...block.childNodes)
  }
  return template.innerHTML
}

function inlineStyleFromMarks(marks: readonly Mark[]): DrawingInlineStyle {
  // Marks describe the effective boolean format. Their absence must mean
  // false, including when the box's saved base style is true.
  const result: DrawingInlineStyle = booleanStyle({})
  for (const mark of marks) {
    if (mark.type.name === 'color') result.color = mark.attrs.color
    else if (mark.type.name === 'fontSize') result.fontSizePt = mark.attrs.pt
    else if (mark.type.name === 'strong') result.bold = true
    else if (mark.type.name === 'em') result.italic = true
    else if (mark.type.name === 'underline') result.underline = true
    else if (mark.type.name === 'strike') result.strike = true
  }
  return result
}

function serializeDoc(doc: ProseNode, base: DrawingStyle): { text: string; runs: DrawingTextRun[] } {
  let text = ''
  const runs: DrawingTextRun[] = []
  doc.forEach((node) => {
    const value = node.type.name === 'hard_break' ? '\n' : node.text
    if (value === undefined) return
    const from = text.length
    text += value
    const style = inlineStyleFromMarks(node.marks)
    for (const field of ['bold', 'italic', 'underline', 'strike'] as const) {
      if (style[field] === (base[field] === true)) delete style[field]
    }
    if (Object.keys(style).length > 0) {
      const previous = runs.at(-1)
      const to = text.length
      const same = previous !== undefined &&
        INLINE_FIELDS.every((key) => previous.style[key] === style[key])
      if (same && previous.to === from) previous.to = to
      else runs.push({ from, to, style })
    }
  })
  return { text, runs }
}

function markForField(schema: Schema, field: keyof DrawingInlineStyle): MarkType {
  if (field === 'color') return schema.marks.color!
  if (field === 'fontSizePt') return schema.marks.fontSize!
  return schema.marks[BOOLEAN_MARKS[field]]!
}

function effectiveStyle(state: EditorState, base: DrawingStyle): DrawingStyle {
  const { from, to, empty, $from } = state.selection
  const samples: DrawingInlineStyle[] = []
  if (empty) {
    samples.push(inlineStyleFromMarks(state.storedMarks ?? $from.marks()))
  } else {
    state.doc.nodesBetween(from, to, (node) => {
      if (node.isText || node.type.name === 'hard_break') {
        samples.push(inlineStyleFromMarks(node.marks))
      }
    })
  }
  if (samples.length === 0) return base
  const merged: DrawingStyle = { ...base }
  for (const key of INLINE_FIELDS) {
    const fallback = key === 'fontSizePt'
      ? base.fontSizePt ?? (base.fontScale ?? 1) * TEXT_DEFAULT_FONT_PT
      : base[key]
    const first = samples[0]?.[key] ?? fallback
    if (samples.every((sample) => (sample[key] ?? fallback) === first)) {
      if (first === undefined) delete merged[key]
      else Object.assign(merged, { [key]: first })
    }
  }
  return merged
}

function applyInlinePatch(view: EditorView, patch: TextStylePatch): void {
  let transaction = view.state.tr
  const { from, to, empty } = view.state.selection
  for (const field of INLINE_FIELDS) {
    if (!(field in patch)) continue
    const value = patch[field]
    const markType = markForField(view.state.schema, field)
    if (empty) {
      // Keep the pre-rich-text behaviour when there is only a caret: toolbar
      // formatting applies to the whole text box. A real range selection is
      // handled by the branch below and remains character-scoped.
      if (view.state.doc.content.size > 0) {
        transaction = transaction.removeMark(0, view.state.doc.content.size, markType)
        if (value !== undefined && value !== false) {
          const attrs = field === 'color'
            ? { color: value }
            : field === 'fontSizePt' ? { pt: value } : undefined
          transaction = transaction.addMark(
            0,
            view.state.doc.content.size,
            markType.create(attrs)
          )
        }
      }
      transaction = transaction.removeStoredMark(markType)
      if (value !== undefined && value !== false) {
        const attrs = field === 'color'
          ? { color: value }
          : field === 'fontSizePt' ? { pt: value } : undefined
        transaction = transaction.addStoredMark(markType.create(attrs))
      }
    } else {
      transaction = transaction.removeMark(from, to, markType)
      if (value !== undefined && value !== false) {
        const attrs = field === 'color'
          ? { color: value }
          : field === 'fontSizePt' ? { pt: value } : undefined
        transaction = transaction.addMark(from, to, markType.create(attrs))
      }
    }
  }
  view.dispatch(transaction.scrollIntoView())
  view.focus()
}

function insertHardBreak(view: EditorView): boolean {
  const hardBreak = view.state.schema.nodes.hard_break
  if (hardBreak === undefined) return false
  const marks = view.state.storedMarks ?? view.state.selection.$from.marks()
  view.dispatch(
    view.state.tr
      .replaceSelectionWith(hardBreak.create())
      .setStoredMarks(marks)
      .scrollIntoView()
  )
  return true
}

export interface TextBoxEditorHandle {
  focus: () => void
  apply: (patch: TextStylePatch) => void
}

interface TextBoxEditorProps {
  text: string
  runs?: readonly DrawingTextRun[]
  baseStyle: DrawingStyle
  baseWidthPx: number
  surfaceWidthPt: number
  contentStyle: CSSProperties
  color: DrawingStyle['color']
  fill?: DrawingStyle['fill']
  autoFocus?: boolean
  onChange: (text: string, runs: DrawingTextRun[], scrollHeightPx: number) => void
  onSelectionStyleChange: (style: DrawingStyle) => void
  onBlur: (event: ReactFocusEvent<HTMLElement>) => void
  onCancel: () => void
  onCommit: () => void
}

export const TextBoxEditor = forwardRef<TextBoxEditorHandle, TextBoxEditorProps>(
  function TextBoxEditor(props, forwardedRef): JSX.Element {
    const {
      text,
      runs,
      baseStyle,
      baseWidthPx,
      surfaceWidthPt,
      contentStyle,
      color,
      fill,
      autoFocus = false,
      onChange,
      onSelectionStyleChange,
      onBlur,
      onCancel,
      onCommit
    } = props
    const hostRef = useRef<HTMLDivElement>(null)
    const viewRef = useRef<EditorView | null>(null)
    const callbacksRef = useRef({ onChange, onSelectionStyleChange, onBlur, onCancel, onCommit })
    callbacksRef.current = { onChange, onSelectionStyleChange, onBlur, onCancel, onCommit }
    const baseStyleRef = useRef(baseStyle)
    baseStyleRef.current = baseStyle
    const widthRef = useRef({ baseWidthPx, surfaceWidthPt })
    widthRef.current = { baseWidthPx, surfaceWidthPt }
    const schema = useMemo(createSchema, [])

    const refreshFontSizes = (): void => {
      const root = hostRef.current
      if (root === null) return
      for (const node of root.querySelectorAll<HTMLElement>('[data-font-size-pt]')) {
        const pt = Number(node.dataset.fontSizePt)
        node.style.fontSize = `${textBoxFontPx(
          widthRef.current.baseWidthPx,
          undefined,
          pt,
          widthRef.current.surfaceWidthPt
        )}px`
      }
    }

    useImperativeHandle(forwardedRef, () => ({
      focus: () => viewRef.current?.focus(),
      apply: (patch) => {
        const view = viewRef.current
        if (view !== null) applyInlinePatch(view, patch)
      }
    }), [])

    useLayoutEffect(() => refreshFontSizes(), [baseWidthPx, surfaceWidthPt])

    useLayoutEffect(() => {
      const host = hostRef.current
      if (host === null) return
      const intrinsicHeight = (): number => {
        // The visible editor fills the foreignObject so its background, hit
        // area and selection frame never diverge. Measure content by briefly
        // releasing that inherited height, then restore it in the same frame.
        const previousHeight = host.style.height
        host.style.height = 'auto'
        const height = host.getBoundingClientRect().height
        host.style.height = previousHeight
        return height
      }
      const emit = (view: EditorView, changed: boolean): void => {
        refreshFontSizes()
        callbacksRef.current.onSelectionStyleChange(
          effectiveStyle(view.state, baseStyleRef.current)
        )
        if (!changed) return
        const serialized = serializeDoc(view.state.doc, baseStyleRef.current)
        // Commit/blur can follow the final keystroke immediately (especially
        // ⌘Enter). Publishing on the next frame made the parent commit its
        // previous, sometimes still-empty draft even though the glyphs were
        // already visible in ProseMirror.
        callbacksRef.current.onChange(
          serialized.text,
          serialized.runs,
          intrinsicHeight()
        )
      }
      const view = new EditorView(host, {
        state: EditorState.create({
          schema,
          doc: initialDoc(schema, text, runs, baseStyleRef.current),
          plugins: [
            history(),
            keymap({
              'Mod-z': undo,
              'Shift-Mod-z': redo,
              'Mod-y': redo,
              'Mod-b': toggleMark(schema.marks.strong!),
              'Mod-i': toggleMark(schema.marks.em!),
              'Mod-u': toggleMark(schema.marks.underline!),
              Enter: (_state, _dispatch, view) =>
                view === undefined ? false : insertHardBreak(view),
              'Shift-Enter': (_state, _dispatch, view) =>
                view === undefined ? false : insertHardBreak(view)
            })
          ]
        }),
        dispatchTransaction: (transaction: Transaction) => {
          const next = view.state.apply(transaction)
          view.updateState(next)
          emit(view, transaction.docChanged)
        },
        clipboardTextParser: (value, $context, _plain, currentView) => new Slice(
          Fragment.from(textNodes(
            schema,
            value.replace(/\r\n?/g, '\n'),
            currentView.state.storedMarks ?? $context.marks()
          )),
          0,
          0
        ),
        transformPastedHTML: clipboardInlineHtml,
        handleKeyDown: (currentView, event) => {
          if (event.key === 'Escape') {
            event.preventDefault()
            callbacksRef.current.onCancel()
            currentView.dom.blur()
            return true
          }
          if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
            event.preventDefault()
            callbacksRef.current.onCommit()
            currentView.dom.blur()
            return true
          }
          if ((event.metaKey || event.ctrlKey) && ['+', '=', '-'].includes(event.key)) {
            event.preventDefault()
            const current = effectiveStyle(currentView.state, baseStyleRef.current)
            const point = current.fontSizePt ??
              (current.fontScale ?? 1) * TEXT_DEFAULT_FONT_PT
            const steps = [6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96]
            const closest = steps.reduce((best, candidate) =>
              Math.abs(candidate - point) < Math.abs(best - point) ? candidate : best)
            const index = steps.indexOf(closest)
            const next = steps[Math.max(0, Math.min(steps.length - 1, index + (event.key === '-' ? -1 : 1)))]
            applyInlinePatch(currentView, { fontScale: undefined, fontSizePt: next })
            return true
          }
          return false
        },
        handleDOMEvents: {
          blur: (_view, event) => {
            callbacksRef.current.onBlur(event as unknown as ReactFocusEvent<HTMLElement>)
            return false
          },
          pointerdown: (_view, event) => {
            event.stopPropagation()
            return false
          }
        }
      })
      viewRef.current = view
      // Chromium does not consistently expose a contenteditable nested in an
      // SVG foreignObject as a textbox unless its ARIA role is explicit.
      view.dom.setAttribute('role', 'textbox')
      view.dom.setAttribute('aria-label', '텍스트 입력')
      view.dom.setAttribute('aria-multiline', 'true')
      view.dom.setAttribute('data-placeholder', '텍스트를 입력하세요')
      view.dom.classList.add('ink-layer__textbox-editor-content')
      const end = view.state.doc.content.size
      const selection = view.state.tr.setSelection(TextSelection.create(view.state.doc, end))
      if (end === 0) selection.setStoredMarks(marksForStyle(schema, booleanStyle(baseStyleRef.current)))
      view.dispatch(selection)
      emit(view, false)
      // Focus before the pointer event finishes so immediate typing reaches
      // this editor rather than the page or a previous text box.
      if (autoFocus) view.focus()
      requestAnimationFrame(() => {
        if (viewRef.current !== view) return
        // The editor host sizes itself to its content instead of inheriting
        // the old foreignObject height. Publish that first intrinsic measure
        // so opening an existing box also removes stale extra whitespace.
        emit(view, true)
      })
      return () => {
        viewRef.current = null
        view.destroy()
      }
      // The editor owns its draft until it unmounts; current props are exposed
      // through refs so zoom/style changes do not destroy the user's selection.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [schema])

    // Boolean typography lives on marks so removing a mark also removes
    // formatting inherited from the saved box style.
    return (
      <div
        ref={hostRef}
        className="ink-layer__textbox ink-layer__textbox-editor is-editing"
        data-color={color}
        {...(fill === undefined ? {} : { 'data-fill': fill })}
        style={{ ...contentStyle, fontWeight: 400, fontStyle: 'normal', textDecoration: 'none' }}
      />
    )
  }
)
