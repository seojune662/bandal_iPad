import { placeFixedMenu } from '../../lib/placeFixedMenu'
/**
 * `@` 멘션 — 노트 본문 어디서든 과목 자료를 검색해 마크다운 링크로 삽입한다.
 *
 * slashMenuPlugin 의 구조(상태 추적·키보드·body 포탈 메뉴)를 그대로 따르되:
 * - 트리거가 `@` 이고, 빈 문단 제한 없이 "문단 시작 또는 공백 뒤"에서 열린다
 *   (이메일 주소 한가운데의 @ 는 무시).
 * - 항목이 정적 배열이 아니라 materials:tree 비동기 로드다.
 * - 선택하면 `[파일명](bandal://material?path=…)` 링크 텍스트를 삽입한다.
 *   클릭 네비게이션(materialLinkNavigation)과 백링크 인덱싱(linkIndex)은
 *   이 포맷을 이미 처리하므로 여기서 links:create 를 부르지 않는다 —
 *   멘션은 참조이지 순서 연결이 아니다.
 *
 * 팩토리 클로저가 에디터 인스턴스별 상태(파일 목록)를 들고 있으므로
 * NoteTab 의 prosePluginsCtx 경로로 에디터마다 새로 만들어 등록한다.
 */

import { Plugin, PluginKey } from '@milkdown/prose/state'
import type { EditorView } from '@milkdown/prose/view'
import { invoke } from '../../lib/ipc'
import {
  filterLinkPickerFiles,
  flattenMaterialFiles,
  type LinkPickerFile
} from '../links/LinkPickerDialog'

interface InactiveMentionState {
  active: false
}

interface ActiveMentionState {
  active: true
  from: number
  query: string
  selected: number
}

export type MentionMenuState = InactiveMentionState | ActiveMentionState

type MentionMenuMeta =
  | { type: 'open'; from: number }
  | { type: 'close' }
  | { type: 'move'; delta: number }
  | { type: 'files-loaded' }

const INACTIVE_STATE: MentionMenuState = { active: false }

export const mentionMenuKey = new PluginKey<MentionMenuState>(
  'note-mention-menu'
)

/** `main/features/link/materialLink.ts:createMaterialLink` 의 path-only 미러. */
export function mentionHref(relPath: string): string {
  const encoded = encodeURIComponent(relPath).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  )
  return `bandal://material?path=${encoded}`
}

/** 문단 시작이거나 바로 앞이 공백일 때만 멘션을 연다 (이메일 오탐 방지). */
export function canOpenMentionAt(
  precedingChar: string
): boolean {
  return precedingChar === '' || /\s/u.test(precedingChar)
}

/** 쿼리에 공백이 들어오면 일반 문장으로 보고 닫는다. */
export function mentionQueryEnds(query: string): boolean {
  return /\s/u.test(query)
}

export interface MentionMenuOptions {
  courseId: string
  /** rename 이후에도 자기 자신을 제외할 수 있게 ref 로 받는다. */
  getSelfRelPath: () => string
}

export function createMentionMenuPlugin(
  options: MentionMenuOptions
): Plugin<MentionMenuState> {
  // 에디터 인스턴스별 파일 캐시 — open 때마다 새로 불러온다.
  let files: LinkPickerFile[] | null = null
  let loading = false
  let loadSequence = 0

  function visibleFiles(query: string): LinkPickerFile[] {
    if (files === null) return []
    return filterLinkPickerFiles(files, options.getSelfRelPath(), query)
  }

  function loadFiles(view: EditorView): void {
    if (loading) return
    loading = true
    const current = ++loadSequence
    void invoke('materials:tree', { courseId: options.courseId })
      .then((tree) => {
        if (current !== loadSequence) return
        files = flattenMaterialFiles(tree)
      })
      .catch((caught: unknown) => {
        if (current !== loadSequence) return
        console.error('[Bandal] 멘션할 자료 목록을 불러오지 못했습니다.', caught)
        files = []
      })
      .finally(() => {
        if (current !== loadSequence) return
        loading = false
        // 로드 완료를 상태 변화로 알려 메뉴를 다시 그리게 한다.
        const state = mentionMenuKey.getState(view.state)
        if (state?.active === true) {
          view.dispatch(
            view.state.tr.setMeta(mentionMenuKey, {
              type: 'files-loaded'
            } satisfies MentionMenuMeta)
          )
        }
      })
  }

  function executeMentionItem(
    view: EditorView,
    state: ActiveMentionState,
    selected: number
  ): boolean {
    const item = visibleFiles(state.query)[selected]
    if (item === undefined) return false

    const schema = view.state.schema
    const linkType = schema.marks['link']
    const label = schema.text(
      item.name,
      linkType === undefined
        ? undefined
        : [linkType.create({ href: mentionHref(item.relPath) })]
    )
    // 링크 뒤에 마크 없는 공백을 붙여 이어지는 입력이 링크에 물들지 않게 한다.
    const trailing = schema.text(' ')

    let tr = view.state.tr.delete(state.from, view.state.selection.from)
    tr = tr.insert(state.from, [label, trailing])
    tr = tr.setMeta(mentionMenuKey, { type: 'close' } satisfies MentionMenuMeta)
    view.dispatch(tr)
    view.focus()
    return true
  }

  return new Plugin<MentionMenuState>({
    key: mentionMenuKey,
    state: {
      init: () => INACTIVE_STATE,
      apply: (transaction, previous, _oldState, newState) => {
        const meta = transaction.getMeta(mentionMenuKey) as
          | MentionMenuMeta
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

        const mentionText = newState.doc.textBetween(from, cursor, '\n', '\n')
        if (!mentionText.startsWith('@')) return INACTIVE_STATE
        const query = mentionText.slice(1)
        if (mentionQueryEnds(query)) return INACTIVE_STATE
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
        if (text !== '@' || from !== to || view.composing) return false
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
        if (!canOpenMentionAt(preceding)) return false

        view.dispatch(
          view.state.tr
            .insertText('@', from, to)
            .setMeta(mentionMenuKey, {
              type: 'open',
              from
            } satisfies MentionMenuMeta)
        )
        files = null
        loadFiles(view)
        return true
      },
      handleKeyDown: (view, event) => {
        const state = mentionMenuKey.getState(view.state)
        if (state === undefined || !state.active || event.isComposing) {
          return false
        }

        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault()
          view.dispatch(
            view.state.tr.setMeta(mentionMenuKey, {
              type: 'move',
              delta: event.key === 'ArrowDown' ? 1 : -1
            } satisfies MentionMenuMeta)
          )
          return true
        }
        if (event.key === 'Enter') {
          event.preventDefault()
          return executeMentionItem(view, state, state.selected)
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          view.dispatch(
            view.state.tr.setMeta(mentionMenuKey, {
              type: 'close'
            } satisfies MentionMenuMeta)
          )
          return true
        }
        return false
      }
    },
    view: (editorView) => {
      const menu = document.createElement('div')
      menu.className = 'note-slash-menu note-mention-menu'
      menu.setAttribute('role', 'listbox')
      menu.setAttribute('aria-label', '자료 멘션')
      menu.hidden = true
      document.body.append(menu)

      const render = (view: EditorView): void => {
        const state = mentionMenuKey.getState(view.state)
        if (state === undefined || !state.active) {
          menu.hidden = true
          return
        }

        menu.hidden = false
        const children: HTMLElement[] = []
        if (files === null) {
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
            option.dataset.mentionIndex = String(index)
            option.setAttribute('role', 'option')
            option.setAttribute(
              'aria-selected',
              String(index === state.selected)
            )
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
            empty.textContent = '일치하는 자료가 없습니다.'
            children.push(empty)
          }
        }
        menu.replaceChildren(...children)

        const coordinates = view.coordsAtPos(view.state.selection.from)
        placeFixedMenu(menu, coordinates.left, coordinates.bottom)
      }

      const handleMouseDown = (event: MouseEvent): void => {
        const target = event.target
        if (!(target instanceof Element)) return
        const option = target.closest<HTMLElement>('[data-mention-index]')
        const selected = Number(option?.dataset.mentionIndex)
        const state = mentionMenuKey.getState(editorView.state)
        if (
          state === undefined ||
          !state.active ||
          !Number.isInteger(selected)
        ) {
          return
        }
        event.preventDefault()
        executeMentionItem(editorView, state, selected)
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
