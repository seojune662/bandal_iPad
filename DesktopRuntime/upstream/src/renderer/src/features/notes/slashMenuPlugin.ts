import { placeFixedMenu } from '../../lib/placeFixedMenu'
import type { Ctx } from '@milkdown/ctx'
import {
  createCodeBlockCommand,
  insertHrCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInHeadingCommand,
  wrapInOrderedListCommand
} from '@milkdown/preset-commonmark'
import { insertTableCommand } from '@milkdown/preset-gfm'
import { Plugin, PluginKey } from '@milkdown/prose/state'
import type { EditorView } from '@milkdown/prose/view'
import { Decoration, DecorationSet } from '@milkdown/prose/view'
import { $prose, callCommand } from '@milkdown/utils'
import { wrapInCalloutCommand } from './callout'
import { toggleTaskListItems } from './noteFormatting'

export type SlashMenuCommand =
  | 'heading-1'
  | 'heading-2'
  | 'heading-3'
  | 'bullet-list'
  | 'ordered-list'
  | 'task-list'
  | 'blockquote'
  | 'callout'
  | 'page'
  | 'link'
  | 'image'
  | 'code-block'
  | 'horizontal-rule'
  | 'table'

export interface SlashMenuItem {
  command: SlashMenuCommand
  label: string
  description: string
  keywords: readonly string[]
}

export type NoteSlashToolbarAction = 'link' | 'image'
  | 'page'

export const NOTE_SLASH_TOOLBAR_ACTION_EVENT =
  'bandal:note-slash-toolbar-action'

export const SLASH_MENU_ITEMS: readonly SlashMenuItem[] = [
  {
    command: 'heading-1',
    label: '제목 1',
    description: '큰 제목',
    keywords: ['h1', 'heading', 'title']
  },
  {
    command: 'heading-2',
    label: '제목 2',
    description: '중간 제목',
    keywords: ['h2', 'heading', 'subtitle']
  },
  {
    command: 'heading-3',
    label: '제목 3',
    description: '작은 제목',
    keywords: ['h3', 'heading']
  },
  {
    command: 'bullet-list',
    label: '글머리 목록',
    description: '순서 없는 목록',
    keywords: ['bullet', 'list', 'ul']
  },
  {
    command: 'ordered-list',
    label: '번호 목록',
    description: '순서 있는 목록',
    keywords: ['number', 'ordered', 'list', 'ol']
  },
  {
    command: 'task-list',
    label: '할 일 목록',
    description: '체크할 수 있는 목록',
    keywords: ['task', 'todo', 'check', 'checklist']
  },
  {
    command: 'blockquote',
    label: '인용',
    description: '인용 블록',
    keywords: ['quote', 'blockquote']
  },
  {
    command: 'callout',
    label: '콜아웃',
    description: '접을 수 있는 강조 메모',
    keywords: ['callout', 'admonition', 'note', 'tip', 'warning', '콜아웃', '메모']
  },
  {
    command: 'page',
    label: '새 페이지',
    description: '이 노트 안에 하위 페이지 만들기',
    keywords: ['page', 'new', 'note', '페이지', '노트']
  },
  {
    command: 'link',
    label: '링크',
    description: '선택한 텍스트에 URL 연결',
    keywords: ['link', 'url', 'href']
  },
  {
    command: 'image',
    label: '이미지',
    description: '과목 assets 폴더에 이미지 삽입',
    keywords: ['image', 'picture', 'photo']
  },
  {
    command: 'code-block',
    label: '코드 블록',
    description: '여러 줄 코드',
    keywords: ['code', 'pre']
  },
  {
    command: 'horizontal-rule',
    label: '구분선',
    description: '내용 구분선',
    keywords: ['divider', 'rule', 'hr']
  },
  {
    command: 'table',
    label: '표',
    description: '3 × 3 표',
    keywords: ['table', 'grid']
  }
]

interface InactiveSlashMenuState {
  active: false
}

interface ActiveSlashMenuState {
  active: true
  from: number
  query: string
  selected: number
}

export type SlashMenuState = InactiveSlashMenuState | ActiveSlashMenuState

type SlashMenuMeta =
  | { type: 'open'; from: number }
  | { type: 'close' }
  | { type: 'move'; delta: number }

const INACTIVE_STATE: SlashMenuState = { active: false }

export const slashMenuKey = new PluginKey<SlashMenuState>('note-slash-menu')

export function filterSlashMenuItems(query: string): readonly SlashMenuItem[] {
  const normalized = query.trim().toLocaleLowerCase()
  if (normalized.length === 0) return SLASH_MENU_ITEMS
  return SLASH_MENU_ITEMS.filter((item) => {
    const searchText = [item.label, item.description, ...item.keywords]
      .join(' ')
      .toLocaleLowerCase()
    return searchText.includes(normalized)
  })
}

function executeSlashItem(
  view: EditorView,
  state: ActiveSlashMenuState,
  selected: number,
  run: (command: SlashMenuCommand, view: EditorView) => boolean
): boolean {
  const item = filterSlashMenuItems(state.query)[selected]
  if (item === undefined) return false

  view.dispatch(
    view.state.tr
      .delete(state.from, view.state.selection.from)
      .setMeta(slashMenuKey, { type: 'close' } satisfies SlashMenuMeta)
  )
  const handled = run(item.command, view)
  view.focus()
  return handled
}

function slashMenuDecorations(state: Parameters<typeof DecorationSet.create>[0]): DecorationSet {
  const first = state.firstChild
  if (
    state.childCount !== 1 ||
    first === null ||
    first.type.name !== 'paragraph' ||
    first.content.size !== 0
  ) {
    return DecorationSet.empty
  }

  return DecorationSet.create(state, [
    Decoration.node(0, first.nodeSize, {
      class: 'note-editor-placeholder',
      'data-placeholder': '필기를 시작하세요… `/`로 블록 삽입'
    })
  ])
}

export function createSlashMenuPlugin(
  run: (command: SlashMenuCommand, view: EditorView) => boolean
): Plugin<SlashMenuState> {
  return new Plugin<SlashMenuState>({
    key: slashMenuKey,
    state: {
      init: () => INACTIVE_STATE,
      apply: (transaction, previous, _oldState, newState) => {
        const meta = transaction.getMeta(slashMenuKey) as SlashMenuMeta | undefined
        if (meta?.type === 'open') {
          return { active: true, from: meta.from, query: '', selected: 0 }
        }
        if (meta?.type === 'close') return INACTIVE_STATE
        if (!previous.active) return previous

        if (meta?.type === 'move') {
          const count = filterSlashMenuItems(previous.query).length
          if (count === 0) return previous
          return {
            ...previous,
            selected: (previous.selected + meta.delta + count) % count
          }
        }

        const from = transaction.mapping.map(previous.from, -1)
        const { selection } = newState
        const cursor = selection.from
        if (
          !selection.empty ||
          cursor < from ||
          selection.$from.parent.type.name !== 'paragraph' ||
          selection.$from.start() !== from
        ) {
          return INACTIVE_STATE
        }

        const slashText = newState.doc.textBetween(from, cursor, '\n', '\n')
        if (!slashText.startsWith('/')) return INACTIVE_STATE
        const query = slashText.slice(1)
        const count = filterSlashMenuItems(query).length
        return {
          active: true,
          from,
          query,
          selected: count === 0 ? 0 : Math.min(previous.selected, count - 1)
        }
      }
    },
    props: {
      decorations: (state) => slashMenuDecorations(state.doc),
      handleTextInput: (view, from, to, text) => {
        const { selection } = view.state
        if (
          text !== '/' ||
          from !== to ||
          selection.from !== from ||
          !selection.empty ||
          selection.$from.parent.type.name !== 'paragraph' ||
          selection.$from.parent.content.size !== 0
        ) {
          return false
        }

        view.dispatch(
          view.state.tr
            .insertText('/', from, to)
            .setMeta(slashMenuKey, { type: 'open', from } satisfies SlashMenuMeta)
        )
        return true
      },
      handleKeyDown: (view, event) => {
        const state = slashMenuKey.getState(view.state)
        if (state === undefined || !state.active || event.isComposing) return false

        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault()
          view.dispatch(
            view.state.tr.setMeta(slashMenuKey, {
              type: 'move',
              delta: event.key === 'ArrowDown' ? 1 : -1
            } satisfies SlashMenuMeta)
          )
          return true
        }
        if (event.key === 'Enter') {
          event.preventDefault()
          return executeSlashItem(view, state, state.selected, run)
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          view.dispatch(
            view.state.tr.setMeta(slashMenuKey, {
              type: 'close'
            } satisfies SlashMenuMeta)
          )
          return true
        }
        return false
      }
    },
    view: (editorView) => {
      const menu = document.createElement('div')
      menu.className = 'note-slash-menu'
      menu.setAttribute('role', 'listbox')
      menu.setAttribute('aria-label', '블록 삽입')
      menu.hidden = true
      document.body.append(menu)

      const render = (view: EditorView): void => {
        const state = slashMenuKey.getState(view.state)
        if (state === undefined || !state.active) {
          menu.hidden = true
          return
        }

        menu.hidden = false
        const items = filterSlashMenuItems(state.query)
        const children: HTMLElement[] = items.map((item, index) => {
          const option = document.createElement('button')
          const label = document.createElement('span')
          const description = document.createElement('span')
          option.type = 'button'
          option.className = 'note-slash-menu__item'
          option.dataset.slashIndex = String(index)
          option.setAttribute('role', 'option')
          option.setAttribute('aria-selected', String(index === state.selected))
          label.className = 'note-slash-menu__label'
          label.textContent = item.label
          description.className = 'note-slash-menu__description'
          description.textContent = item.description
          option.append(label, description)
          return option
        })

        if (children.length === 0) {
          const empty = document.createElement('div')
          empty.className = 'note-slash-menu__empty'
          empty.textContent = '일치하는 블록이 없습니다.'
          children.push(empty)
        }
        menu.replaceChildren(...children)

        const coordinates = view.coordsAtPos(view.state.selection.from)
        placeFixedMenu(menu, coordinates.left, coordinates.bottom)
      }

      const handleMouseDown = (event: MouseEvent): void => {
        const target = event.target
        if (!(target instanceof Element)) return
        const option = target.closest<HTMLElement>('[data-slash-index]')
        const selected = Number(option?.dataset.slashIndex)
        const state = slashMenuKey.getState(editorView.state)
        if (state === undefined || !state.active || !Number.isInteger(selected)) return
        event.preventDefault()
        executeSlashItem(editorView, state, selected, run)
      }

      const onResize = () => render(editorView)
      window.addEventListener('resize', onResize)
      menu.addEventListener('mousedown', handleMouseDown)
      render(editorView)
      return {
        update: render,
        destroy: () => {
          window.removeEventListener('resize', onResize)
          menu.removeEventListener('mousedown', handleMouseDown)
          menu.remove()
        }
      }
    }
  })
}

function runSlashCommand(
  context: Ctx,
  view: EditorView,
  command: SlashMenuCommand
): boolean {
  switch (command) {
    case 'heading-1':
      return callCommand(wrapInHeadingCommand.key, 1)(context)
    case 'heading-2':
      return callCommand(wrapInHeadingCommand.key, 2)(context)
    case 'heading-3':
      return callCommand(wrapInHeadingCommand.key, 3)(context)
    case 'bullet-list':
      return callCommand(wrapInBulletListCommand.key)(context)
    case 'ordered-list':
      return callCommand(wrapInOrderedListCommand.key)(context)
    case 'task-list': {
      const wrapped = callCommand(wrapInBulletListCommand.key)(context)
      return toggleTaskListItems(view) || wrapped
    }
    case 'blockquote':
      return callCommand(wrapInBlockquoteCommand.key)(context)
    case 'callout':
      return callCommand(wrapInCalloutCommand.key, 'note')(context)
    case 'link':
    case 'image':
    case 'page':
      view.dom.dispatchEvent(
        new CustomEvent<NoteSlashToolbarAction>(
          NOTE_SLASH_TOOLBAR_ACTION_EVENT,
          {
            bubbles: true,
            detail: command
          }
        )
      )
      return true
    case 'code-block':
      return callCommand(createCodeBlockCommand.key)(context)
    case 'horizontal-rule':
      return callCommand(insertHrCommand.key)(context)
    case 'table':
      return callCommand(insertTableCommand.key, { row: 3, col: 3 })(context)
  }
}

/** Milkdown wrapper around the direct ProseMirror slash-menu plugin. */
export const slashMenu = $prose((context) =>
  createSlashMenuPlugin((command, view) => runSlashCommand(context, view, command))
)
