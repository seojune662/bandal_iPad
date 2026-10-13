import type {
  LearningBinding, LearningProjectSnapshot, LearningProjectSummary, LearningArticleSnapshot,
  LearningArtifact, LearningLevel, LearningSourceRef, SaveLearningWordInput, UpdateLearningWordInput,
  SaveLearningProgressInput, CompleteLearningArticleInput, SaveLearningQuizAnswerInput,
  FinishLearningQuizInput, ReviewLearningCardInput, StartLearningRunInput, ImportLearningDraftInput, LearningMaterialRequest,
  LearningProjectSettings, LearningAiSettings, UpdateLearningSettingsInput, LearningMutation, RenameLearningProjectInput, DismissLearningRunInput
} from '../types/learning'
import type { DictionaryLookupResult } from '../types/dictionary'

export interface LearningGenerationSource {
  kind: 'course' | 'material' | 'article' | 'vocabulary'
  relPath?: string
  selection?: string
  page?: number
  articleIds?: string[]
  wordIds?: string[]
  sourceCourseId?: string
}
export interface LearningRunResult { runId: string; binding: LearningBinding }
export interface LearningIpcContract {
  'learning:lookupDictionary': { req: { text: string }; res: DictionaryLookupResult }
  'learning:list': { req: { courseId?: string; includeDeleted?: boolean }; res: { projects: LearningProjectSummary[] } }
  'learning:rename': { req: RenameLearningProjectInput; res: LearningProjectSnapshot }
  'learning:delete': { req: LearningMutation; res: { ok: true } }
  'learning:restore': { req: LearningMutation; res: LearningProjectSnapshot }
  'learning:dismissRun': { req: DismissLearningRunInput; res: LearningProjectSnapshot }
  'learning:create': {
    req: Partial<LearningProjectSettings> & { placement: 'standalone' | 'in-course'; courseId?: string; rootRelPath?: string; name: string; topic: string; level?: LearningLevel; readingMinutes?: number }
    res: LearningProjectSnapshot
  }
  'learning:get': { req: { binding: LearningBinding }; res: LearningProjectSnapshot }
  'learning:updateSettings': { req: UpdateLearningSettingsInput; res: LearningProjectSnapshot }
  'learning:getArticle': { req: LearningMaterialRequest; res: LearningArticleSnapshot }
  'learning:getArtifact': { req: LearningMaterialRequest; res: LearningArtifact }
  'learning:resolveSource': { req: { binding: LearningBinding; sourceRef: LearningSourceRef }; res: { relPath: string | null; missing: boolean; sourceCourseId?: string } }
  'learning:addArticle': { req: { binding: LearningBinding; url: string; tabId?: string; sourceCourseId?: string }; res: LearningProjectSnapshot & { addedArticleId: string } }
  'learning:saveWord': { req: SaveLearningWordInput; res: LearningProjectSnapshot }
  'learning:updateWord': { req: UpdateLearningWordInput; res: LearningProjectSnapshot }
  'learning:updateOccurrence': { req: { binding: LearningBinding; occurrenceId: string; meaning: string; expectedRevision?: number }; res: LearningProjectSnapshot }
  'learning:saveProgress': { req: SaveLearningProgressInput; res: LearningProjectSnapshot }
  'learning:completeArticle': { req: CompleteLearningArticleInput; res: LearningProjectSnapshot }
  'learning:saveQuizAnswer': { req: SaveLearningQuizAnswerInput; res: LearningProjectSnapshot }
  'learning:finishQuiz': { req: FinishLearningQuizInput; res: LearningProjectSnapshot }
  'learning:reviewCard': { req: ReviewLearningCardInput; res: LearningProjectSnapshot }
  'learning:run': { req: StartLearningRunInput; res: LearningRunResult }
  'learning:runCancel': { req: { binding: LearningBinding; runId: string }; res: LearningProjectSnapshot }
  'learning:runRetry': { req: { binding: LearningBinding; runId: string }; res: LearningRunResult }
  'learning:importPreview': { req: { binding: LearningBinding; relPath: string; sourceCourseId?: string }; res: LearningRunResult }
  'learning:importSave': { req: ImportLearningDraftInput; res: LearningProjectSnapshot }
  'study:generate': {
    req: { courseId: string; packId: string; binding?: LearningBinding; rootRelPath?: string; source?: LearningGenerationSource; ai?: LearningAiSettings }
    res: LearningRunResult
  }
}

export const LEARNING_CHANNELS = [
  'learning:lookupDictionary',
  'learning:list', 'learning:rename', 'learning:delete', 'learning:restore', 'learning:dismissRun', 'learning:create', 'learning:get', 'learning:updateSettings', 'learning:getArticle', 'learning:getArtifact',
  'learning:resolveSource', 'learning:addArticle', 'learning:saveWord', 'learning:updateWord', 'learning:updateOccurrence', 'learning:saveProgress',
  'learning:completeArticle', 'learning:saveQuizAnswer', 'learning:finishQuiz', 'learning:reviewCard',
  'learning:run', 'learning:runCancel', 'learning:runRetry', 'learning:importPreview', 'learning:importSave', 'study:generate'
] as const satisfies readonly (keyof LearningIpcContract)[]
