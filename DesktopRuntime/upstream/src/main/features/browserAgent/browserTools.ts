import { AsyncLocalStorage } from 'node:async_hooks'
import type { AgentConfirmScope } from '../../../shared/types/agentTools'
import { RunStopped } from './run'
import type { AuditRepo } from './audit'
import {
  ANY_ORIGIN,
  GRANT_DAYS,
  normalizeOrigin,
  type BrowserCapability,
  type GrantsRepo
} from './grants'
import { checkNavigation } from './navigation'
import { runGuestScript, verdictFor, type ScrollTarget } from './pageDriver'
import { resolveRef } from './refs'
import { DEFAULT_SNAPSHOT_CHARS } from './snapshot'
import type { ElementFacts } from './actionPolicy'
import { redactText, redactUrl } from './redact'
import { itemKey, type SeenRepo } from './seenRepo'
import {
  fetchLmsList,
  lmsTargetFor,
  type LmsListKind,
  type LmsTarget
} from './siteRecipes'
import type { CourseLinkSpec } from '../../../shared/types/university'
const LIST_KINDS: readonly LmsListKind[] = ['announcements', 'assignments', 'modules', 'files']
const SCROLL_KINDS = ['down', 'up', 'top', 'bottom'] as const
export const BROWSER_KEYS = ['Enter', 'Tab', 'Escape', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'] as const
export type BrowserKey = (typeof BROWSER_KEYS)[number]
export type BrowserScrollInput =
  | { kind: 'down' | 'up' | 'top' | 'bottom' }
  | { kind: 'ref'; ref: string }
export interface BrowserToolsDeps {
  courseId: string
  getRunId: () => string
  getAgentUse?: () => boolean
  grants: GrantsRepo
  audit: AuditRepo
  seen: SeenRepo
  courseLinks: (courseId: string) => { url: string; lmsCourseId: string | null }[]
  specFor: (url: string) => Pick<CourseLinkSpec, 'platform'> | null
  fetch: (url: string) => Promise<Response>
  collect?: (input: {
    courseId: string
    url: string
    dirRelPath: string
  }) => Promise<{ relPath: string }>
  confirm: (request: {
    courseId: string
    tool: string
    summary: string
    details: string[]
    scopes?: AgentConfirmScope[]
  }) => Promise<AgentConfirmScope | false>
  openTabs?: () => {
    tabs: { tabId: string; title: string; url: string; asleep: boolean }[]
    activeTabId: string | null
  }
  page?: PageSurface
  commit?: CommitSurface
}
export interface CommitSurface {
  submit: (tabId: string, frameIndex: number, elementIndex: number) => Promise<boolean>
  useSavedLogin: (tabId: string) => Promise<{ filled: boolean; username: string | null }>
  attachFile: (
    tabId: string,
    frameIndex: number,
    elementIndex: number,
    courseId: string,
    relPath: string
  ) => Promise<boolean>
}
export interface PageSurface {
  openTab: (url: string) => Promise<{ tabId: string; url: string }>
  wakeTab: (tabId: string) => Promise<boolean>
  generation: (tabId: string) => number
  snapshot: (tabId: string, maxChars: number) => Promise<{ url: string; outline: string } | null>
  read: (tabId: string, maxChars: number) => Promise<{ url: string; text: string } | null>
  factsFor: (
    tabId: string,
    frameIndex: number,
    elementIndex: number
  ) => Promise<ElementFacts | null>
  act: (
    tabId: string,
    frameIndex: number,
    elementIndex: number,
    action:
      | { kind: 'click' }
      | { kind: 'type'; text: string }
      | { kind: 'select'; value: string }
  ) => Promise<ActOutcome>
  currentUrl: (tabId: string) => string | null
  scroll: (tabId: string, to: ScrollTarget) => Promise<ActOutcome>
  pressKey: (tabId: string, key: BrowserKey) => Promise<ActOutcome>
  hover: (tabId: string, frameIndex: number, elementIndex: number) => Promise<ActOutcome>
  navigateHistory: (
    tabId: string,
    action: 'back' | 'forward' | 'reload' | 'stop'
  ) => Promise<ActOutcome>
  tabLifecycle: (tabId: string, action: 'focus' | 'close') => Promise<boolean>
  findInPage: (tabId: string, text: string) => Promise<number>
  handoff: (tabId: string, message: string) => Promise<'resumed' | 'stopped'>
  assertLive: (tabId?: string) => void
  step: (action: string, url?: string) => void
}
export interface ActOutcome {
  ok: boolean
  problem: string | null
  options?: { value: string; label: string }[]
  url: string
  title: string
  navigated: boolean
}
export interface LmsCoursePageResult {
  url: string | null
  platform: string | null
}
export function createBrowserTools(deps: BrowserToolsDeps) {
  const toolTurn = new AsyncLocalStorage<string>()
  function assertPageLive(page: PageSurface, tabId?: string): void {
    const startedIn = toolTurn.getStore()
    if (startedIn !== undefined && startedIn !== deps.getRunId()) throw new RunStopped()
    page.assertLive(tabId)
  }
  function targetFor(courseId: string): LmsTarget | null {
    for (const link of deps.courseLinks(courseId)) {
      const target = lmsTargetFor(link, deps.specFor(link.url))
      if (target !== null) return target
    }
    return null
  }
  async function urlOfTab(page: PageSurface, tabId: string): Promise<string | null> {
    const current = page.currentUrl(tabId)
    if (current !== null) return current
    const woke = await page.wakeTab(tabId)
    return woke ? page.currentUrl(tabId) : null
  }
  function audit(
    action: Parameters<AuditRepo['record']>[0]['action'],
    url: string,
    detail: string
  ): void {
    deps.audit.record({
      courseId: deps.courseId,
      runId: deps.getRunId(),
      action,
      url: redactUrl(url),
      detail: redactText(detail)
    })
  }
  async function gate(
    url: string,
    capability: BrowserCapability
  ): Promise<{ ok: true } | { ok: false; message: string }> {
    const held = deps.grants.find({
      courseId: deps.courseId,
      url,
      capability
    })
    const verdict = checkNavigation({
      url,
      capability,
      heldCapability: held?.capability ?? null
    })
    if (verdict.allowed) {
      if (held !== null) deps.grants.touch(held.id)
      return { ok: true }
    }
    if (verdict.reason !== 'no-grant') {
      audit('denied', url, `${verdict.reason}: ${verdict.message}`)
      return { ok: false, message: verdict.message }
    }
    const origin = normalizeOrigin(url)
    if (origin === null) {
      audit('denied', url, 'malformed origin')
      return { ok: false, message: verdict.message }
    }
    const scope = await deps.confirm({
      courseId: deps.courseId,
      tool: 'browser_access',
      summary: `${origin} 을 읽고 다룰까요?`,
      details: [
        '보기와 누르기, 파일 받기까지 할 수 있어요.',
        '글을 쓰거나 제출하는 건 그때마다 따로 물어봐요.'
      ],
      scopes: ['once', 'site', 'course']
    })
    if (scope === false) {
      audit('denied', url, '학생이 거부함')
      return { ok: false, message: '학생이 접근을 허용하지 않았어요.' }
    }
    if (scope === 'once') {
      audit('grant', origin, '이번 한 번만')
      return { ok: true }
    }
    const target = scope === 'course' ? ANY_ORIGIN : origin
    const created = deps.grants.grant({
      courseId: deps.courseId,
      url: target,
      capability
    })
    if (created === null) {
      return { ok: false, message: verdict.message }
    }
    audit(
      'grant',
      origin,
      `${scope === 'course' ? '이 과목의 모든 사이트' : '이 사이트'} · ${GRANT_DAYS}일`
    )
    deps.grants.touch(created.id)
    return { ok: true }
  }
  type ToolError = {
    status: 'error'
    message: string
    options?: { value: string; label: string }[]
  }
  type GatedTab =
    | { ok: true; page: PageSurface; url: string }
    | { ok: false; result: ToolError }
  function pageChanged(page: PageSurface, tabId: string, url: string, generation: number): ToolError | null {
    assertPageLive(page, tabId)
    if (deps.getAgentUse?.() === false) {
      return { status: 'error', message: '브라우저 에이전트 사용이 설정에서 꺼져 있어요' }
    }
    if (page.currentUrl(tabId) === url && page.generation(tabId) === generation) return null
    audit('denied', url, '승인 또는 페이지 확인 중 페이지가 바뀜')
    return { status: 'error', message: '페이지가 그 사이에 바뀌었어요. 다시 살펴본 뒤에 진행해 주세요.' }
  }
  async function gatedTab(
    tabId: string,
    capability: BrowserCapability,
    unavailable: string
  ): Promise<GatedTab> {
    const page = deps.page
    if (page === undefined) {
      return { ok: false, result: { status: 'error', message: unavailable } }
    }
    assertPageLive(page, tabId)
    const listedUrl = deps.openTabs?.().tabs.find((tab) => tab.tabId === tabId)?.url
    const url = page.currentUrl(tabId) ?? listedUrl ?? null
    if (url === null) {
      return {
        ok: false,
        result: { status: 'error', message: '그 탭을 찾지 못했어요.' }
      }
    }
    const generation = page.generation(tabId)
    const permitted = await gate(url, capability)
    if (!permitted.ok) {
      return {
        ok: false,
        result: { status: 'error', message: permitted.message }
      }
    }
    const changed = pageChanged(page, tabId, url, generation)
    if (changed) return { ok: false, result: changed }
    return { ok: true, page, url }
  }
  async function refFacts(
    page: PageSurface,
    tabId: string,
    url: string,
    ref: string,
    detail: string
  ): Promise<
    | { ok: true; frameIndex: number; elementIndex: number; facts: ElementFacts }
    | { ok: false; result: ToolError }
  > {
    const generation = page.generation(tabId)
    const resolved = resolveRef(ref, generation)
    if (!resolved.ok) {
      audit('denied', url, `${detail} ref ${resolved.reason}`)
      return {
        ok: false,
        result: { status: 'error', message: resolved.message }
      }
    }
    const facts = await page.factsFor(
      tabId,
      resolved.frameIndex,
      resolved.elementIndex
    )
    const changed = pageChanged(page, tabId, url, generation)
    if (changed) return { ok: false, result: changed }
    if (facts === null) {
      audit('denied', url, `${detail}: 요소 없음`)
      return {
        ok: false,
        result: { status: 'error', message: '그 요소를 찾지 못했어요.' }
      }
    }
    return {
      ok: true,
      frameIndex: resolved.frameIndex,
      elementIndex: resolved.elementIndex,
      facts
    }
  }
  function actionResult(
    page: PageSurface,
    outcome: ActOutcome,
    detail: string,
    action: 'navigate' | 'read' = 'navigate'
  ):
    | {
        status: 'ok'
        url: string
        title: string
        navigated: boolean
        options?: { value: string; label: string }[]
      }
    | ToolError {
    if (!outcome.ok) {
      audit('denied', outcome.url, `${detail}: ${outcome.problem ?? '실패'}`)
      return {
        status: 'error',
        message: outcome.problem ?? '동작을 실행하지 못했어요.',
        ...(outcome.options === undefined ? {} : { options: outcome.options })
      }
    }
    audit(action, outcome.url, detail)
    page.step('페이지를 조작하는 중', outcome.url)
    return {
      status: 'ok',
      url: outcome.url,
      title: outcome.title,
      navigated: outcome.navigated,
      ...(outcome.options === undefined ? {} : { options: outcome.options })
    }
  }
  async function historyTool(
    tabId: string,
    action: 'back' | 'forward' | 'reload' | 'stop'
  ) {
    const tab = await gatedTab(
      tabId,
      'interact',
      '이 대화에서는 페이지를 이동할 수 없어요.'
    )
    if (!tab.ok) return tab.result
    return actionResult(
      tab.page,
      await tab.page.navigateHistory(tabId, action),
      `history ${action}`
    )
  }
  async function lifecycleTool(tabId: string, action: 'focus' | 'close') {
    const tab = await gatedTab(
      tabId,
      'interact',
      '이 대화에서는 탭을 다룰 수 없어요.'
    )
    if (!tab.ok) return tab.result
    const ok = await tab.page.tabLifecycle(tabId, action)
    audit(ok ? 'navigate' : 'denied', tab.url, `tab ${action}`)
    return ok
      ? { status: 'ok' as const }
      : { status: 'error' as const, message: '탭 동작을 실행하지 못했어요.' }
  }
  const tools = {
    lms_course_page(courseId: string): LmsCoursePageResult {
      const target = targetFor(courseId)
      if (target === null) return { url: null, platform: null }
      return {
        url: `${target.origin}/courses/${target.lmsCourseId}`,
        platform: target.platform
      }
    },
    async lms_list(
      courseId: string,
      rawKind: string | null
    ) {
      const kind: LmsListKind = LIST_KINDS.includes(rawKind as LmsListKind)
        ? (rawKind as LmsListKind)
        : 'files'
      const target = targetFor(courseId)
      if (target === null) {
        return {
          status: 'error',
          message:
            '이 과목에 학교 강의실이 연결돼 있지 않아요. 과목 링크를 먼저 추가해 주세요.'
        }
      }
      const permitted = await gate(target.origin, 'read')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      const result = await fetchLmsList({ fetch: deps.fetch }, target, kind)
      if (result.status !== 'ok') {
        audit('read', target.origin, `${kind}: ${result.message}`)
        return { status: 'error', message: result.message }
      }
      audit('read', target.origin, `${kind}: ${result.items.length}건 조회`)
      return {
        status: 'ok',
        kind,
        items: result.items.map((item) => ({
          title: item.title,
          at: item.at,
          url: item.url
        }))
      }
    },
    async browser_download(
      courseId: string,
      url: string,
      dirRelPath: string
    ) {
      if (deps.collect === undefined) {
        return { status: 'error', message: '이 대화에서는 내려받을 수 없어요.' }
      }
      const permitted = await gate(url, 'download')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      try {
        const { relPath } = await deps.collect({ courseId, url, dirRelPath })
        audit('download', url, `자료 «${relPath}»`)
        return { status: 'ok', relPath }
      } catch (error) {
        const message =
          error instanceof Error ? error.message : '내려받지 못했어요.'
        audit('download', url, `실패: ${message}`)
        return { status: 'error', message }
      }
    },
    browser_tabs() {
      const source = deps.openTabs
      if (source === undefined) {
        return { status: 'ok', tabs: [], activeTabId: null }
      }
      const { tabs, activeTabId } = source()
      audit('snapshot', '', `탭 ${tabs.length}개를 확인했어요`)
      return {
        status: 'ok',
        tabs: tabs.map((tab) => ({
          tabId: tab.tabId,
          title: redactText(tab.title),
          url: redactUrl(tab.url),
          active: tab.tabId === activeTabId,
          asleep: tab.asleep
        })),
        activeTabId
      }
    },
    async browser_open(url: string) {
      const page = deps.page
      if (page === undefined) {
        return { status: 'error', message: '이 대화에서는 페이지를 열 수 없어요.' }
      }
      assertPageLive(page)
      const permitted = await gate(url, 'read')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      assertPageLive(page)
      if (deps.getAgentUse?.() === false) return { status: 'error', message: '브라우저 에이전트 사용이 설정에서 꺼져 있어요' }
      const opened = await page.openTab(url)
      audit('navigate', opened.url, '탭에서 열었어요')
      page.step('페이지를 여는 중', opened.url)
      return { status: 'ok', tabId: opened.tabId, url: opened.url }
    },
    async browser_snapshot(
      tabId: string,
      maxChars: number | null
    ) {
      const page = deps.page
      if (page === undefined) {
        return { status: 'error', message: '이 대화에서는 페이지를 볼 수 없어요.' }
      }
      assertPageLive(page, tabId)
      const url = await urlOfTab(page, tabId)
      if (url === null) {
        return { status: 'error', message: '그 탭을 찾지 못했어요.' }
      }
      const generation = page.generation(tabId)
      const permitted = await gate(url, 'read')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      const changed = pageChanged(page, tabId, url, generation)
      if (changed) return changed
      const result = await page.snapshot(tabId, maxChars ?? DEFAULT_SNAPSHOT_CHARS)
      if (result === null) {
        return { status: 'error', message: '페이지를 살펴보지 못했어요.' }
      }
      const changedAfterRead = pageChanged(page, tabId, url, generation)
      if (changedAfterRead) return changedAfterRead
      audit('snapshot', result.url, `${result.outline.length}자`)
      page.step('페이지를 살펴보는 중', result.url)
      return { status: 'ok', url: result.url, outline: result.outline }
    },
    async browser_read(
      tabId: string,
      maxChars: number | null
    ) {
      const page = deps.page
      if (page === undefined) {
        return { status: 'error', message: '이 대화에서는 페이지를 읽을 수 없어요.' }
      }
      assertPageLive(page, tabId)
      const url = await urlOfTab(page, tabId)
      if (url === null) {
        return { status: 'error', message: '그 탭을 찾지 못했어요.' }
      }
      const generation = page.generation(tabId)
      const permitted = await gate(url, 'read')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      const changed = pageChanged(page, tabId, url, generation)
      if (changed) return changed
      const result = await page.read(tabId, maxChars ?? 8000)
      if (result === null) {
        return { status: 'error', message: '페이지를 읽지 못했어요.' }
      }
      const changedAfterRead = pageChanged(page, tabId, url, generation)
      if (changedAfterRead) return changedAfterRead
      audit('read', result.url, `본문 ${result.text.length}자`)
      return { status: 'ok', url: result.url, text: result.text }
    },
    async browser_scroll(tabId: string, to: BrowserScrollInput) {
      const tab = await gatedTab(
        tabId,
        'read',
        '이 대화에서는 페이지를 스크롤할 수 없어요.'
      )
      if (!tab.ok) return tab.result
      if (typeof to !== 'object' || to === null || typeof to.kind !== 'string') {
        audit('denied', tab.url, 'scroll 입력 오류')
        return { status: 'error' as const, message: '스크롤 대상을 확인해 주세요.' }
      }
      let target: ScrollTarget
      if (to.kind === 'ref') {
        const element = await refFacts(tab.page, tabId, tab.url, to.ref, 'scroll')
        if (!element.ok) return element.result
        target = {
          kind: 'ref',
          frameIndex: element.frameIndex,
          elementIndex: element.elementIndex
        }
      } else if ((SCROLL_KINDS as readonly string[]).includes(to.kind)) {
        target = { kind: to.kind as (typeof SCROLL_KINDS)[number] }
      } else {
        audit('denied', tab.url, `scroll ${to.kind}`)
        return { status: 'error' as const, message: '지원하지 않는 스크롤이에요.' }
      }
      return actionResult(
        tab.page,
        await tab.page.scroll(tabId, target),
        `scroll ${to.kind}`,
        'read'
      )
    },
    async browser_key(tabId: string, key: string) {
      const tab = await gatedTab(
        tabId,
        'interact',
        '이 대화에서는 키를 누를 수 없어요.'
      )
      if (!tab.ok) return tab.result
      if (!(BROWSER_KEYS as readonly string[]).includes(key)) {
        audit('denied', tab.url, `key ${key}`)
        return { status: 'error' as const, message: '지원하지 않는 키예요.' }
      }
      if (key === 'Enter') {
        const generation = tab.page.generation(tabId)
        const approved = await deps.confirm({
          courseId: deps.courseId,
          tool: 'browser_key',
          summary: `${normalizeOrigin(tab.url) ?? tab.url} 에서 Enter 키를 누를까요?`,
          details: ['입력 중인 폼이 제출되거나 메시지가 전송될 수 있어요.', '이 승인은 이번 한 번만 유효하고, 기억해 두지 않습니다.'],
          scopes: ['once']
        })
        if (!approved) {
          audit('denied', tab.url, 'Enter: 학생이 거부함')
          return { status: 'error' as const, message: '학생이 Enter 키 실행을 승인하지 않았어요.' }
        }
        const changed = pageChanged(tab.page, tabId, tab.url, generation)
        if (changed) return changed
      }
      return actionResult(
        tab.page,
        await tab.page.pressKey(tabId, key as BrowserKey),
        `key ${key}`
      )
    },
    async browser_hover(tabId: string, ref: string) {
      const tab = await gatedTab(
        tabId,
        'interact',
        '이 대화에서는 페이지에 마우스를 올릴 수 없어요.'
      )
      if (!tab.ok) return tab.result
      const element = await refFacts(tab.page, tabId, tab.url, ref, 'hover')
      if (!element.ok) return element.result
      return actionResult(
        tab.page,
        await tab.page.hover(tabId, element.frameIndex, element.elementIndex),
        `hover ${element.facts.tag}`
      )
    },
    browser_back(tabId: string) {
      return historyTool(tabId, 'back')
    },
    browser_forward(tabId: string) {
      return historyTool(tabId, 'forward')
    },
    browser_reload(tabId: string) {
      return historyTool(tabId, 'reload')
    },
    browser_stop(tabId: string) {
      return historyTool(tabId, 'stop')
    },
    browser_focus_tab(tabId: string) {
      return lifecycleTool(tabId, 'focus')
    },
    browser_close_tab(tabId: string) {
      return lifecycleTool(tabId, 'close')
    },
    async browser_find(tabId: string, text: string) {
      const tab = await gatedTab(
        tabId,
        'read',
        '이 대화에서는 페이지에서 찾을 수 없어요.'
      )
      if (!tab.ok) return tab.result
      if (text.trim() === '') {
        audit('denied', tab.url, 'find 빈 문자열')
        return { status: 'error' as const, message: '찾을 글을 입력해 주세요.' }
      }
      try {
        const matches = await tab.page.findInPage(tabId, text)
        audit('read', tab.url, `find ${text}: ${matches}건`)
        return { status: 'ok' as const, matches }
      } catch {
        audit('denied', tab.url, `find ${text}: 실패`)
        return { status: 'error' as const, message: '페이지에서 찾지 못했어요.' }
      }
    },
    async browser_act(
      tabId: string,
      ref: string,
      action:
        | { kind: 'click' }
        | { kind: 'type'; text: string }
        | { kind: 'select'; value: string }
    ) {
      const tab = await gatedTab(
        tabId,
        'interact',
        '이 대화에서는 페이지를 조작할 수 없어요.'
      )
      if (!tab.ok) return tab.result
      const element = await refFacts(tab.page, tabId, tab.url, ref, action.kind)
      if (!element.ok) return element.result
      const verdict = verdictFor(action.kind, element.facts)
      if (!verdict.allowed) {
        audit('denied', tab.url, `${action.kind}: ${verdict.reason}`)
        return { status: 'error', message: verdict.message }
      }
      const detail = action.kind === 'type'
        ? `type ${element.facts.tag}: ${action.text}`
        : action.kind === 'select'
          ? `select ${action.value}`
          : `click ${element.facts.tag} "${element.facts.href ?? ''}"`
      return actionResult(tab.page, await tab.page.act(
        tabId,
        element.frameIndex,
        element.elementIndex,
        action
      ), detail)
    },
    async browser_handoff(
      tabId: string,
      message: string
    ) {
      const page = deps.page
      if (page === undefined) {
        return { status: 'error', message: '이 대화에서는 넘길 수 없어요.' }
      }
      const outcome = await page.handoff(tabId, message)
      if (outcome === 'stopped') {
        return { status: 'error', message: '학생이 중지했어요.' }
      }
      return { status: 'resumed' }
    },
    async browser_submit(
      tabId: string,
      ref: string
    ) {
      const page = deps.page
      const commit = deps.commit
      if (page === undefined || commit === undefined) {
        return { status: 'error', message: '이 대화에서는 제출할 수 없어요.' }
      }
      assertPageLive(page, tabId)
      const url = page.currentUrl(tabId)
      if (url === null) {
        return { status: 'error', message: '그 탭을 찾지 못했어요.' }
      }
      const generation = page.generation(tabId)
      const permitted = await gate(url, 'interact')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      const changed = pageChanged(page, tabId, url, generation)
      if (changed) return changed
      const resolved = resolveRef(ref, page.generation(tabId))
      if (!resolved.ok) {
        audit('denied', url, `submit ref ${resolved.reason}`)
        return { status: 'error', message: resolved.message }
      }
      const facts = await page.factsFor(
        tabId,
        resolved.frameIndex,
        resolved.elementIndex
      )
      if (facts === null) {
        return { status: 'error', message: '그 요소를 찾지 못했어요.' }
      }
      const changedAfterFacts = pageChanged(page, tabId, url, generation)
      if (changedAfterFacts) return changedAfterFacts
      const approved = await deps.confirm({
        courseId: deps.courseId,
        tool: 'browser_submit',
        summary: `${normalizeOrigin(url) ?? url} 에서 제출할까요?`,
        details: [
          '되돌릴 수 없는 동작입니다.',
          '이 승인은 이번 한 번만 유효하고, 기억해 두지 않습니다.'
        ]
      })
      if (!approved) {
        audit('denied', url, 'submit: 학생이 거부함')
        return { status: 'error', message: '학생이 제출을 승인하지 않았어요.' }
      }
      const changedAfterApproval = pageChanged(page, tabId, url, generation)
      if (changedAfterApproval) return changedAfterApproval
      const ok = await runGuestScript(() =>
        commit.submit(tabId, resolved.frameIndex, resolved.elementIndex)
      )
      audit('navigate', url, ok ? 'submit 실행' : 'submit 실패')
      return ok
        ? { status: 'ok' }
        : { status: 'error', message: '제출하지 못했어요.' }
    },
    async browser_use_saved_login(tabId: string) {
      const page = deps.page
      const commit = deps.commit
      if (page === undefined || commit === undefined) {
        return { status: 'error', message: '이 대화에서는 로그인할 수 없어요.' }
      }
      assertPageLive(page, tabId)
      const url = page.currentUrl(tabId)
      if (url === null) {
        return { status: 'error', message: '그 탭을 찾지 못했어요.' }
      }
      const generation = page.generation(tabId)
      const permitted = await gate(url, 'interact')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      const changed = pageChanged(page, tabId, url, generation)
      if (changed) return changed
      const origin = normalizeOrigin(url) ?? url
      const approved = await deps.confirm({
        courseId: deps.courseId,
        tool: 'browser_use_saved_login',
        summary: `${origin} 에 저장된 로그인을 사용할까요?`,
        details: [
          '아이디와 비밀번호를 채우기만 하고, 제출은 하지 않습니다.',
          '이 승인은 이번 한 번만 유효하고, 기억해 두지 않습니다.'
        ]
      })
      if (!approved) {
        audit('denied', url, 'saved-login: 학생이 거부함')
        return { status: 'error', message: '학생이 로그인을 승인하지 않았어요.' }
      }
      const changedAfterApproval = pageChanged(page, tabId, url, generation)
      if (changedAfterApproval) return changedAfterApproval
      const result = await commit.useSavedLogin(tabId)
      audit('navigate', url, result.filled ? 'saved-login 채움' : 'saved-login 없음')
      return { status: 'ok', filled: result.filled }
    },
    async browser_attach_file(
      tabId: string,
      ref: string,
      courseId: string,
      relPath: string
    ) {
      const page = deps.page
      const commit = deps.commit
      if (page === undefined || commit === undefined) {
        return { status: 'error', message: '이 대화에서는 파일을 붙일 수 없어요.' }
      }
      assertPageLive(page, tabId)
      const url = page.currentUrl(tabId)
      if (url === null) {
        return { status: 'error', message: '그 탭을 찾지 못했어요.' }
      }
      const generation = page.generation(tabId)
      const permitted = await gate(url, 'interact')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      const changed = pageChanged(page, tabId, url, generation)
      if (changed) return changed
      const resolved = resolveRef(ref, page.generation(tabId))
      if (!resolved.ok) {
        return { status: 'error', message: resolved.message }
      }
      const ok = await commit.attachFile(
        tabId,
        resolved.frameIndex,
        resolved.elementIndex,
        courseId,
        relPath
      )
      audit('navigate', url, ok ? `파일 첨부 «${relPath}»` : '파일 첨부 실패')
      return ok
        ? { status: 'ok' }
        : { status: 'error', message: '파일을 붙이지 못했어요.' }
    },
    async lms_new_items(
      courseId: string,
      rawKind: string | null
    ) {
      const kind: LmsListKind = LIST_KINDS.includes(rawKind as LmsListKind)
        ? (rawKind as LmsListKind)
        : 'announcements'
      const target = targetFor(courseId)
      if (target === null) {
        return {
          status: 'error',
          message:
            '이 과목에 학교 강의실이 연결돼 있지 않아요. 과목 링크를 먼저 추가해 주세요.'
        }
      }
      const permitted = await gate(target.origin, 'read')
      if (!permitted.ok) return { status: 'error', message: permitted.message }
      const result = await fetchLmsList({ fetch: deps.fetch }, target, kind)
      if (result.status !== 'ok') {
        audit('read', target.origin, `${kind}: ${result.message}`)
        return { status: 'error', message: result.message }
      }
      const listKey = `${target.origin}|${target.lmsCourseId}|${kind}`
      const seenItems = result.items.map((item) => ({
        key: itemKey(item.id, item.title, item.at),
        title: item.title
      }))
      const firstRun = !deps.seen.has(courseId, listKey)
      if (firstRun) {
        deps.seen.seed({ courseId, listKey, items: seenItems })
        audit('read', target.origin, `${kind}: 처음 확인 (${seenItems.length}건 기록)`)
        return { status: 'ok', kind, items: [], firstRun: true }
      }
      const fresh = deps.seen.diffAndRecord({
        courseId,
        listKey,
        items: seenItems
      })
      const freshKeys = new Set(fresh.map((item) => item.key))
      const items = result.items
        .filter((item) => freshKeys.has(itemKey(item.id, item.title, item.at)))
        .map((item) => ({ title: item.title, at: item.at, url: item.url }))
      audit('read', target.origin, `${kind}: 새 항목 ${items.length}건`)
      return { status: 'ok', kind, items, firstRun: false }
    }
  }
  return new Proxy(tools, {
    get(target, key) {
      const value: unknown = Reflect.get(target, key)
      if (typeof key !== 'string' || !key.startsWith('browser_')) return value
      if (typeof value !== 'function') return value
      return (...args: unknown[]) => deps.getAgentUse?.() === false
        ? { status: 'error', message: '브라우저 에이전트 사용이 설정에서 꺼져 있어요' }
        : toolTurn.run(deps.getRunId(), () => Reflect.apply(value, target, args))
    }
  })
}
