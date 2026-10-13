import { rememberStartedLearningRun } from '../learning/learningStartedRuns'
import type { LearningAiSettings, LearningBinding, LearningProjectSummary } from '../../../../shared/types/learning'
import type { LearningGenerationSource } from '../../../../shared/ipc/learningContract'
import type { WorkflowPackScope } from '../../../../shared/types/workflowPack'
import { invoke } from '../../lib/ipc'
import { useMaterialsStore } from '../../stores/materialsStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { requestLearningCreation, requestLearningGeneration } from '../learning/LearningDialogsHost'
import type { LearningGenerationRequest } from '../learning/LearningGenerationForm'
import { openLearning } from '../learning/learningNavigation'
import { flushOpenNoteSession } from '../notes/noteSessionRegistry'
import { openPluginPanel, runPluginCommand } from '../plugins/pluginCommands'
import type { PackStudyToolDefinition } from '../study/studyToolsStore'
import { useStudyToolsStore } from '../study/studyToolsStore'
import type { FeatureEntry, PackFeatureEntry } from './featureInventory'
import { refreshLauncherContext, type LauncherContext } from './launcherContext'

export type FeatureActionScope = 'selection' | 'material' | 'course'
export interface FeatureActionOptions { binding?: LearningBinding; followUp?: boolean; ai?: LearningAiSettings }
export type FeatureActionResult =
  | { status: 'opened'; message: string; binding?: LearningBinding }
  | { status: 'started'; message: string; binding: LearningBinding; runId: string }
  | { status: 'dispatched'; message: string; courseId: string; relPath: string }
  | { status: 'completed'; message: string; relPath?: string }
  | { status: 'needs-project-picker'; message: string; projects: LearningProjectSummary[] }
  | { status: 'needs-course'; message: string }
  | { status: 'failed'; message: string }

export function studyToolFeatureEntry(tool: PackStudyToolDefinition): PackFeatureEntry {
  return { kind: 'pack', id: `pack:${tool.id}`, packId: tool.id, label: tool.label, description: tool.description,
    source: tool.source ?? 'builtin', enabled: tool.enabled !== false,
    unavailableReason: tool.enabled === false ? '학습 팩이 비활성화되어 있어요.' : null,
    schemaVersion: tool.schemaVersion ?? (tool.experience ? 2 : 1),
    worksOn: tool.worksOn ?? (tool.worksOnCourse ? ['course', 'material', 'selection'] : ['material', 'selection']),
    usesWeb: tool.usesWeb ?? false, outputs: tool.outputs ?? { dir: tool.outputDir ?? tool.outputsDir ?? 'AI 학습자료', primary: tool.label },
    ...(tool.experience ? { experience: tool.experience } : {}), ...(tool.followUp ? { followUp: tool.followUp } : {}) }
}

function targetScope(context: LauncherContext, scope: FeatureActionScope): WorkflowPackScope {
  return scope === 'course' ? 'course' : context.browser ? 'browser-tab' : scope === 'selection' ? 'selection' : 'material'
}

export function featureActionDisabledReason(entry: FeatureEntry, context: LauncherContext, scope: FeatureActionScope = 'material'): string | null {
  if (entry.unavailableReason) return entry.unavailableReason
  if (!entry.enabled) return '이 기능이 비활성화되어 있어요.'
  if (entry.kind === 'plugin-command' && entry.menuLocations.includes('editor') && !entry.menuLocations.includes('materials')) {
    if (scope === 'course' || context.material?.kind !== 'note') return '필기를 열고 선택한 글에서 사용할 수 있어요.'
  }
  if (entry.kind !== 'pack') return null
  if (entry.experience === 'article-vocabulary') return null
  if (!context.courseId) return '과목을 선택하면 사용할 수 있어요.'
  if (scope !== 'course' && context.sourceUnavailable) return '원본 자료를 확인할 수 없어요. 현재 자료를 다시 선택해 주세요.'
  if (scope === 'selection' && !context.selection) return '먼저 자료에서 글을 선택해 주세요.'
  if (scope === 'material' && !context.material?.relPath && !context.binding && !context.browser) return '파일이나 학습 자료를 열어 주세요.'
  if (scope === 'material' && context.binding && !context.articleIds.length && !context.wordIds.length) return '학습 공간에서 글이나 단어장을 열어 주세요.'
  if (entry.schemaVersion === 1 && scope !== 'course' && context.binding && !context.savedMaterialRelPath) return '이 자료의 원문 파일을 확인한 뒤 사용할 수 있어요.'
  const supportedScope = entry.schemaVersion === 2 && context.browser && scope !== 'course' ? scope === 'selection' ? 'selection' : 'material' : targetScope(context, scope)
  if (!entry.worksOn.includes(supportedScope)) return scope === 'course' ? '이 기능은 과목 전체에서 사용할 수 없어요.' : scope === 'selection' ? '이 기능은 선택한 글에서 사용할 수 없어요.' : '이 기능은 현재 자료에서 사용할 수 없어요.'
  return null
}

async function flushSourceNote(context: LauncherContext): Promise<void> {
  if (context.material?.kind !== 'note' || !context.material.relPath || !context.courseId) return
  const flushed = await flushOpenNoteSession({ courseId: context.courseId, relPath: context.material.relPath })
  if (flushed && flushed.result.status !== 'saved') {
    throw new Error(flushed.result.status === 'conflict' || flushed.result.status === 'error'
      ? `필기를 저장하지 못해 실행을 멈췄어요. ${flushed.result.detail}` : '필기를 저장한 뒤 다시 실행해 주세요.')
  }
  if (!flushed && context.material.unsaved) throw new Error('저장 전 필기를 확인할 수 없어요. 필기를 저장한 뒤 다시 실행해 주세요.')
}

function sameBinding(left: LearningBinding, right: LearningBinding): boolean { return left.courseId === right.courseId && left.rootRelPath === right.rootRelPath }

export async function requestFeatureAction(entry: FeatureEntry, context: LauncherContext, options: {
  scope?: FeatureActionScope; binding?: LearningBinding; sourceCourseId?: string; followUp?: boolean
  onResult?: (result: FeatureActionResult) => void
  /** Contextual launchers can present the shared setup form in their own surface. */
  presentGeneration?: (request: LearningGenerationRequest) => void
} = {}): Promise<FeatureActionResult> {
  if (entry.unavailableReason || !entry.enabled) return { status: 'failed', message: entry.unavailableReason ?? '이 기능이 비활성화되어 있어요.' }
  if (entry.kind === 'plugin-panel' || entry.kind === 'plugin-command' && entry.menuLocations.length === 0 || entry.kind === 'pack' && entry.experience === 'article-vocabulary') {
    return executeFeatureAction(entry, context, options.scope ?? 'course', options)
  }
  const presentGeneration = options.presentGeneration ?? requestLearningGeneration
  presentGeneration({ label: entry.kind === 'pack' && entry.packId === 'flashcards' ? '카드' : entry.label, entry, context, ...(options.scope ? { initialScope: options.scope } : {}),
    ...(options.binding ? { binding: options.binding } : {}), ...(options.sourceCourseId ? { sourceCourseId: options.sourceCourseId } : {}),
    onStart: async choice => {
      const result = await executeFeatureAction(entry, choice.context, choice.scope, { ...(choice.binding ? { binding: choice.binding } : {}), ...(choice.ai ? { ai: choice.ai } : {}), ...(options.followUp ? { followUp: true } : {}) })
      if (result.status === 'failed' || result.status === 'needs-course') throw new Error(result.message)
      options.onResult?.(result)
      return result
    } })
  return { status: 'opened', message: '원본, 저장 공간과 AI를 확인한 뒤 실행해 주세요.' }
}

async function reviewBinding(context: LauncherContext, override?: LearningBinding): Promise<LearningBinding | undefined> {
  if (override ?? context.binding) return override ?? context.binding ?? undefined
  const { projects } = await invoke('learning:list', { courseId: context.courseId! })
  const courses = useCoursesStore.getState().courses
  return projects.filter(project => !project.deletedAt && project.purpose === 'course-review' && project.linkedCourseId === context.courseId).sort((a, b) => (courses.find(course => course.id === b.binding.courseId)?.createdAt ?? '').localeCompare(courses.find(course => course.id === a.binding.courseId)?.createdAt ?? '') || (courses.find(course => course.id === b.binding.courseId)?.sortOrder ?? 0) - (courses.find(course => course.id === a.binding.courseId)?.sortOrder ?? 0))[0]?.binding
}

function generationSource(context: LauncherContext, scope: FeatureActionScope): LearningGenerationSource {
  if (scope === 'course') return { kind: 'course' }
  const selection = scope === 'selection' ? context.selection : ''
  if (context.binding && context.wordIds.length) return { kind: 'vocabulary', wordIds: context.wordIds, ...(selection ? { selection } : {}) }
  if (context.binding && context.articleIds.length) return { kind: 'article', articleIds: context.articleIds, ...(selection ? { selection } : {}) }
  return { kind: 'material', relPath: context.material!.relPath!, ...(context.material?.page ? { page: context.material.page } : {}), ...(selection ? { selection } : {}) }
}

/** Existing hosts remain responsible for permissions, source validation and writes. */
export async function executeFeatureAction(entry: FeatureEntry, capturedContext: LauncherContext, scope: FeatureActionScope = 'material', options: FeatureActionOptions = {}): Promise<FeatureActionResult> {
  const disabled = featureActionDisabledReason(entry, capturedContext, scope)
  if (disabled) return { status: !capturedContext.courseId && entry.kind === 'pack' ? 'needs-course' : 'failed', message: disabled }
  try {
    if (entry.kind === 'plugin-panel') {
      openPluginPanel(entry.pluginId, entry.panelId)
      return { status: 'opened', message: `${entry.label}을 열었어요.` }
    }
    if (entry.kind === 'pack' && entry.experience === 'article-vocabulary') {
      requestLearningCreation(undefined, entry.packId)
      return { status: 'opened', message: '새 영어 읽기 공간을 만들어 주세요.' }
    }
    if (useWorkspaceStore.getState().surface !== 'course' && capturedContext.sourcePanelId) throw new Error('이전 자료는 학습 홈에서 사용할 수 없어요. 원본 자료를 다시 선택해 주세요.')
    if (entry.kind === 'pack' && options.binding && capturedContext.binding && !sameBinding(options.binding, capturedContext.binding)) throw new Error('이 기사와 단어가 저장된 학습 공간을 선택해 주세요.')
    let context = scope === 'course' || (entry.kind === 'plugin-command' && !capturedContext.material?.relPath)
      ? capturedContext : await refreshLauncherContext(capturedContext)
    if (entry.kind === 'plugin-command') {
      const current = useWorkspaceStore.getState().activePanelSource()
      if (entry.menuLocations.includes('editor') && context.sourcePanelId && current?.panelId !== context.sourcePanelId) throw new Error('원본 필기를 다시 선택한 뒤 실행해 주세요.')
      await runPluginCommand(entry.pluginId, entry.commandId, scope !== 'course' && context.courseId && context.material?.relPath
        ? { courseId: context.courseId, relPath: context.material.relPath } : undefined, { notify: false })
      return { status: 'completed', message: `${entry.label}을 실행했어요.` }
    }
    if (entry.schemaVersion === 2) {
      let binding = await reviewBinding(context, options.binding)
      const project = binding ? await invoke('learning:get', { binding }) : null
      if (project && (!project.purpose || project.purpose === 'unclassified')) {
        requestLearningCreation(undefined, undefined, project)
        return { status: 'opened', ...(binding ? { binding } : {}), message: '기존 학습 공간의 종류와 AI를 먼저 확인해 주세요.' }
      }
      if (!options.ai && !project?.ai?.model) {
        return requestFeatureAction(entry, capturedContext, { scope, ...(binding ? { binding } : {}) })
      }
      if (scope !== 'course') { context = await refreshLauncherContext(capturedContext); await flushSourceNote(context) }
      let source: LearningGenerationSource
      if (context.browser && scope !== 'course') {
        if (!binding) {
          if (!options.ai) throw new Error('복습에 사용할 AI를 먼저 선택해 주세요.')
          binding = (await invoke('learning:create', { placement: 'standalone', name: `${context.courseName || '과목'} 복습`, topic: '과목 자료', purpose: 'course-review', topicIds: [], readingSetupConfirmed: false, linkedCourseId: context.courseId!, ai: options.ai })).binding
        }
        const project = await invoke('learning:addArticle', { binding, url: context.browser.url, tabId: context.browser.tabId, sourceCourseId: context.courseId! })
        const article = project.articles.find(item => item.id === project.addedArticleId)
        if (!article) throw new Error('이 글을 학습 원문으로 보관하지 못했어요.')
        source = { kind: 'article', articleIds: [article.id], ...(scope === 'selection' ? { selection: context.selection } : {}) }
      } else source = generationSource(context, scope)
      const sourceCourseId = source.kind === 'course' && project?.purpose === 'course-review' && project.linkedCourseId ? project.linkedCourseId : source.kind === 'article' || source.kind === 'vocabulary' ? binding?.courseId ?? context.courseId! : context.courseId!
      const result = await invoke('study:generate', { courseId: sourceCourseId, packId: entry.packId,
        ...(binding ? { binding } : {}), source: { ...source, sourceCourseId }, ...(options.ai ? { ai: options.ai } : {}) })
      rememberStartedLearningRun(result)
      openLearning(result.binding, 'review')
      return { status: 'started', ...result, message: `${entry.label}을 준비하고 있어요. 학습 공간에서 진행 상황을 볼 수 있어요.` }
    }
    if (scope !== 'course') await flushSourceNote(context)
    const result = context.browser && scope !== 'course'
      ? await invoke('study:run', { courseId: context.courseId!, tool: entry.packId, relPath: null,
          browserTabUrl: context.browser.url, browserTabId: context.browser.tabId,
          ...(scope === 'selection' ? { selection: context.selection } : {}), ...(options.followUp ? { followUpOf: entry.packId } : {}) })
      : await useStudyToolsStore.getState().run({ courseId: context.courseId!, tool: entry.packId,
          relPath: scope === 'course' ? null : context.savedMaterialRelPath ?? context.material?.relPath ?? null,
          ...(scope === 'selection' ? { selection: context.selection } : {}), ...(options.followUp ? { followUpOf: entry.packId } : {}) })
    window.setTimeout(() => { void useMaterialsStore.getState().loadTree(context.courseId!, { silent: true, refreshOnly: true }) }, 800)
    return { status: 'dispatched', courseId: context.courseId!, relPath: result.relPath, message: `생성을 요청했어요. 자료에 나타나면 열어 보세요: ${result.relPath}` }
  } catch (error) {
    return { status: 'failed', message: error instanceof Error ? error.message : '기능을 실행하지 못했어요.' }
  }
}
