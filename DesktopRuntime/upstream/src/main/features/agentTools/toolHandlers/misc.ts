import type { TabDescriptor } from '../../../../shared/tabs'
import { ValidationError } from '../../../db/errors'
import {
  BROWSER_KEYS,
  type BrowserKey,
  type BrowserScrollInput
} from '../../browserAgent/browserTools'
import {
  cancelled,
  inputObject,
  nullableStringField,
  optionalInteger,
  optionalString,
  stringField,
  type ToolContext,
  type ToolHandlerMap
} from './context'

interface BrowserExtensions {
  browser_scroll: (tabId: string, to: BrowserScrollInput) => Promise<unknown>
  browser_key: (tabId: string, key: BrowserKey) => Promise<unknown>
  browser_hover: (tabId: string, ref: string) => Promise<unknown>
  browser_back: (tabId: string) => Promise<unknown>
  browser_forward: (tabId: string) => Promise<unknown>
  browser_reload: (tabId: string) => Promise<unknown>
  browser_stop: (tabId: string) => Promise<unknown>
  browser_focus_tab: (tabId: string) => Promise<unknown>
  browser_close_tab: (tabId: string) => Promise<unknown>
  browser_find: (tabId: string, text: string) => Promise<unknown>
}

const SCROLL_DIRECTIONS = ['down', 'up', 'top', 'bottom'] as const

export function miscTools(ctx: ToolContext) {
  const {
    deps,
    currentTurn,
    reserve,
    release,
    approve,
    record,
    assertCoursePath
  } = ctx

  function browser(): BrowserExtensions {
    if (deps.browser === undefined) {
      throw new ValidationError('browser tools are unavailable')
    }
    return deps.browser as unknown as BrowserExtensions
  }

  return {
    app_state() {
      const state = deps.appState?.()
      if (state === undefined) {
        return {
          selectedCourseId: null,
          groups: [],
          courses: [],
          workspaceTabs: [],
          browserTabs: []
        }
      }
      return state
    },

    list_favorites(input) {
      return deps.favoritesRepo.list(nullableStringField(input, 'courseId'))
    },

    add_favorite(input) {
      const context = currentTurn()
      const courseId = nullableStringField(input, 'courseId')
      const favorite = deps.favoritesRepo.add({
        courseId,
        label: stringField(input, 'label', { nonEmpty: true }),
        descriptor: inputObject(input['descriptor']) as unknown as TabDescriptor
      })
      record(context, courseId ?? context.courseId, 'add_favorite', 'course', favorite.id, `즐겨찾기 «${favorite.label}»`, false)
      return favorite
    },

    rename_favorite(input) {
      const context = currentTurn()
      const favorite = deps.favoritesRepo.rename({
        id: stringField(input, 'id', { nonEmpty: true }),
        label: stringField(input, 'label', { nonEmpty: true })
      })
      record(context, favorite.courseId ?? context.courseId, 'rename_favorite', 'course', favorite.id, `즐겨찾기 «${favorite.label}»`, false)
      return favorite
    },

    async remove_favorite(input) {
      const context = currentTurn()
      const id = stringField(input, 'id', { nonEmpty: true })
      if (!await approve(
        context,
        'remove_favorite',
        `즐겨찾기 «${id}»을(를) 삭제합니다.`,
        [id]
      )) return cancelled('remove_favorite')
      deps.favoritesRepo.softDelete(id)
      record(context, context.courseId, 'remove_favorite', 'course', id, `즐겨찾기 «${id}»`, false)
      return { ok: true as const }
    },

    async search_course(input) {
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const query = stringField(input, 'query', { nonEmpty: true })
      const limit = optionalInteger(input, 'limit', 1)
      return { hits: await deps.searchIndex.query(courseId, query, limit) }
    },

    browser_scroll(input) {
      const tabId = stringField(input, 'tabId', { nonEmpty: true })
      const to = optionalString(input, 'to')
      const ref = optionalString(input, 'ref')
      if ((to === undefined) === (ref === undefined)) {
        throw new ValidationError('exactly one of to or ref is required')
      }
      if (ref !== undefined) {
        return browser().browser_scroll(tabId, { kind: 'ref', ref })
      }
      if (!(SCROLL_DIRECTIONS as readonly string[]).includes(to as string)) {
        throw new ValidationError('to must be down, up, top, or bottom')
      }
      return browser().browser_scroll(tabId, {
        kind: to as (typeof SCROLL_DIRECTIONS)[number]
      })
    },

    browser_key(input) {
      const key = stringField(input, 'key', { nonEmpty: true })
      if (!(BROWSER_KEYS as readonly string[]).includes(key)) {
        throw new ValidationError('unsupported browser key')
      }
      return browser().browser_key(
        stringField(input, 'tabId', { nonEmpty: true }),
        key as BrowserKey
      )
    },

    browser_hover(input) {
      return browser().browser_hover(
        stringField(input, 'tabId', { nonEmpty: true }),
        stringField(input, 'ref', { nonEmpty: true })
      )
    },

    browser_back: (input) => browser().browser_back(stringField(input, 'tabId', { nonEmpty: true })),
    browser_forward: (input) => browser().browser_forward(stringField(input, 'tabId', { nonEmpty: true })),
    browser_reload: (input) => browser().browser_reload(stringField(input, 'tabId', { nonEmpty: true })),
    browser_stop: (input) => browser().browser_stop(stringField(input, 'tabId', { nonEmpty: true })),
    browser_focus_tab: (input) => browser().browser_focus_tab(stringField(input, 'tabId', { nonEmpty: true })),
    browser_close_tab: (input) => browser().browser_close_tab(stringField(input, 'tabId', { nonEmpty: true })),
    browser_find: (input) => browser().browser_find(
      stringField(input, 'tabId', { nonEmpty: true }),
      stringField(input, 'text', { nonEmpty: true })
    ),

    send_highlight_to_note(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      const noteRelPath = optionalString(input, 'noteRelPath')
      assertCoursePath(courseId, relPath)
      if (noteRelPath !== undefined) assertCoursePath(courseId, noteRelPath)
      const mayCreate = noteRelPath === undefined
      if (mayCreate) reserve('files', 1)
      let result
      try {
        result = deps.linkService.sendHighlightToNote({
          courseId,
          relPath,
          page: optionalInteger(input, 'page', 1) as number,
          quote: stringField(input, 'quote', { nonEmpty: true }),
          comment: nullableStringField(input, 'comment'),
          annotationId: stringField(input, 'annotationId', { nonEmpty: true }),
          ...(noteRelPath !== undefined ? { noteRelPath } : {})
        })
      } catch (error) {
        if (mayCreate) release('files', 1)
        throw error
      }
      if (mayCreate && !result.created) release('files', 1)
      record(context, courseId, 'send_highlight_to_note', 'note', result.relPath, `필기 «${result.relPath}»`, result.created)
      return result
    },

    send_web_clip_to_note(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const noteRelPath = optionalString(input, 'noteRelPath')
      if (noteRelPath !== undefined) assertCoursePath(courseId, noteRelPath)
      const mayCreate = noteRelPath === undefined
      if (mayCreate) reserve('files', 1)
      let result
      try {
        result = deps.linkService.sendWebClipToNote({
          courseId,
          url: stringField(input, 'url', { nonEmpty: true }),
          title: stringField(input, 'title'),
          quote: stringField(input, 'quote', { nonEmpty: true }),
          comment: nullableStringField(input, 'comment'),
          ...(noteRelPath !== undefined ? { noteRelPath } : {})
        })
      } catch (error) {
        if (mayCreate) release('files', 1)
        throw error
      }
      if (mayCreate && !result.created) release('files', 1)
      record(context, courseId, 'send_web_clip_to_note', 'note', result.relPath, `필기 «${result.relPath}»`, result.created)
      return result
    }
  } satisfies Partial<ToolHandlerMap>
}
