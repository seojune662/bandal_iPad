import './ai/abort'
import { createLearningRepo } from '../upstream/src/main/features/learning/learningRepo'
import { createLearningCache } from '../upstream/src/main/features/learning/learningCache'
import { createLearningRuntime } from '../upstream/src/main/features/learning/learningRuntime'
import { createLearningGrounding } from '../upstream/src/main/features/learning/learningGrounding'
import { normalizeLearningDraft } from '../upstream/src/main/features/learning/validation'
import { buildArticleSnapshot, matchArticleWords } from '../upstream/src/main/features/learning/articleExtractor'
import { registerLearningHandlers } from '../upstream/src/main/ipc/learningHandlers'
import type { LearningBinding, LearningDraft } from '../upstream/src/shared/types/learning'
import type { installAI } from './ai'
import { platform } from './ai/adapter'
import { emit } from './native'

export function installLearning(deps: { db: any; courses: any; packs: any; handle: (channel: string, fn: (req: any) => any) => void; changed: () => void; changedMaterials: (courseId: string) => void }) {
  let ai: ReturnType<typeof installAI> | undefined
  const connected = () => { if (!ai) throw new Error('학습 AI 연결을 준비 중입니다.'); return ai }
  const cache = createLearningCache(deps.db)
  const repo = createLearningRepo({ getCourseFolder: id => deps.courses.getFolder(id),
    getCourseFolderIncludingDeleted: id => deps.courses.getFolderIncludingDeleted(id),
    listCourseIds: () => deps.courses.list().map((course: any) => course.id),
    onChanged: binding => { emit('learning:changed', { binding }); deps.changedMaterials(binding.courseId) } })
  const grounding = createLearningGrounding(id => deps.courses.getFolder(id))
  function validateRefs(result: LearningDraft) {
    const refs = [...(result.words?.map(word => word.sourceRef) ?? []), ...(result.artifacts?.flatMap(artifact => [
      ...(artifact.sourceRefs ?? []), ...(artifact.kind === 'quiz' ? artifact.questions.flatMap(question => question.sourceRefs) : artifact.kind === 'cards' ? artifact.cards.flatMap(card => card.sourceRefs) : [])
    ]) ?? [])]
    if (refs.some(ref => ref.kind === 'web')) throw new Error('웹 출처는 가져온 기사 본문의 근거 문장으로 연결하세요.')
    return result
  }
  const sourceTabs = new Map<string, { courseId: string; url: string }>()
  async function extract(input: { url: string; courseId?: string; tabId?: string }, signal?: AbortSignal) {
    const check = () => { if (signal?.aborted) throw Object.assign(new Error('기사 읽기를 중지했어요.'), { name: 'AbortError' }) }
    check()
    const result = await platform('native:learningExtract', input)
    check()
    if (result.access !== (input.tabId ? 'source-tab' : 'public') || typeof result.sourceUrl !== 'string') throw new Error('기사 출처를 확인하지 못했어요.')
    return buildArticleSnapshot(result.raw, result.sourceUrl, result.access)
  }
  const extractor = {
    extractUrl: (url: string, signal?: AbortSignal) => extract({ url }, signal),
    extractSourceTab: async (tabId: string) => {
      const source = sourceTabs.get(tabId); sourceTabs.delete(tabId)
      if (!source) throw new Error('원본 브라우저 탭이 확인되지 않았습니다.')
      return extract({ ...source, tabId })
    }
  }
  const runtime = createLearningRuntime({ repo, extractUrl: extractor.extractUrl, matchWords: matchArticleWords,
    validateDraft: async (draft, state) => validateRefs(await normalizeLearningDraft(draft, state,
      id => repo.readArticle(state.binding, id), grounding.validator(state.binding, state.linkedCourseId))),
    resolveAi: value => connected().validateLearningAi(value),
    modelRejected: (provider, model) => connected().rejectModel(provider, model),
    recipe: (packId, kind) => {
      const id = packId ?? (kind === 'find-articles' ? 'vocab-chain-en' : kind === 'create-quiz' ? 'quiz' : kind === 'create-cards' ? 'flashcards' : undefined)
      if (!id) return ''
      const pack = deps.packs.resolve(id)
      if (!pack || pack.schemaVersion !== 2) throw new Error('학습 팩을 사용할 수 없어요. 플러그인 설정을 확인하세요.')
      return pack.recipe
    },
    tools: packId => packId ? deps.packs.resolve(packId)?.allowedTools ?? [] : [
      'learning_verify_article', 'learning_submit_result', 'read_material', 'list_materials', 'app_state',
      'browser_tabs', 'browser_open', 'browser_snapshot', 'browser_read', 'browser_scroll', 'browser_handoff'
    ],
    sourceText: async (binding, source) => {
      if (source?.kind !== 'material') return source?.selection ?? ''
      if (!source.relPath) throw new Error('대상 자료를 선택하세요.')
      const material = await grounding.material(binding, source.relPath, source.sourceCourseId, source.selection ? source.page : undefined)
      if (source.selection && !material.text.replace(/\s+/gu, ' ').includes(source.selection.replace(/\s+/gu, ' ').trim())) throw new Error('선택한 내용이 원본 자료와 일치하지 않아요.')
      return JSON.stringify({ relPath: source.relPath, pathScope: 'course', ...(source.sourceCourseId ? { sourceCourseId: source.sourceCourseId } : {}), ...(source.page === undefined ? {} : { page: source.page }), contentHash: material.contentHash, text: source.selection ?? material.text, truncated: material.truncated })
    },
    send: (courseId, sessionId, provider, prompt, value) => connected().sendLearning(courseId, sessionId, provider, prompt, value),
    cancel: (courseId, sessionId, provider) => { const api = connected(); api.confirmer.cancelConversation(sessionId); api.managers[provider].cancel(courseId, sessionId) },
    close: (courseId, sessionId, provider) => connected().managers[provider].close(courseId, sessionId)
  })
  registerLearningHandlers(deps.handle as any, {
    repo, runtime, cache, courses: deps.courses, changedCourse: deps.changed,
    dictionary: { lookup: (text: string) => platform('native:learningDictionary', { text }) } as any,
    extractor: extractor as any, resolvePack: id => deps.packs.resolve(id),
    approvePack: async (id, courseId) => {
      const summary = deps.packs.list().find((item: any) => item.pack.id === id)
      if (!summary || !summary.enabled) throw new Error('학습 팩을 사용할 수 없어요.')
      if (summary.source === 'builtin' || summary.approvedAt) return
      deps.courses.getById(courseId)
      const answer = await platform('native:learningApprovePack', { id, courseId, name: summary.pack.name, version: summary.pack.version, description: summary.pack.description })
      if (!answer || ![1, 2].includes(answer.response)) throw new Error('학습 팩 실행이 취소되었습니다.')
      if (answer.response === 2) deps.packs.approve(id, new Date().toISOString())
    },
    validateAi: value => connected().validateLearningAi(value),
    assertSourceTab: (courseId, tabId, url) => { deps.courses.getById(courseId); sourceTabs.set(tabId, { courseId, url }) },
    resolveSource: async (binding, source) => grounding.resolve(binding, source, (await repo.read(binding)).linkedCourseId),
    validateDraft: async (binding, draft) => {
      const state = await repo.read(binding)
      const result = await normalizeLearningDraft(draft, state, id => repo.readArticle(binding, id), grounding.validator(binding, state.linkedCourseId))
      if (result.articles?.length || result.wordUpdates?.length) throw new Error('가져오기에서는 퀴즈·카드·학습노트만 저장할 수 있어요.')
      return validateRefs(result)
    }
  })
  return { repo, runtime, pauseProject: <T>(binding: LearningBinding, work: () => Promise<T>) => runtime.withProjectPaused(binding, work),
    connectAI(value: ReturnType<typeof installAI>) { ai = value; value.connectLearning(runtime) } }
}
