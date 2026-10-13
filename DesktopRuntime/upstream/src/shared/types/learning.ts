/** Portable learning records. Persisted paths are relative to the project root. */
import type { AgentProvider } from './agent-events'
import type { WorkspaceKind } from './course'
import type { DictionarySource } from './dictionary'

export interface LearningBinding { courseId: string; rootRelPath: string }
export type LearningPurpose = 'english-reading' | 'course-review' | 'unclassified'
export const LEARNING_TOPICS = [
  { id: 'science', label: '과학' }, { id: 'space', label: '우주' },
  { id: 'technology-ai', label: '기술·AI' }, { id: 'environment', label: '환경' },
  { id: 'health', label: '건강' }, { id: 'psychology', label: '심리' },
  { id: 'business-economy', label: '경제·비즈니스' }, { id: 'society-culture', label: '사회·문화' },
  { id: 'history', label: '역사' }, { id: 'arts-design', label: '예술·디자인' },
  { id: 'sports', label: '스포츠' }, { id: 'travel', label: '여행' },
  { id: 'food', label: '음식' }, { id: 'career', label: '커리어' }
] as const
export interface LearningAiSettings { provider: AgentProvider; model: string; effort: string | null }
export interface LearningProjectSettings {
  purpose: LearningPurpose
  topicIds: string[]
  readingSetupConfirmed: boolean
  ai: LearningAiSettings
  linkedCourseId?: string
  packId?: string
}
export type LearningLevel = 'beginner' | 'intermediate' | 'advanced'
export interface LearningSentence { id: string; text: string; start: number; end: number }
export interface LearningParagraph { id: string; text: string; sentences: LearningSentence[] }
export interface LearningArticleInput {
  id?: string
  sourceUrl: string
  canonicalUrl?: string
  title: string
  byline?: string | null
  publishedAt?: string | null
  siteName?: string | null
  language?: string
  wordCount?: number
  estimatedMinutes?: number
  paragraphs: LearningParagraph[]
  contentHash?: string
  fetchedAt?: string
  access?: 'public' | 'source-tab'
  matchedWordIds?: string[]
}
export interface LearningArticleSnapshot {
  id: string
  sourceUrl: string
  canonicalUrl: string
  title: string
  byline: string | null
  publishedAt: string | null
  siteName: string | null
  language: string
  wordCount: number
  estimatedMinutes: number
  paragraphs: LearningParagraph[]
  contentHash: string
  fetchedAt: string
  access: 'public' | 'source-tab'
  createdAt: string
}
export interface LearningArticleRef {
  id: string; title: string; sourceUrl: string; canonicalUrl: string
  snapshotRelPath: string; exportRelPath: string | null; contentHash: string
  wordCount: number; estimatedMinutes: number; createdAt: string
  status: 'unread' | 'reading' | 'completed'
  progress: { paragraphId: string | null; scrollFraction: number }
  completedAt: string | null
  matchedWordIds: string[]
}
export interface LearningSourceRef {
  kind: 'article' | 'material' | 'web'
  quote: string
  articleId?: string
  paragraphId?: string
  sentenceId?: string
  start?: number
  end?: number
  relPath?: string
  pathScope?: 'project' | 'course'
  /** Original course for sources retained in an independent review workspace. */
  sourceCourseId?: string
  contentHash?: string
  /** Computed by the host when resolving a citation; never replaces the retained quote. */
  availability?: 'available' | 'missing' | 'changed'
  url?: string
  title?: string
  page?: number
}
export type LearningWordStatus = 'new' | 'learning' | 'known'
export interface LearningWord {
  id: string; surface: string; lemma: string; meaning: string; pronunciation: string
  partOfSpeech: string; status: LearningWordStatus; createdAt: string; updatedAt: string
  dictionarySource?: DictionarySource
}
export interface LearningOccurrence {
  id: string; wordId: string; surface: string; sentence: string
  sourceRef: LearningSourceRef; meaning: string; createdAt: string
  dictionarySource?: DictionarySource
}
export interface LearningQuizQuestion {
  id: string; type: 'choice' | 'cloze' | 'short-answer'; prompt: string
  options?: Array<{ id: string; text: string }>
  answer: string; acceptedAnswers?: string[]; explanation: string
  modelAnswer?: string; checkingPoints?: string[]
  sourceRefs: LearningSourceRef[]; wordId?: string
}
export interface LearningCardDefinition {
  id: string; front: string; back: string; sourceRefs: LearningSourceRef[]; wordId?: string
}
export interface LearningArtifactRef {
  id: string; kind: 'quiz' | 'cards' | 'summary'; title: string
  relPath: string; exportRelPath: string | null; createdAt: string
  contentHash: string
  sourceRefs: LearningSourceRef[]; articleIds: string[]; wordIds: string[]
}
interface LearningArtifactBase {
  id: string; schemaVersion: 1; revision: number; title: string; createdAt: string; sourceRefs: LearningSourceRef[]
  articleIds: string[]; wordIds: string[]
}
export type LearningArtifact =
  | (LearningArtifactBase & { kind: 'quiz'; questions: LearningQuizQuestion[] })
  | (LearningArtifactBase & { kind: 'cards'; cards: LearningCardDefinition[] })
  | (LearningArtifactBase & { kind: 'summary'; markdown: string })
export type LearningArtifactDraft =
  | { kind: 'quiz'; id?: string; title: string; questions: LearningQuizQuestion[]; sourceRefs?: LearningSourceRef[]; articleIds?: string[]; wordIds?: string[] }
  | { kind: 'cards'; id?: string; title: string; cards: LearningCardDefinition[]; sourceRefs?: LearningSourceRef[]; articleIds?: string[]; wordIds?: string[] }
  | { kind: 'summary'; id?: string; title: string; markdown: string; sourceRefs?: LearningSourceRef[]; articleIds?: string[]; wordIds?: string[] }
export interface LearningCard extends LearningCardDefinition {
  artifactId: string; status: 'new' | 'learning' | 'review'
  dueAt: string; intervalDays: number; repetitions: number; lapses: number; lastReviewedAt: string | null
}
export type LearningCardRating = 'again' | 'hard' | 'good'
export interface LearningQuizAnswer {
  questionId: string; answer: string; correct: boolean | null; answeredAt: string; selfCheck?: boolean
}
export interface LearningQuizAttempt {
  id: string; artifactId: string; answers: LearningQuizAnswer[]
  startedAt: string; completedAt: string | null; score: number; total: number
  selfCheckedCount: number; selfPassedCount: number
  resultRelPath: string | null
}
export type LearningRunKind = 'find-articles' | 'explain-word' | 'create-quiz' | 'create-cards' | 'create-summary' | 'import-material'
export interface LearningRunSource {
  kind: 'course' | 'material' | 'article' | 'vocabulary'
  relPath?: string; selection?: string; articleIds?: string[]; wordIds?: string[]
  page?: number
  sourceCourseId?: string
}
export interface LearningWordDraft {
  surface: string; lemma?: string; meaning?: string; pronunciation?: string; partOfSpeech?: string
  sentence: string; sourceRef: LearningSourceRef
  dictionarySource?: DictionarySource
}
export interface LearningDraft {
  version: 1
  articles?: LearningArticleInput[]
  artifacts?: LearningArtifactDraft[]
  words?: LearningWordDraft[]
  wordUpdates?: Array<{ wordId: string; occurrenceId?: string; meaning: string; lemma?: string; pronunciation?: string; partOfSpeech?: string }>
}
export interface LearningRun {
  id: string; kind: LearningRunKind
  packId?: string
  purpose?: LearningPurpose
  topicIds?: string[]
  readingSetupConfirmed?: boolean
  status: 'queued' | 'running' | 'validating' | 'interrupted' | 'awaiting-confirmation' | 'complete' | 'failed' | 'cancelled'
  provider: string; articleIds: string[]; wordIds: string[]
  model?: string; effort?: string | null; sessionId?: string
  errorCode?: string
  errorCategory?: 'connection' | 'model' | 'quota' | 'network' | 'tool' | 'source' | 'validation' | 'timeout' | 'cancelled' | 'unknown'
  actionable?: string
  /** Hides a terminal failure notice without discarding the execution history. */
  dismissedAt?: string | null
  /** Exact host-published results, distinct from input/source IDs. */
  resultArticleIds?: string[]
  resultArtifactIds?: string[]
  source?: LearningRunSource
  message: string; error: string | null; draft: LearningDraft | null
  createdAt: string; updatedAt: string
}
export interface LearningHistoryEntry {
  id: string; kind: 'article-added' | 'article-completed' | 'word-saved' | 'artifact-created' | 'quiz-completed' | 'card-reviewed'
  entityId: string; createdAt: string; summary: string; resultRelPath?: string
}
export interface LearningProjectState extends Partial<LearningProjectSettings> {
  schemaVersion: 1; projectId: string; revision: number
  name: string; topic: string; level: LearningLevel; readingMinutes: number
  createdAt: string; updatedAt: string
  /** List removal is portable and retains every article, result and export. */
  deletedAt?: string | null
  articles: LearningArticleRef[]; words: LearningWord[]; occurrences: LearningOccurrence[]
  artifacts: LearningArtifactRef[]; cards: LearningCard[]; quizAttempts: LearningQuizAttempt[]
  runs: LearningRun[]; history: LearningHistoryEntry[]
  exports: Array<{ relPath: string; contentHash: string }>
  /** Immutable source citations resolve through subsequent filesystem moves. */
  pathAliases?: Array<{ fromRelPath: string; toRelPath: string; isDirectory: boolean; scope: 'project' | 'course'; sourceCourseId?: string }>
}
export interface LearningProjectSnapshot extends LearningProjectState {
  binding: LearningBinding
  recovery: 'none' | 'previous'
  warnings: string[]
}
export interface LearningProjectSummary extends Partial<LearningProjectSettings> {
  binding: LearningBinding; projectId: string; name: string; topic: string
  level: LearningLevel; readingMinutes: number; articleCount: number; completedArticleCount: number
  wordCount: number; knownWordCount: number; dueCardCount: number; updatedAt: string
  warning: string | null
  deletedAt?: string | null
}
export interface LearningMutation { binding: LearningBinding; expectedRevision?: number }
export interface RenameLearningProjectInput extends LearningMutation { name: string }
export interface DismissLearningRunInput extends LearningMutation { runId: string }
export interface CreateLearningProjectInput extends LearningMutation, Partial<LearningProjectSettings> {
  name: string; topic: string; level?: LearningLevel; readingMinutes?: number
}
export interface UpdateLearningSettingsInput extends LearningMutation, Partial<LearningProjectSettings> {
  /** Explicitly confirmed container classification; never inferred from purpose. */
  workspaceKind?: WorkspaceKind
  name?: string; topic?: string; level?: LearningLevel; readingMinutes?: number
}
export interface AddLearningArticleInput extends LearningMutation { article: LearningArticleInput }
export interface SaveLearningWordInput extends LearningMutation, LearningWordDraft {}
export interface UpdateLearningWordInput extends LearningMutation {
  wordId: string; lemma?: string; meaning?: string; pronunciation?: string; partOfSpeech?: string; status?: LearningWordStatus
}
export interface UpdateLearningOccurrenceInput extends LearningMutation { occurrenceId: string; meaning: string }
export interface SaveLearningProgressInput extends LearningMutation {
  articleId: string; paragraphId: string | null; scrollFraction: number
}
export interface CompleteLearningArticleInput extends LearningMutation { articleId: string }
export interface PutLearningArtifactInput extends LearningMutation { artifact: LearningArtifactDraft }
export interface SaveLearningQuizAnswerInput extends LearningMutation {
  artifactId: string; attemptId: string; questionId: string; answer: string
  selfCheck?: boolean
}
export interface FinishLearningQuizInput extends LearningMutation { artifactId: string; attemptId: string }
export interface ReviewLearningCardInput extends LearningMutation { cardId: string; rating: LearningCardRating; reviewId: string }
export interface UpdateLearningRunInput extends LearningMutation { run: LearningRun }
export interface ImportLearningDraftInput extends LearningMutation { draft: LearningDraft; runId?: string }
export interface LearningMaterialRequest { binding: LearningBinding; id: string }
export interface StartLearningRunInput extends LearningMutation {
  kind: LearningRunKind; provider?: string; articleIds?: string[]; wordIds?: string[]
  packId?: string
  sourceRefs?: LearningSourceRef[]
  source?: LearningRunSource
}
