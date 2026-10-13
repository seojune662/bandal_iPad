/**
 * `[[` 피커 — mentionMenuPlugin 의 구조(상태 추적·키보드·body 포탈 메뉴)를
 * 그대로 따르되:
 * - 트리거가 `[[` (두 번째 `[` 입력 시) 이고 쿼리에 공백을 허용한다
 *   (`[[강의 1]]` 처럼 대상 이름에 공백이 흔하다).
 * - 항목은 wikilinkResolverStore 의 과목별 캐시에서 온다.
 * - Enter/클릭은 wikilink 노드 + 공백을 삽입하고 `[[쿼리` 를 지운다.
 *   일치 항목이 없으면 쿼리를 그대로 대상으로 삼는 미해결 링크를 넣는다.
 * - `]]` 를 직접 닫아도 같은 노드로 승격한다 — 평문 `[[x]]` 는 저장 시
 *   `\[\[x]]` 로 이스케이프되어 다음 열기에서 링크가 아니게 되기 때문.
 */

import { Plugin, PluginKey } from '@milkdown/prose/state'
import type { EditorView } from '@milkdown/prose/view'
import {
  isNoteRelPath,
  parseWikilink,
  wikilinkStem,
  type WikilinkParts
} from '../../../../../shared/wikilink'
import {
  filterLinkPickerFiles,
  type LinkPickerFile
} from '../../links/LinkPickerDialog'
import { WIKILINK_NODE } from './wikilinkSchema'
import {
  loadWikilinkFiles,
  resolveWikilink,
  wikilinkFilesSync
} from './wikilinkResolverStore'

interface InactiveWikilinkMenuState {
  active: false
}

interface ActiveWikilinkMenuState {
  active: true
  /** Position of the first `[`. */
  from: number
  query: string
  selected: number
}

export type WikilinkMenuState =
  | InactiveWikilinkMenuState
  | ActiveWikilinkMenuState

type WikilinkMenuMeta =
  | { type: 'open'; from: number }
  | { type: 'close' }
  | { type: 'move'; delta: number }
  | { type: 'files-loaded' }

const INACTIVE_STATE: WikilinkMenuState = { active: false }
const TRIGGER = '[['

export const wikilinkMenuKey = new PluginKey<WikilinkMenuState>(
  'note-wikilink-menu'
)

/** The second `[` of `[[` opens the picker. */
export function isWikilinkTrigger(precedingChar: string, text: string): boolean {
  return text === '[' && precedingChar === '['
}

/**
 * A query ends when it can no longer be a wikilink target: a line break,
 * a nested `[`, or a `]` anywhere but the very end (the pending first half
 * of a manual `]]`).
 */
export function wikilinkQueryEnds(query: string): boolean {
  if (/[\n\r[]/u.test(query)) return true
  const firstClose = query.indexOf(']')
  return firstClose !== -1 && firstClose !== query.length - 1
}

/** True when the query already holds the first `]` of a manual `]]`. */
export function wikilinkQueryAwaitsClose(query: string): boolean {
  return query.endsWith(']')
}

/**
 * Shortest target that still resolves to this file: the stem for notes and
 * the file name for anything else, falling back to the full path when
 * another file shares the name.
 */
export function wikilinkTargetFor(
  file: LinkPickerFile,
  resolve: (target: string) => string | null
): string {
  const short = isNoteRelPath(file.relPath) ? wikilinkStem(file.relPath) : file.name
  if (resolve(short) === file.relPath) return short
  return isNoteRelPath(file.relPath)
    ? file.relPath.replace(/\.(?:md|markdown)$/iu, '')
    : file.relPath
}

export interface WikilinkPickerOptions {
  courseId: string
  getSelfRelPath: () => string
}

export function createWikilinkPickerPlugin(
  options: WikilinkPickerOptions
): Plugin<WikilinkMenuState> {
  let loadSequence = 0

  function files(): readonly LinkPickerFile[] | null {
    return wikilinkFilesSync(options.courseId)
  }

  function visibleFiles(query: string): LinkPickerFile[] {
    const loaded = files()
    if (loaded === null) return []
    return filterLinkPickerFiles(loaded, options.getSelfRelPath(), query.trim())
  }

  function loadFiles(view: EditorView): void {
    const current = ++loadSequence
    void loadWikilinkFiles(options.courseId).finally(() => {
      if (current !== loadSequence) return
      const state = wikilinkMenuKey.getState(view.state)
      if (state?.active === true) {
        view.dispatch(
          view.state.tr.setMeta(wikilinkMenuKey, {
            type: 'files-loaded'
          } satisfies WikilinkMenuMeta)
        )
      }
    })
  }

  function insertWikilink(
    view: EditorView,
    from: number,
    to: number,
    parts: WikilinkParts
  ): boolean {
    const schema = view.state.schema
    const nodeType = schema.nodes[WIKILINK_NODE]
    if (nodeType === undefined) return false
    const node = nodeType.create({ ...parts })
    // 노드 뒤에 공백을 붙여 이어지는 입력이 바로 다음 문자로 이어지게 한다.
    const trailing = schema.text(' ')
    let tr = view.state.tr.delete(from, to)
    tr = tr.insert(from, [node, trailing])
    tr = tr.setMeta(wikilinkMenuKey, { type: 'close' } satisfies WikilinkMenuMeta)
    view.dispatch(tr)
    view.focus()
    return true
  }

  function executeItem(
    view: EditorView,
    state: ActiveWikilinkMenuState,
    selected: number
  ): boolean {
    const items = visibleFiles(state.query)
    const item = items[selected]
    const to = view.state.selection.from
    if (item !== undefined) {
      const target = wikilinkTargetFor(item, (candidate) =>
        resolveWikilink(options.courseId, candidate)
      )
      return insertWikilink(view, state.from, to, {
        target,
        heading: null,
        alias: null,
        embed: false
      })
    }
    // 일치 항목 없음: 입력한 이름 그대로 미해결 링크를 만든다 (클릭 시 노트 생성).
    const parts = parseWikilink(`${TRIGGER}${state.query.replace(/\]$/u, '')}]]`)
    if (parts === null) return false
    return insertWikilink(view, state.from, to, parts)
  }

  function closeMenu(view: EditorView): void {
    view.dispatch(
      view.state.tr.setMeta(wikilinkMenuKey, {
        type: 'close'
      } satisfies WikilinkMenuMeta)
    )
  }

  return new Plugin<WikilinkMenuState>({
    key: wikilinkMenuKey,
    state: {
      init: () => INACTIVE_STATE,
      apply: (transaction, previous, _oldState, newState) => {
        const meta = transaction.getMeta(wikilinkMenuKey) as
          | WikilinkMenuMeta
          | undefined
        if (meta?.type === 'open') {
          return { active: true, from: meta.from, query: '', selected: 0 }
        }
        if (meta?.type === 'close') return INACTIVE_STATE
        if (!previous.active) return previous
        if (meta?.type === 'files-loaded') return { ...previous }

        if (meta?.type === 'move') {
          const count = visibleFiles(previous.query).length
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
          selection.$from.start() > from
        ) {
          return INACTIVE_STATE
        }

        const text = newState.doc.textBetween(from, cursor, '\n', '\n')
        if (!text.startsWith(TRIGGER)) return INACTIVE_STATE
        const query = text.slice(TRIGGER.length)
        if (wikilinkQueryEnds(query)) return INACTIVE_STATE
        const count = visibleFiles(query).length
        return {
          active: true,
          from,
          query,
          selected: count === 0 ? 0 : Math.min(previous.selected, count - 1)
        }
      }
    },
    props: {
      handleTextInput: (view, from, to, text) => {
        if (from !== to || view.composing) return false
        const active = wikilinkMenuKey.getState(view.state)

        // 수동 `]]`: 두 번째 `]` 가 오면 평문 대신 노드로 승격한다.
        if (active?.active === true && text === ']') {
          if (!wikilinkQueryAwaitsClose(active.query)) return false
          const parts = parseWikilink(`${TRIGGER}${active.query.slice(0, -1)}]]`)
          if (parts === null) {
            closeMenu(view)
            return false
          }
          return insertWikilink(view, active.from, to, parts)
        }

        if (text !== '[') return false
        const { selection } = view.state
        if (
          selection.from !== from ||
          !selection.empty ||
          selection.$from.parent.type.name !== 'paragraph'
        ) {
          return false
        }
        const paragraphStart = selection.$from.start()
        const preceding =
          from > paragraphStart
            ? view.state.doc.textBetween(from - 1, from, '\n', '\n')
            : ''
        if (!isWikilinkTrigger(preceding, text)) return false

        view.dispatch(
          view.state.tr
            .insertText('[', from, to)
            .setMeta(wikilinkMenuKey, {
              type: 'open',
              from: from - 1
            } satisfies WikilinkMenuMeta)
        )
        loadFiles(view)
        return true
      },
      handleKeyDown: (view, event) => {
        const state = wikilinkMenuKey.getState(view.state)
        if (state === undefined || !state.active || event.isComposing) {
          return false
        }

        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault()
          view.dispatch(
            view.state.tr.setMeta(wikilinkMenuKey, {
              type: 'move',
              delta: event.key === 'ArrowDown' ? 1 : -1
            } satisfies WikilinkMenuMeta)
          )
          return true
        }
        if (event.key === 'Enter') {
          if (state.query.trim().length === 0 && visibleFiles('').length === 0) {
            closeMenu(view)
            return false
          }
          event.preventDefault()
          return executeItem(view, state, state.selected)
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          closeMenu(view)
          return true
        }
        return false
      }
    },
    view: (editorView) => {
      const menu = document.createElement('div')
      menu.className = 'note-slash-menu note-wikilink-menu'
      menu.setAttribute('role', 'listbox')
      menu.setAttribute('aria-label', '위키링크 대상')
      menu.hidden = true
      document.body.append(menu)

      const render = (view: EditorView): void => {
        const state = wikilinkMenuKey.getState(view.state)
        if (state === undefined || !state.active) {
          menu.hidden = true
          return
        }

        menu.hidden = false
        const children: HTMLElement[] = []
        if (files() === null) {
          const status = document.createElement('div')
          status.className = 'note-slash-menu__empty'
          status.textContent = '자료 불러오는 중…'
          children.push(status)
        } else {
          const items = visibleFiles(state.query)
          for (const [index, item] of items.entries()) {
            const option = document.createElement('button')
            const label = document.createElement('span')
            const description = document.createElement('span')
            option.type = 'button'
            option.className = 'note-slash-menu__item'
            option.dataset['wikilinkIndex'] = String(index)
            option.setAttribute('role', 'option')
            option.setAttribute('aria-selected', String(index === state.selected))
            label.className = 'note-slash-menu__label'
            label.textContent = item.name
            description.className = 'note-slash-menu__description'
            description.textContent = item.relPath
            option.append(label, description)
            children.push(option)
          }
          if (items.length === 0) {
            const empty = document.createElement('div')
            empty.className = 'note-slash-menu__empty'
            empty.textContent =
              state.query.trim().length === 0
                ? '일치하는 자료가 없습니다.'
                : `Enter — "${state.query.trim()}" 새 노트 링크 만들기`
            children.push(empty)
          }
        }
        menu.replaceChildren(...children)

        const coordinates = view.coordsAtPos(view.state.selection.from)
        menu.style.left = `${coordinates.left}px`
        menu.style.top = `${coordinates.bottom}px`
      }

      const handleMouseDown = (event: MouseEvent): void => {
        const target = event.target
        if (!(target instanceof Element)) return
        const option = target.closest<HTMLElement>('[data-wikilink-index]')
        const selected = Number(option?.dataset['wikilinkIndex'])
        const state = wikilinkMenuKey.getState(editorView.state)
        if (state === undefined || !state.active || !Number.isInteger(selected)) {
          return
        }
        event.preventDefault()
        executeItem(editorView, state, selected)
      }

      menu.addEventListener('mousedown', handleMouseDown)
      render(editorView)
      return {
        update: render,
        destroy: () => {
          menu.removeEventListener('mousedown', handleMouseDown)
          menu.remove()
        }
      }
    }
  })
}
