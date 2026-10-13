import type { EditorState } from '@milkdown/prose/state'
import type { EditorView } from '@milkdown/prose/view'

export interface NoteFormatState {
  paragraph: boolean
  headingLevel: number | null
  strong: boolean
  emphasis: boolean
  strikethrough: boolean
  bulletList: boolean
  orderedList: boolean
  taskList: boolean
  blockquote: boolean
  link: boolean
  linkHref: string | null
  inlineCode: boolean
  codeBlock: boolean
  codeBlockPosition: number | null
  codeBlockLanguage: string
}

export const EMPTY_NOTE_FORMAT_STATE: NoteFormatState = {
  paragraph: false,
  headingLevel: null,
  strong: false,
  emphasis: false,
  strikethrough: false,
  bulletList: false,
  orderedList: false,
  taskList: false,
  blockquote: false,
  link: false,
  linkHref: null,
  inlineCode: false,
  codeBlock: false,
  codeBlockPosition: null,
  codeBlockLanguage: ''
}

function activeMark(state: EditorState, name: string): boolean {
  const type = state.schema.marks[name]
  if (type === undefined) return false

  const { empty, $from, from, to } = state.selection
  if (!empty) return state.doc.rangeHasMark(from, to, type)
  return type.isInSet(state.storedMarks ?? $from.marks()) !== undefined
}

function activeMarkAttribute(
  state: EditorState,
  name: string,
  attribute: string
): string | null {
  const type = state.schema.marks[name]
  if (type === undefined) return null

  const { $from } = state.selection
  const mark = type.isInSet(state.storedMarks ?? $from.marks())
  const value = mark?.attrs[attribute]
  return typeof value === 'string' ? value : null
}

function ancestorDepth(state: EditorState, name: string): number | null {
  const { $from } = state.selection
  for (let depth = $from.depth; depth >= 0; depth -= 1) {
    if ($from.node(depth).type.name === name) return depth
  }
  return null
}

export function getNoteFormatState(state: EditorState): NoteFormatState {
  const { $from } = state.selection
  const headingDepth = ancestorDepth(state, 'heading')
  const heading = headingDepth === null ? null : $from.node(headingDepth)
  const listItemDepth = ancestorDepth(state, 'list_item')
  const listItem = listItemDepth === null ? null : $from.node(listItemDepth)
  const codeBlockDepth = ancestorDepth(state, 'code_block')
  const codeBlock = codeBlockDepth === null ? null : $from.node(codeBlockDepth)

  return {
    paragraph: ancestorDepth(state, 'paragraph') !== null,
    headingLevel:
      heading !== null && typeof heading.attrs['level'] === 'number'
        ? heading.attrs['level']
        : null,
    strong: activeMark(state, 'strong'),
    emphasis: activeMark(state, 'emphasis'),
    strikethrough: activeMark(state, 'strike_through'),
    bulletList: ancestorDepth(state, 'bullet_list') !== null,
    orderedList: ancestorDepth(state, 'ordered_list') !== null,
    taskList: typeof listItem?.attrs['checked'] === 'boolean',
    blockquote: ancestorDepth(state, 'blockquote') !== null,
    link: activeMark(state, 'link'),
    linkHref: activeMarkAttribute(state, 'link', 'href'),
    inlineCode: activeMark(state, 'inlineCode'),
    codeBlock: codeBlock !== null,
    codeBlockPosition:
      codeBlockDepth !== null && codeBlockDepth > 0
        ? $from.before(codeBlockDepth)
        : null,
    codeBlockLanguage:
      codeBlock !== null && typeof codeBlock.attrs['language'] === 'string'
        ? codeBlock.attrs['language']
        : ''
  }
}

function selectedListItemPositions(state: EditorState): number[] {
  const positions = new Set<number>()
  const { $from, from, to } = state.selection

  for (let depth = $from.depth; depth > 0; depth -= 1) {
    if ($from.node(depth).type.name === 'list_item') {
      positions.add($from.before(depth))
      break
    }
  }

  state.doc.nodesBetween(from, to, (node, position) => {
    if (node.type.name === 'list_item') positions.add(position)
  })

  return [...positions].sort((left, right) => left - right)
}

/** Toggles the selected GFM list items between tasks and ordinary list items. */
export function toggleTaskListItems(view: EditorView): boolean {
  const positions = selectedListItemPositions(view.state)
  if (positions.length === 0) return false

  const allTasks = positions.every((position) => {
    const node = view.state.doc.nodeAt(position)
    return typeof node?.attrs['checked'] === 'boolean'
  })
  const checked = allTasks ? null : false
  let transaction = view.state.tr

  for (const position of positions) {
    const node = transaction.doc.nodeAt(position)
    if (node === null || node.type.name !== 'list_item') continue
    transaction = transaction.setNodeMarkup(position, undefined, {
      ...node.attrs,
      checked
    })
  }

  if (!transaction.docChanged) return false
  view.dispatch(transaction.scrollIntoView())
  return true
}
