import { randomUUID } from 'node:crypto'
import { posix } from 'node:path'
import type { LearningIpcContract, LearningGenerationSource } from '../../shared/ipc/learningContract'
import type { LearningBinding, LearningSourceRef, StartLearningRunInput, LearningAiSettings } from '../../shared/types/learning'
import type { WorkflowPack, WorkflowPackV2, WorkflowPackScope } from '../../shared/types/workflowPack'
import type { Course, WorkspaceKind } from '../../shared/types/course'
import { ConflictError, ValidationError } from '../db/errors'
import { requireId, requireNonEmptyString, resolveInside } from '../db/validate'
import { learningString, learningNumber, normalizeLearningArticle, validateLearningSettings, validateLearningAi, requireEnglishReadingSettings } from '../features/learning/validation'
import type { LearningRepo } from '../features/learning/learningRepo'
import type { createLearningRuntime } from '../features/learning/learningRuntime'
import type { createArticleExtractor } from '../features/learning/articleExtractor'
import { matchArticleWords } from '../features/learning/articleExtractor'
import type { createLearningCache } from '../features/learning/learningCache'
import type { createDictionaryService } from '../features/learning/dictionary'

type Handler = <K extends keyof LearningIpcContract>(channel: K, fn: (input: LearningIpcContract[K]['req']) => LearningIpcContract[K]['res'] | Promise<LearningIpcContract[K]['res']>) => void
interface LearningHandlerDeps {
  dictionary: ReturnType<typeof createDictionaryService>
  repo: LearningRepo
  runtime: ReturnType<typeof createLearningRuntime>
  extractor: ReturnType<typeof createArticleExtractor>
  cache: ReturnType<typeof createLearningCache>
  courses: { create(input: { name: string; color: string; workspaceKind?: WorkspaceKind }): Course; setWorkspaceKind(courseId: string, kind: WorkspaceKind): Course; list(input?: { includeArchived?: boolean; includeDeleted?: boolean }): Course[]; getById(id: string): Course;
    getByIdIncludingDeleted(id: string): Course; rename(input: { courseId: string; name: string }): Course;
    softDelete(input: { courseId: string }): { ok: true }; restore(input: { courseId: string }): Course }
  resolvePack(id: string): WorkflowPack | null
  approvePack(id: string, courseId: string): Promise<void>
  validateAi?(ai: LearningAiSettings): Promise<LearningAiSettings>
  changedCourse(): void
  deletedCourse?(courseId: string): void
  assertSourceTab(courseId: string, tabId: string, url: string): void
  resolveSource(binding: LearningBinding, ref: LearningSourceRef): Promise<{ relPath: string | null; missing: boolean; sourceCourseId?: string }>
  validateDraft?(binding: LearningBinding, draft: unknown): Promise<import('../../shared/types/learning').LearningDraft>
}

export function registerLearningHandlers(handle: Handler, deps: LearningHandlerDeps): void {
  handle('learning:lookupDictionary', input => deps.dictionary.lookup(input?.text))
  function nativePack(id: string, kind?: StartLearningRunInput['kind']): WorkflowPackV2 {
    const pack = deps.resolvePack(id)
    if (!pack || pack.schemaVersion !== 2) throw new ValidationError('이 학습 팩은 전용 학습 화면에서 사용할 수 없습니다.')
    const kinds: readonly StartLearningRunInput['kind'][] = pack.experience === 'article-vocabulary'
      ? ['find-articles', 'explain-word'] : pack.experience === 'quiz' ? ['create-quiz'] : ['create-cards']
    if (kind !== undefined && !kinds.includes(kind)) throw new ValidationError('이 팩은 요청한 학습 작업을 지원하지 않습니다.')
    return pack
  }
  async function authorizePack(id: string, courseId: string, kind: StartLearningRunInput['kind']): Promise<WorkflowPackV2> {
    const pack = nativePack(id, kind)
    await deps.approvePack(pack.id, courseId)
    // Approval can display a dialog; recheck an enabled pack before dispatch.
    return nativePack(pack.id, kind)
  }
  const reviewCreations = new Map<string, Promise<LearningBinding>>()
  async function selectedAi(value: unknown): Promise<LearningAiSettings> {
    const ai = validateLearningAi(value)
    if (!deps.validateAi) throw new ValidationError('AI 모델을 확인할 수 없습니다. 설정을 다시 열어 주세요.')
    return deps.validateAi(ai)
  }
  async function defaultBinding(courseId: string, ai?: LearningAiSettings, packId?: string, name?: string): Promise<LearningBinding> {
    const pending = reviewCreations.get(courseId)
    if (pending) return pending
    const task = (async () => {
      const original = deps.courses.getById(requireId(courseId, 'courseId'))
      if (original.workspaceKind === 'study-space') throw new ValidationError('복습할 원본 과목을 선택하세요.')
      // An explicitly restored old space must not replace the newer default.
      const spaces = deps.courses.list().sort((a, b) => b.createdAt.localeCompare(a.createdAt) || b.sortOrder - a.sortOrder)
      for (const course of spaces) {
        if (course.missing || course.workspaceKind !== 'study-space') continue
        const projects = await deps.repo.discover(course.id)
        const existing = projects.find(project => !project.warning && project.purpose === 'course-review' && project.linkedCourseId === courseId && project.binding.rootRelPath === '')
        if (existing) {
          if (!existing.ai && !ai) throw new ValidationError('복습 공간에서 사용할 AI를 먼저 선택하세요.')
          if (ai) await deps.repo.updateSettings({ binding: existing.binding, ai: await selectedAi(ai) })
          return existing.binding
        }
      }
      if (!ai) throw new ValidationError('복습 공간에서 사용할 AI를 먼저 선택하세요.')
      const checkedAi = await selectedAi(ai)
      const course = deps.courses.create({ name: name ?? `${original.name} 복습`, color: 'blue', workspaceKind: 'study-space' })
      const binding = { courseId: course.id, rootRelPath: '' }
      await deps.repo.create({ binding, name: course.name, topic: original.name, purpose: 'course-review', linkedCourseId: courseId,
        topicIds: [], readingSetupConfirmed: false, ai: checkedAi, ...(packId ? { packId } : {}) })
      deps.changedCourse()
      return binding
    })()
    reviewCreations.set(courseId, task)
    try { return await task } finally { if (reviewCreations.get(courseId) === task) reviewCreations.delete(courseId) }
  }
  function assertSourceCourse(binding: LearningBinding, sourceCourseId: string, linkedCourseId?: string): void {
    requireId(sourceCourseId, 'sourceCourseId')
    if (sourceCourseId !== binding.courseId && sourceCourseId !== linkedCourseId) throw new ValidationError('이 학습 공간에 연결되지 않은 과목입니다.')
    deps.courses.getById(sourceCourseId)
  }
  handle('learning:list', async input => {
    if (input.courseId) input.includeDeleted ? deps.courses.getByIdIncludingDeleted(input.courseId) : deps.courses.getById(input.courseId)
    const courses = deps.courses.list(input.includeDeleted ? { includeDeleted: true } : {})
    const projects = []
    for (const course of courses) {
      if (course.missing || (course.deletedAt && course.workspaceKind !== 'study-space')) continue
      const found = await deps.repo.discover(course.id, { includeDeleted: input.includeDeleted === true })
      if (course.deletedAt) for (const project of found) project.deletedAt ??= course.deletedAt
      deps.cache.replaceCourse(course.id, found.filter(project => !project.deletedAt))
      projects.push(...found.filter(project => !input.courseId || project.binding.courseId === input.courseId || project.linkedCourseId === input.courseId))
    }
    return { projects }
  })
  function assertRevision(input: { expectedRevision?: number }, current: { revision: number }): void {
    if (input.expectedRevision !== undefined && input.expectedRevision !== current.revision) throw new ConflictError('학습 공간이 변경되었습니다. 최신 상태를 불러와 주세요.')
  }
  const lifecycleRequests = new Map<string, Promise<unknown>>()
  async function lifecycle<T>(binding: LearningBinding, work: () => Promise<T>): Promise<T> {
    const key = JSON.stringify([binding.courseId, posix.normalize(binding.rootRelPath || '.')])
    const previous = lifecycleRequests.get(key) ?? Promise.resolve()
    const task = previous.catch(() => undefined).then(work)
    lifecycleRequests.set(key, task)
    try { return await task } finally { if (lifecycleRequests.get(key) === task) lifecycleRequests.delete(key) }
  }
  handle('learning:rename', input => lifecycle(input.binding, async () => {
    const name = learningString(input.name, 'name', 1_000).trim()
    if (!name) throw new ValidationError('학습 공간 이름을 입력하세요.')
    const current = await deps.repo.read(input.binding)
    assertRevision(input, current)
    const course = deps.courses.getById(input.binding.courseId)
    const saved = await deps.repo.rename({ ...input, name, expectedRevision: input.expectedRevision ?? current.revision })
    if (input.binding.rootRelPath === '' && course.workspaceKind === 'study-space') {
      deps.courses.rename({ courseId: course.id, name }); deps.changedCourse()
    }
    return saved
  }))
  handle('learning:delete', input => lifecycle(input.binding, async () => {
    const current = await deps.repo.readDeleted(input.binding)
    assertRevision(input, current)
    return deps.runtime.withProjectPaused(input.binding, async () => {
      const latest = await deps.repo.readDeleted(input.binding)
      const course = deps.courses.getByIdIncludingDeleted(input.binding.courseId)
      const saved = await deps.repo.delete({ binding: input.binding, expectedRevision: latest.revision })
      deps.cache.index(saved)
      if (input.binding.rootRelPath === '' && course.workspaceKind === 'study-space' && !course.deletedAt) {
        deps.courses.softDelete({ courseId: course.id }); deps.deletedCourse?.(course.id); deps.changedCourse()
      }
      return { ok: true as const }
    })
  }))
  handle('learning:restore', input => lifecycle(input.binding, async () => {
    const current = await deps.repo.readDeleted(input.binding)
    assertRevision(input, current)
    return deps.runtime.withProjectPaused(input.binding, async () => {
      const course = deps.courses.getByIdIncludingDeleted(input.binding.courseId)
      const restoreCourse = input.binding.rootRelPath === '' && course.workspaceKind === 'study-space' && !!course.deletedAt
      if (course.deletedAt && !restoreCourse) throw new ValidationError('원본 과목을 먼저 복원해야 합니다.')
      if (restoreCourse) deps.courses.restore({ courseId: course.id })
      try {
        const latest = await deps.repo.readDeleted(input.binding)
        const saved = await deps.repo.restore({ binding: input.binding, expectedRevision: latest.revision })
        deps.cache.index(saved)
        if (input.binding.rootRelPath === '' && course.workspaceKind === 'study-space') {
          deps.courses.rename({ courseId: course.id, name: saved.name }); deps.changedCourse()
        }
        return saved
      } catch (error) {
        if (restoreCourse) { deps.courses.softDelete({ courseId: course.id }); deps.changedCourse() }
        throw error
      }
    })
  }))
  handle('learning:dismissRun', input => deps.repo.dismissRun(input))
  handle('learning:create', async input => {
    if (!['standalone', 'in-course'].includes(input.placement)) throw new ValidationError('학습 공간 위치를 선택하세요.')
    const name = requireNonEmptyString(input.name, 'name')
    learningString(name, 'name', 1_000)
    learningString(input.topic, 'topic', 10_000)
    if (input.level !== undefined && !['beginner', 'intermediate', 'advanced'].includes(input.level)) throw new ValidationError('학습 수준을 선택하세요.')
    if (input.readingMinutes !== undefined) learningNumber(input.readingMinutes, 'readingMinutes', 1, 30)
    const settings = validateLearningSettings(input)
    if (settings.purpose === 'english-reading') {
      if (input.placement !== 'standalone') throw new ValidationError('새 영어 읽기는 독립 학습 공간으로 만드세요.')
      requireEnglishReadingSettings(settings, input.level, input.readingMinutes)
    }
    if (settings.purpose === 'course-review') {
      if (input.placement !== 'standalone' || !settings.linkedCourseId) throw new ValidationError('복습할 원본 과목을 선택하세요.')
      return deps.repo.read(await defaultBinding(settings.linkedCourseId, settings.ai, settings.packId, name))
    }
    if (settings.ai) settings.ai = await selectedAi(settings.ai)
    if (settings.linkedCourseId) deps.courses.getById(settings.linkedCourseId)
    let binding: LearningBinding
    if (input.placement === 'standalone') {
      const course = deps.courses.create({ name, color: 'blue', workspaceKind: 'study-space' })
      binding = { courseId: course.id, rootRelPath: '' }
      deps.changedCourse()
    } else {
      const courseId = requireId(input.courseId, 'courseId')
      deps.courses.getById(courseId)
      const rootRelPath = input.rootRelPath ?? name.replace(/[/\\:*?"<>|]/g, '').trim()
      if (!rootRelPath) throw new ValidationError('학습 폴더 이름을 입력하세요.')
      resolveInside('/learning', rootRelPath)
      binding = { courseId, rootRelPath }
    }
    return deps.repo.create({ binding, name, topic: input.topic, ...settings, ...(input.level ? { level: input.level } : {}), ...(input.readingMinutes === undefined ? {} : { readingMinutes: input.readingMinutes }) })
  })
  handle('learning:updateSettings', async input => {
    const current = await deps.repo.read(input.binding)
    const settings = validateLearningSettings(input)
    if (settings.ai) settings.ai = await selectedAi(settings.ai)
    if (settings.purpose === 'english-reading' && !current.readingSetupConfirmed) requireEnglishReadingSettings({ ...current, ...settings }, input.level, input.readingMinutes)
    if (settings.purpose === 'course-review') {
      if (!settings.ai && !current.ai) throw new ValidationError('복습 공간에서 사용할 AI를 선택하세요.')
      settings.readingSetupConfirmed = false; settings.topicIds = []
    }
    if (settings.linkedCourseId) deps.courses.getById(settings.linkedCourseId)
    if (input.workspaceKind !== undefined && (input.binding.rootRelPath !== '' || !['course', 'study-space'].includes(input.workspaceKind))) throw new ValidationError('폴더 전체의 공간 분류를 명시적으로 확인하세요.')
    const snapshot = await deps.repo.updateSettings({ ...input, ...settings, expectedRevision: input.expectedRevision ?? current.revision })
    if (input.workspaceKind !== undefined) {
      deps.courses.setWorkspaceKind(input.binding.courseId, input.workspaceKind)
      deps.changedCourse()
    }
    return snapshot
  })
  handle('learning:get', async input => {
    const snapshot = await deps.runtime.recover(input.binding)
    deps.cache.index(snapshot)
    return snapshot
  })
  handle('learning:getArticle', input => deps.repo.readArticle(input.binding, input.id))
  handle('learning:getArtifact', input => deps.repo.readArtifact(input.binding, input.id))
  handle('learning:resolveSource', input => deps.resolveSource(input.binding, input.sourceRef))
  handle('learning:addArticle', async input => {
    const sourceCourseId = input.sourceCourseId ?? input.binding.courseId
    // Imported public article snapshots are owned by the chosen destination;
    // a live tab's origin is checked without linking the source course's files.
    if (input.tabId) deps.assertSourceTab(requireId(sourceCourseId, 'sourceCourseId'), input.tabId, input.url)
    const article = input.tabId ? await deps.extractor.extractSourceTab(input.tabId) : await deps.extractor.extractUrl(input.url)
    const state = await deps.repo.read(input.binding)
    article.matchedWordIds = [...new Set(matchArticleWords(article, state.words.map(word => ({ id: word.id, surface: word.surface, forms: [word.lemma,
      ...state.occurrences.filter(occurrence => occurrence.wordId === word.id).map(occurrence => occurrence.surface)] }))).map(match => match.wordId))]
    const normalized = normalizeLearningArticle(article, article.id ?? randomUUID(), new Date().toISOString())
    const snapshot = await deps.repo.addArticle({ binding: input.binding, article: { ...article, ...normalized } })
    // Resolve the exact repository deduplication identity, including a mirrored
    // article already retained under another source URL.
    const added = snapshot.articles.find(item => item.canonicalUrl === normalized.canonicalUrl || item.contentHash === normalized.contentHash)
    if (!added) throw new Error('저장한 기사 식별자를 찾지 못했습니다.')
    return { ...snapshot, addedArticleId: added.id }
  })
  handle('learning:saveWord', input => deps.repo.saveWord(input))
  handle('learning:updateWord', input => deps.repo.updateWord(input))
  handle('learning:updateOccurrence', input => deps.repo.updateOccurrence(input))
  handle('learning:saveProgress', input => deps.repo.saveProgress(input))
  handle('learning:completeArticle', input => deps.repo.completeArticle(input))
  handle('learning:saveQuizAnswer', input => deps.repo.saveQuizAnswer(input))
  handle('learning:finishQuiz', input => deps.repo.finishQuiz(input))
  handle('learning:reviewCard', input => deps.repo.reviewCard(input))
  handle('learning:run', async input => {
    if (input.packId !== undefined) await authorizePack(input.packId, input.binding.courseId, input.kind)
    return deps.runtime.start(input)
  })
  handle('learning:runCancel', input => deps.runtime.cancel(input.binding, input.runId))
  handle('learning:runRetry', async input => {
    const project = await deps.repo.read(input.binding)
    const run = project.runs.find(item => item.id === input.runId)
    if (!run) throw new ValidationError('다시 실행할 학습 작업을 찾지 못했습니다.')
    if (run.packId !== undefined) await authorizePack(run.packId, input.binding.courseId, run.kind)
    return deps.runtime.retry(input.binding, input.runId)
  })
  handle('learning:importPreview', async input => {
    const project = await deps.repo.read(input.binding)
    const sourceCourseId = input.sourceCourseId ?? input.binding.courseId
    assertSourceCourse(input.binding, sourceCourseId, project.linkedCourseId)
    return deps.runtime.start({ binding: input.binding, kind: 'import-material', source: { kind: 'material', relPath: input.relPath, sourceCourseId } })
  })
  handle('learning:importSave', async input => {
    if (!input.runId) throw new ValidationError('가져오기 미리보기를 먼저 실행하세요.')
    const project = await deps.repo.read(input.binding)
    const run = project.runs.find(item => item.id === input.runId)
    if (run?.status === 'complete') return project
    if (run?.status !== 'awaiting-confirmation' || !run.draft) throw new ValidationError('저장할 가져오기 미리보기가 없습니다.')
    const draft = deps.validateDraft ? await deps.validateDraft(input.binding, input.draft) : run.draft
    return deps.repo.importDraft({ binding: input.binding, draft, runId: run.id })
  })
  handle('study:generate', async input => {
    const pack = nativePack(input.packId)
    const source: LearningGenerationSource = input.source ?? { kind: 'course' }
    const kind: StartLearningRunInput['kind'] = pack.experience === 'article-vocabulary' ? 'find-articles' : pack.experience === 'quiz' ? 'create-quiz' : 'create-cards'
    // Saved articles/vocabulary are project materials. Live browser-tab sources
    // are added through the validated article import endpoint, not this DTO.
    const scope: WorkflowPackScope = source.selection?.trim() ? 'selection' : source.kind === 'course' ? 'course' : 'material'
    if (!pack.worksOn.includes(scope)) throw new ValidationError('이 팩은 선택한 자료 범위에서 사용할 수 없습니다.')
    if (source.kind === 'material' && !source.relPath?.trim()) throw new ValidationError('대상 자료를 선택하세요.')
    if (source.relPath && (posix.isAbsolute(source.relPath) || source.relPath.split('/').includes('..'))) throw new ValidationError('올바른 자료 경로가 필요합니다.')
    const authorized = await authorizePack(pack.id, input.courseId, kind)
    if (!authorized.worksOn.includes(scope)) throw new ValidationError('이 팩은 선택한 자료 범위에서 사용할 수 없습니다.')
    if (kind === 'find-articles' && !input.binding && input.rootRelPath === undefined) throw new ValidationError('영어 읽기 공간을 먼저 만들고 읽기 설정을 확인하세요.')
    const binding = input.binding ?? (input.rootRelPath === undefined ? await defaultBinding(input.courseId, input.ai, pack.id) : { courseId: input.courseId, rootRelPath: input.rootRelPath })
    const project = await deps.repo.read(binding)
    const sourceCourseId = source.sourceCourseId ?? input.courseId
    assertSourceCourse(binding, sourceCourseId, project.linkedCourseId)
    if ((source.kind === 'article' || source.kind === 'vocabulary') && sourceCourseId !== binding.courseId) throw new ValidationError('기사와 단어는 현재 학습 공간의 기록에서 선택하세요.')
    if (source.kind === 'course' || source.kind === 'material') source.sourceCourseId = sourceCourseId
    if (input.ai && input.binding) await deps.repo.updateSettings({ binding, ai: await selectedAi(input.ai) })
    return deps.runtime.start({ binding, kind, packId: pack.id, source, ...(source.articleIds ? { articleIds: source.articleIds } : {}), ...(source.wordIds ? { wordIds: source.wordIds } : {}) })
  })
}
