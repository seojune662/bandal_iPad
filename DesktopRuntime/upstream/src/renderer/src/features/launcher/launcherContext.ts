import { useEffect } from 'react'
import { create } from 'zustand'
import type { TabDescriptor } from '../../../../shared/tabs'
import type { MaterialContext } from '../../../../shared/types/chatContext'
import type { LearningBinding } from '../../../../shared/types/learning'
import { invoke, onPush } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { readDocumentContexts } from '../agent/documentContext'
import { useBrowserGuests, type BrowserNavState } from '../browser/browserGuestsStore'
import { BROWSER_SELECTION_EVENT } from '../browser/selectionBridge'
import { tabTitle } from '../workspace/tabIdentity'

export interface LauncherContext {
  courseId: string | null
  courseName: string | null
  sourcePanelId: string | null
  descriptor: TabDescriptor | null
  material: MaterialContext | null
  binding: LearningBinding | null
  articleIds: string[]
  wordIds: string[]
  selection: string
  browser: { tabId: string; url: string; title: string } | null
  sourceUnavailable: boolean
  /** Exported course-relative file used by legacy Markdown recipes. */
  savedMaterialRelPath?: string
}

export const EMPTY_LAUNCHER_CONTEXT: LauncherContext = {
  courseId: null, courseName: null, sourcePanelId: null, descriptor: null,
  material: null, binding: null, articleIds: [], wordIds: [], selection: '',
  browser: null, sourceUnavailable: false
}

interface ContextSources {
  courseId: string | null
  courseName?: string | null
  source: { panelId: string; descriptor: TabDescriptor } | null
  documents: readonly MaterialContext[]
  browserNav?: BrowserNavState
}

/** Actual panel identity keeps duplicate views' pages and selections separate. */
export function resolveLauncherContext(input: ContextSources): LauncherContext {
  const descriptor = input.source?.descriptor ?? null
  const courseId = descriptor && 'courseId' in descriptor.payload ? descriptor.payload.courseId : input.courseId
  const sourcePanelId = input.source?.panelId ?? null
  const document = input.documents.find(item => item.documentId === sourcePanelId && item.courseId === courseId)
  const binding = descriptor?.kind === 'learning' && descriptor.payload.rootRelPath !== undefined
    ? { courseId: descriptor.payload.courseId, rootRelPath: descriptor.payload.rootRelPath } : null
  const browser = descriptor?.kind === 'browser'
    ? { tabId: descriptor.payload.tabId, url: input.browserNav?.url ?? descriptor.payload.initialUrl,
        title: input.browserNav?.title || tabTitle(descriptor) } : null
  const material: MaterialContext | null = document ? { ...document } : descriptor && courseId
    ? { courseId, kind: descriptor.kind, title: tabTitle(descriptor),
        ...(sourcePanelId ? { documentId: sourcePanelId } : {}),
        ...('relPath' in descriptor.payload ? { relPath: descriptor.payload.relPath } : {}),
        ...(browser ? { browserTabId: browser.tabId, url: browser.url } : {}) } : null
  return {
    courseId, courseName: input.courseName ?? null, sourcePanelId, descriptor, material, binding,
    articleIds: descriptor?.kind === 'learning' && descriptor.payload.view === 'reader' && descriptor.payload.itemId ? [descriptor.payload.itemId] : [],
    wordIds: [], selection: document?.selection?.trim() ?? '', browser,
    sourceUnavailable: document?.unavailable === true
  }
}

function currentContext(): LauncherContext {
  const workspace = useWorkspaceStore.getState()
  if (workspace.surface !== 'course') return { ...EMPTY_LAUNCHER_CONTEXT, articleIds: [], wordIds: [] }
  const courses = useCoursesStore.getState()
  const source = workspace.activePanelSource()
  const browserNav = source?.descriptor.kind === 'browser' ? useBrowserGuests.getState().nav[source.descriptor.payload.tabId] : undefined
  const courseId = source && 'courseId' in source.descriptor.payload ? source.descriptor.payload.courseId : courses.selectedCourseId
  return resolveLauncherContext({ courseId, courseName: courses.courses.find(course => course.id === courseId)?.name ?? null,
    source, documents: readDocumentContexts(), ...(browserNav ? { browserNav } : {}) })
}

/** Context menus carry an explicit target, which can differ from the open tab. */
export function studyTargetContext(courseId: string, relPath: string | null, selection?: string): LauncherContext {
  const current = currentContext()
  if (relPath !== null && current.courseId === courseId && current.material?.relPath === relPath) {
    return { ...current, selection: selection ?? current.selection }
  }
  return { ...EMPTY_LAUNCHER_CONTEXT, courseId,
    courseName: useCoursesStore.getState().courses.find(course => course.id === courseId)?.name ?? null,
    material: relPath === null ? null : { courseId, relPath, kind: /\.md$/i.test(relPath) ? 'note' : 'file', title: relPath.split('/').at(-1) ?? relPath },
    selection: selection?.trim() ?? '' }
}

async function enrichContext(context: LauncherContext, preserveSelection: boolean): Promise<LauncherContext> {
  let next = { ...context, articleIds: [...context.articleIds], wordIds: [...context.wordIds] }
  if (context.browser && context.courseId && context.sourcePanelId) {
    const snapshot = await invoke('chat:context', { courseId: context.courseId, sourcePanelId: context.sourcePanelId })
    const material = snapshot.material
    if (snapshot.refresh === 'failed' || material?.browserTabId !== context.browser.tabId || material.url !== context.browser.url) {
      throw new Error('브라우저 원본이 닫혔거나 이동했어요. 현재 글을 다시 선택해 주세요.')
    }
    next = { ...next, material, selection: preserveSelection ? context.selection : material.selection?.trim() ?? '',
      browser: { ...context.browser, title: material.title } }
  }
  if (context.binding) {
    const project = await invoke('learning:get', { binding: context.binding })
    if (context.descriptor?.kind === 'learning' && context.descriptor.payload.view === 'reader') {
      const article = context.articleIds.length ? project.articles.find(item => item.id === context.articleIds[0])
        : project.articles.find(item => item.status === 'reading') ?? project.articles.find(item => item.status === 'unread') ?? project.articles.at(-1)
      if (context.articleIds.length && !article) throw new Error('학습 원문을 찾을 수 없어요. 글을 다시 열어 주세요.')
      next.articleIds = article ? [article.id] : []
      if (next.material) next.material = { ...next.material, title: article?.title ?? `${project.name} · 읽기` }
      if (article?.exportRelPath) next.savedMaterialRelPath = [context.binding.rootRelPath, article.exportRelPath].filter(Boolean).join('/')
    }
    if (context.descriptor?.kind === 'learning' && context.descriptor.payload.view === 'vocabulary') {
      next.wordIds = project.words.map(word => word.id)
      if (next.material) next.material = { ...next.material, title: `단어장 · ${project.name}` }
      if (project.exports.some(item => item.relPath === '단어장.md')) next.savedMaterialRelPath = [context.binding.rootRelPath, '단어장.md'].filter(Boolean).join('/')
    }
  }
  return next
}

interface LauncherContextState { context: LauncherContext; loading: boolean; error: string | null }
const useContextState = create<LauncherContextState>(() => ({ context: EMPTY_LAUNCHER_CONTEXT, loading: false, error: null }))
let captured = false
let captureSequence = 0
let invalidatedSelection: { panelId: string; target: string; selection: string } | null = null

function learningTarget(descriptor: TabDescriptor | null): string | null {
  if (descriptor?.kind !== 'learning') return null
  const { courseId, rootRelPath, view, itemId } = descriptor.payload
  return JSON.stringify([courseId, rootRelPath, view ?? 'home', itemId])
}

/** Call on pointerdown: source and text are captured before launcher focus moves. */
export async function captureLauncherContext(): Promise<LauncherContext> {
  return captureContext(false)
}

async function captureContext(selectionChanged: boolean): Promise<LauncherContext> {
  const sequence = ++captureSequence
  captured = true
  const context = currentContext()
  const previous = useContextState.getState().context
  const target = learningTarget(context.descriptor)
  if (selectionChanged) invalidatedSelection = null
  else if (context.sourcePanelId && context.sourcePanelId === previous.sourcePanelId && target && target !== learningTarget(previous.descriptor) && (previous.selection || invalidatedSelection?.panelId === context.sourcePanelId)) {
    // The panel wrapper retains its last quote while changing view/article.
    // Do not transfer that quote to another source until a new selection occurs.
    invalidatedSelection = { panelId: context.sourcePanelId, target, selection: previous.selection || invalidatedSelection!.selection }
  }
  if (invalidatedSelection?.panelId === context.sourcePanelId && invalidatedSelection.target === target && invalidatedSelection.selection === context.selection) context.selection = ''
  useContextState.setState({ context, loading: true, error: null })
  try {
    const enriched = await enrichContext(context, false)
    if (sequence === captureSequence) useContextState.setState({ context: enriched, loading: false, error: null })
    return enriched
  } catch (error) {
    const message = error instanceof Error ? error.message : '현재 자료를 확인하지 못했어요.'
    const unavailable = { ...context, sourceUnavailable: true }
    if (sequence === captureSequence) useContextState.setState({ context: unavailable, loading: false, error: message })
    return unavailable
  }
}

export function prepareLauncherContext(): void { void captureLauncherContext() }

/** Refresh the pinned source; never substitute the tab focused after opening. */
export async function refreshLauncherContext(context: LauncherContext): Promise<LauncherContext> {
  if (useWorkspaceStore.getState().surface !== 'course' && context.sourcePanelId) throw new Error('자료가 숨겨졌어요. 원본 자료를 다시 열고 실행해 주세요.')
  if (context.sourceUnavailable) throw new Error('원본 자료를 확인할 수 없어요. 현재 자료를 다시 선택해 주세요.')
  if (context.sourcePanelId) {
    const workspace = useWorkspaceStore.getState()
    const active = workspace.activePanelSource()
    const descriptor = workspace.openTabs[context.sourcePanelId] ?? (active?.panelId === context.sourcePanelId ? active.descriptor : null)
    if (context.descriptor?.kind === 'learning' && descriptor && learningTarget(descriptor) !== learningTarget(context.descriptor)) {
      throw new Error('학습 원문이 바뀌었어요. 현재 자료를 다시 선택해 주세요.')
    }
    const document = readDocumentContexts().find(item => item.documentId === context.sourcePanelId)
    if (!document || document.unavailable || document.courseId !== context.courseId || document.relPath !== context.material?.relPath) {
      throw new Error('원본 자료가 닫혔거나 바뀌었어요. 현재 자료를 다시 선택해 주세요.')
    }
    context = { ...context, material: { ...document }, selection: context.selection }
  }
  return enrichContext(context, true)
}

export function useLauncherContext(): LauncherContextState {
  const state = useContextState()
  const panelId = useWorkspaceStore(workspace => workspace.activePanelId)
  const hydration = useWorkspaceStore(workspace => workspace.hydration)
  const surface = useWorkspaceStore(workspace => workspace.surface)
  const descriptorKey = useWorkspaceStore(workspace => {
    const descriptor = workspace.activePanelId ? workspace.openTabs[workspace.activePanelId] : undefined
    return descriptor ? JSON.stringify(descriptor) : null
  })
  const courseId = useCoursesStore(courses => courses.selectedCourseId)
  const browserTabId = state.context.browser?.tabId
  const url = useBrowserGuests(guests => browserTabId ? guests.nav[browserTabId]?.url : undefined)
  useEffect(() => {
    if (!captured || state.context.sourcePanelId !== panelId || state.context.courseId !== courseId || (url && url !== state.context.browser?.url) || (descriptorKey !== null && descriptorKey !== JSON.stringify(state.context.descriptor))) prepareLauncherContext()
  }, [panelId, hydration, courseId, url, descriptorKey, surface])
  useEffect(() => onPush('learning:changed', event => {
    const binding = useContextState.getState().context.binding
    if (binding?.courseId === event.binding.courseId && binding.rootRelPath === event.binding.rootRelPath) prepareLauncherContext()
  }), [])
  useEffect(() => {
    const selectionChanged = (): void => {
      const selected = window.getSelection()
      if (selected?.anchorNode && selected.anchorNode.parentElement?.closest('.tab-document')) void captureContext(true)
    }
    document.addEventListener('selectionchange', selectionChanged)
    window.addEventListener(BROWSER_SELECTION_EVENT, prepareLauncherContext)
    return () => { document.removeEventListener('selectionchange', selectionChanged); window.removeEventListener(BROWSER_SELECTION_EVENT, prepareLauncherContext) }
  }, [])
  return state
}
