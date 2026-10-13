import { randomUUID } from 'node:crypto'
import { existsSync, realpathSync } from 'node:fs'
import { mkdir, open, readFile, readdir, rename, rm, stat } from 'node:fs/promises'
import { basename, dirname, join, posix } from 'node:path'
import type {
  AddLearningArticleInput, CompleteLearningArticleInput, CreateLearningProjectInput,
  FinishLearningQuizInput, ImportLearningDraftInput, LearningArticleInput, LearningArticleRef,
  LearningArticleSnapshot, LearningArtifact, LearningArtifactDraft, LearningArtifactRef,
  LearningBinding, LearningDraft, LearningMutation, LearningProjectSnapshot,
  LearningProjectState, LearningProjectSummary, LearningSourceRef, LearningWordDraft, PutLearningArtifactInput,
  ReviewLearningCardInput, SaveLearningProgressInput, SaveLearningQuizAnswerInput,
  SaveLearningWordInput, UpdateLearningRunInput, UpdateLearningWordInput, UpdateLearningOccurrenceInput, UpdateLearningSettingsInput,
  RenameLearningProjectInput, DismissLearningRunInput
} from '../../../shared/types/learning'
import type { DictionarySource } from '../../../shared/types/dictionary'
import { ConflictError, NotFoundError, ValidationError } from '../../db/errors'
import { assertRealInside, resolveInside } from '../../db/validate'
import { articleMarkdown, gradeLearningAnswer, learningHash, normalizeLearningAnswer,
  normalizeLearningLemma, scheduleLearningCard } from './model'
import { renameWithRetry } from '../materials/renameWithRetry'
import type { MaterialPathLock } from '../materials/materialPathJournal'
import { learningArray, learningId, learningNumber, learningObject, learningString,
  normalizeLearningArticle, normalizeLearningDraft, validateLearningArtifact,
  validateLearningRun, validateLearningWordDraft, validateLearningState, validateLearningSettings, requireEnglishReadingSettings,
  type LearningValidationContext } from './validation'

export const LEARNING_DATA_DIR = '.bandal/learning'
const MANIFEST = `${LEARNING_DATA_DIR}/manifest.json`
const STATE = `${LEARNING_DATA_DIR}/state.json`
const PREVIOUS = `${LEARNING_DATA_DIR}/state.previous.json`
const MAX_STATE_BYTES = 64 * 1024 * 1024
const MAX_SOURCE_BYTES = 50 * 1024 * 1024

export interface LearningRepoDeps {
  getCourseFolder(courseId: string): string
  /** Recovery paths only; ordinary reads and sources still require a live course. */
  getCourseFolderIncludingDeleted?: (courseId: string) => string
  listCourseIds?: () => string[]
  now?: () => string
  /** Complete durable material-path updates before exposing mutable learning state. */
  beforePathAccess?: () => Promise<void>
  pathLock?: MaterialPathLock
  onChanged?: (binding: LearningBinding) => void
  /** Testable storage boundary; invoked just before publishing state.json. */
  beforeCommit?: () => void | Promise<void>
}
export interface LearningRepointInput {
  courseId: string; fromRelPath: string; toRelPath: string; isDirectory: boolean
  /** Internal durable outbox receipt; never supplied by renderer mutations. */
  operationId?: string
}
export interface LearningRepo {
  /** Holds the shared material path lock; only the scoped repository may be used inside work. */
  withExclusivePathAccess<T>(work: (scoped: LearningRepo) => Promise<T>): Promise<T>
  create(input: CreateLearningProjectInput): Promise<LearningProjectSnapshot>
  updateSettings(input: UpdateLearningSettingsInput): Promise<LearningProjectSnapshot>
  rename(input: RenameLearningProjectInput): Promise<LearningProjectSnapshot>
  delete(input: LearningMutation): Promise<LearningProjectSnapshot>
  restore(input: LearningMutation): Promise<LearningProjectSnapshot>
  dismissRun(input: DismissLearningRunInput): Promise<LearningProjectSnapshot>
  cancelPendingRuns(binding: LearningBinding): Promise<LearningProjectSnapshot>
  read(binding: LearningBinding): Promise<LearningProjectSnapshot>
  readDeleted(binding: LearningBinding): Promise<LearningProjectSnapshot>
  discover(courseId: string, input?: { includeDeleted?: boolean }): Promise<LearningProjectSummary[]>
  readArticle(binding: LearningBinding, id: string): Promise<LearningArticleSnapshot>
  readArtifact(binding: LearningBinding, id: string): Promise<LearningArtifact>
  addArticle(input: AddLearningArticleInput): Promise<LearningProjectSnapshot>
  saveWord(input: SaveLearningWordInput): Promise<LearningProjectSnapshot>
  updateWord(input: UpdateLearningWordInput): Promise<LearningProjectSnapshot>
  updateOccurrence(input: UpdateLearningOccurrenceInput): Promise<LearningProjectSnapshot>
  saveProgress(input: SaveLearningProgressInput): Promise<LearningProjectSnapshot>
  completeArticle(input: CompleteLearningArticleInput): Promise<LearningProjectSnapshot>
  putArtifact(input: PutLearningArtifactInput): Promise<LearningProjectSnapshot>
  saveQuizAnswer(input: SaveLearningQuizAnswerInput): Promise<LearningProjectSnapshot>
  finishQuiz(input: FinishLearningQuizInput): Promise<LearningProjectSnapshot>
  reviewCard(input: ReviewLearningCardInput): Promise<LearningProjectSnapshot>
  updateRun(input: UpdateLearningRunInput): Promise<LearningProjectSnapshot>
  importDraft(input: ImportLearningDraftInput): Promise<LearningProjectSnapshot>
  validateDraft(binding: LearningBinding, draft: unknown): Promise<LearningDraft>
  repoint(input: LearningRepointInput): Promise<void>
}
interface Loaded {
  root: string; state: LearningProjectState; bytes: string
  recovery: 'none' | 'previous'; warnings: string[]
}
interface PendingExport { relPath: string; markdown: string; expectedHash: string | null }
interface Transaction {
  state: LearningProjectState; root: string; binding: LearningBinding; now: string
  exports: PendingExport[]; articles: Map<string, LearningArticleSnapshot>
}

/** fsync before rename; preserves the old file if writing fails. */
async function atomicWrite(path: string, bytes: string, beforePublish?: () => Promise<void>): Promise<void> {
  const originalDirectory = realpathSync.native(dirname(path))
  const readExisting = async (): Promise<string | null> => {
    try { return await readFile(path, 'utf8') }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null; throw error }
  }
  const originalBytes = await readExisting()
  const temporary = join(dirname(path), `.${basename(path)}.${randomUUID()}.tmp`)
  const file = await open(temporary, 'wx', 0o600)
  try {
    await file.writeFile(bytes, 'utf8'); await file.sync(); await file.close()
    await renameWithRetry(temporary, path, async () => {
      if (realpathSync.native(dirname(path)) !== originalDirectory) throw new ConflictError('학습 자료를 저장할 폴더가 변경되었습니다.')
      if (await readExisting() !== originalBytes) throw new ConflictError('학습 자료가 저장 중에 변경되었습니다.')
      await beforePublish?.()
    })
  } catch (error) {
    await file.close().catch(() => undefined)
    await rm(temporary, { force: true }).catch(() => undefined)
    throw error
  }
}
function json(value: unknown): string { return `${JSON.stringify(value, null, 2)}\n` }
function contentIdentity(value: unknown): string {
  return JSON.stringify(value, (key, entry: unknown) => {
    if (key === 'createdAt' || key === 'fetchedAt' || key === 'availability') return undefined
    if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) {
      return Object.fromEntries(Object.entries(entry as Record<string, unknown>).sort(([left], [right]) => left.localeCompare(right)))
    }
    return entry
  })
}
function safeName(value: string): string {
  return value.normalize('NFC').replace(/[/\\:*?"<>|\u0000-\u001f]/g, '').replace(/^\.+/, '').trim().slice(0, 70) || '학습 자료'
}
function replacePath(path: string, from: string, to: string, directory: boolean): string {
  return path === from ? to : directory && path.startsWith(`${from}/`) ? `${to}${path.slice(from.length)}` : path
}

export function createLearningRepo(deps: LearningRepoDeps): LearningRepo {
  const queues = new Map<string, Promise<unknown>>()
  let pathAccessQueue: Promise<unknown> = Promise.resolve()
  const now = deps.now ?? (() => new Date().toISOString())

  function courseFolder(binding: LearningBinding, includeDeleted = false): string {
    learningString(binding.courseId, 'courseId', 1_000)
    const folder = includeDeleted && deps.getCourseFolderIncludingDeleted ? deps.getCourseFolderIncludingDeleted(binding.courseId) : deps.getCourseFolder(binding.courseId)
    if (!existsSync(folder)) throw new NotFoundError('course folder', folder)
    return folder
  }
  function projectRoot(binding: LearningBinding, allowMissing = false, includeDeleted = false): string {
    const folder = courseFolder(binding, includeDeleted)
    const root = assertRealInside(folder, resolveInside(folder, binding.rootRelPath, { allowRoot: true }))
    if (!allowMissing && !existsSync(root)) throw new NotFoundError('learning project', binding.rootRelPath)
    return root
  }
  function pathInside(root: string, relPath: string): string {
    return assertRealInside(root, resolveInside(root, relPath))
  }
  function withPathLock<T>(work: () => Promise<T>): Promise<T> {
    if (!deps.pathLock) return work()
    // Concurrent windows and course discovery share one repository. Queue our
    // own requests; the OS lock still rejects a genuinely independent writer.
    const task = pathAccessQueue.catch(() => undefined).then(async () => {
      const release = deps.pathLock!.tryAcquire()
      if (!release) throw new ConflictError('자료 경로 변경 또는 학습 저장이 진행 중입니다. 잠시 뒤 다시 시도해 주세요.')
      try { return await work() } finally { release() }
    })
    pathAccessQueue = task
    return task
  }
  async function serial<T>(binding: LearningBinding, work: () => Promise<T>, allowMissing = false, includeDeleted = false, recoveringPaths = false): Promise<T> {
    if (!recoveringPaths) await deps.beforePathAccess?.()
    const root = projectRoot(binding, allowMissing, includeDeleted)
    const key = existsSync(root) ? realpathSync.native(root) : root
    const previous = queues.get(key) ?? Promise.resolve()
    const task = previous.catch(() => undefined).then(() => recoveringPaths ? work() : withPathLock(work))
    queues.set(key, task)
    try { return await task } finally { if (queues.get(key) === task) queues.delete(key) }
  }
  async function readJsonFile(root: string, relPath: string): Promise<{ bytes: string; value: unknown }> {
    const path = pathInside(root, relPath)
    const info = await stat(path)
    if (!info.isFile() || info.size > MAX_STATE_BYTES) throw new ValidationError('학습 데이터 파일이 올바르지 않거나 너무 큽니다.')
    const bytes = await readFile(path, 'utf8')
    return { bytes, value: JSON.parse(bytes) as unknown }
  }
  async function load(binding: LearningBinding, includeDeleted = false): Promise<Loaded> {
    const root = projectRoot(binding, false, includeDeleted)
    let manifest: Record<string, unknown>
    try { manifest = learningObject((await readJsonFile(root, MANIFEST)).value, 'manifest') }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new NotFoundError('learning project', binding.rootRelPath); throw error }
    if (manifest['format'] !== 'bandal-learning' || manifest['formatVersion'] !== 1) throw new ValidationError('지원하지 않는 학습 프로젝트 형식입니다.')
    const projectId = learningId(manifest['projectId'], 'projectId')
    let current: { bytes: string; value: unknown } | undefined
    try { current = await readJsonFile(root, STATE) } catch { /* Recover below; never create an empty state. */ }
    if (current && current.value !== null && typeof current.value === 'object' && !Array.isArray(current.value)
      && typeof (current.value as Record<string, unknown>)['schemaVersion'] === 'number'
      && (current.value as { schemaVersion: number }).schemaVersion > 1) throw new ValidationError('지원하지 않는 학습 데이터 버전입니다.')
    if (current) {
      try {
        const state = validateLearningState(current.value)
        if (state.projectId !== projectId) throw new ValidationError('학습 프로젝트 식별자가 일치하지 않습니다.')
        return { root, state, bytes: current.bytes, recovery: 'none', warnings: [] }
      } catch { /* The last complete revision is the recovery point. */ }
    }
    try {
      const backup = await readJsonFile(root, PREVIOUS)
      const state = validateLearningState(backup.value)
      if (state.projectId !== projectId) throw new ValidationError('학습 프로젝트 식별자가 일치하지 않습니다.')
      return { root, state, bytes: backup.bytes, recovery: 'previous', warnings: ['학습 데이터를 직전 정상 저장본에서 복구했습니다. 최근 변경 한 건은 다시 확인해 주세요.'] }
    } catch {
      throw new ValidationError('학습 데이터를 읽지 못했습니다. 원본 파일을 보존했으니 백업을 복원해 주세요.')
    }
  }
  function requireActive(state: LearningProjectState): void {
    if (state.deletedAt) throw new ConflictError('삭제된 학습 공간입니다. 목록에서 복원한 뒤 다시 열어 주세요.')
  }
  async function resolveSourceAvailability(binding: LearningBinding, root: string, sources: LearningSourceRef[], linkedCourseId?: string): Promise<void> {
    const availability = new Map<string, Promise<'available' | 'missing' | 'changed'>>()
    for (const source of sources) {
      if (source.kind !== 'material' || !source.relPath) continue
      const key = `${source.sourceCourseId ?? binding.courseId}:${source.pathScope ?? 'project'}:${source.relPath}:${source.contentHash ?? ''}`
      let result = availability.get(key)
      if (!result) {
        result = (async () => {
          try {
            if (source.sourceCourseId && (source.pathScope !== 'course' || (source.sourceCourseId !== binding.courseId && source.sourceCourseId !== linkedCourseId))) return 'missing'
            const path = pathInside(source.pathScope === 'course' ? courseFolder({ ...binding, courseId: source.sourceCourseId ?? binding.courseId }) : root, source.relPath!)
            const info = await stat(path)
            if (!info.isFile()) return 'missing'
            if (source.contentHash && (info.size > MAX_SOURCE_BYTES || learningHash(await readFile(path)) !== source.contentHash)) return 'changed'
            return 'available'
          } catch { return 'missing' }
        })()
        availability.set(key, result)
      }
      source.availability = await result
    }
  }
  async function snapshot(binding: LearningBinding, loaded: Loaded): Promise<LearningProjectSnapshot> {
    const result = { ...structuredClone(loaded.state), binding: { ...binding }, recovery: loaded.recovery, warnings: [...loaded.warnings] }
    await resolveSourceAvailability(binding, loaded.root, [...result.occurrences.map((entry) => entry.sourceRef),
      ...result.cards.flatMap((entry) => entry.sourceRefs), ...result.artifacts.flatMap((entry) => entry.sourceRefs)], result.linkedCourseId)
    return result
  }
  async function articleFrom(root: string, state: LearningProjectState, id: string): Promise<LearningArticleSnapshot> {
    const ref = state.articles.find((article) => article.id === learningId(id, 'articleId'))
    if (!ref) throw new NotFoundError('article', id)
    const stored = learningObject((await readJsonFile(root, ref.snapshotRelPath)).value, 'article')
    const result = normalizeLearningArticle(stored, id, learningString(stored['createdAt'], 'createdAt', 64))
    if (stored['id'] !== id || result.contentHash !== ref.contentHash || stored['contentHash'] !== result.contentHash
      || result.sourceUrl !== ref.sourceUrl || result.canonicalUrl !== ref.canonicalUrl
      || result.title !== ref.title || result.wordCount !== ref.wordCount
      || result.estimatedMinutes !== ref.estimatedMinutes || result.createdAt !== ref.createdAt) {
      throw new ValidationError('저장된 기사 본문이나 출처가 변경되었습니다. 원문 스냅샷을 복원해 주세요.')
    }
    return result
  }
  async function artifactFrom(root: string, state: LearningProjectState, id: string, binding: LearningBinding): Promise<LearningArtifact> {
    const ref = state.artifacts.find((artifact) => artifact.id === learningId(id, 'artifactId'))
    if (!ref) throw new NotFoundError('artifact', id)
    const raw = learningObject((await readJsonFile(root, ref.relPath)).value, 'artifact')
    if (raw['id'] !== id || raw['kind'] !== ref.kind || raw['schemaVersion'] !== 1) throw new ValidationError('저장된 학습 자료가 올바르지 않습니다.')
    if (learningHash(json(raw)) !== ref.contentHash) throw new ValidationError('저장된 학습 자료가 변경되었습니다. 원본 스냅샷을 복원해 주세요.')
    const artifact = structuredClone(raw) as unknown as LearningArtifact
    const moveSources = (refs: LearningArtifact['sourceRefs']): void => {
      for (const source of refs) if (source.kind === 'material' && source.relPath) {
        for (const alias of state.pathAliases ?? []) if ((source.pathScope ?? 'project') === alias.scope && (source.sourceCourseId ?? binding.courseId) === (alias.sourceCourseId ?? binding.courseId)) {
          source.relPath = replacePath(source.relPath, alias.fromRelPath, alias.toRelPath, alias.isDirectory)
        }
      }
    }
    moveSources(artifact.sourceRefs)
    if (artifact.kind === 'quiz') artifact.questions.forEach((question) => moveSources(question.sourceRefs))
    if (artifact.kind === 'cards') artifact.cards.forEach((card) => moveSources(card.sourceRefs))
    await resolveSourceAvailability(binding, root, [...artifact.sourceRefs,
      ...(artifact.kind === 'quiz' ? artifact.questions.flatMap((question) => question.sourceRefs)
        : artifact.kind === 'cards' ? artifact.cards.flatMap((card) => card.sourceRefs) : [])], state.linkedCourseId)
    return artifact
  }
  function context(tx: Transaction): LearningValidationContext {
    return {
      state: tx.state, binding: tx.binding,
      readArticle: (id) => tx.articles.has(id) ? Promise.resolve(tx.articles.get(id)!) : articleFrom(tx.root, tx.state, id),
      async validateMaterial(ref) {
        if (ref.sourceCourseId && (ref.pathScope !== 'course' || (ref.sourceCourseId !== tx.binding.courseId && ref.sourceCourseId !== tx.state.linkedCourseId))) throw new ValidationError('연결되지 않은 과목의 출처입니다.')
        const sourceRoot = ref.pathScope === 'course' ? courseFolder({ ...tx.binding, courseId: ref.sourceCourseId ?? tx.binding.courseId }) : tx.root
        const path = pathInside(sourceRoot, ref.relPath!)
        const info = await stat(path)
        if (!info.isFile()) throw new ValidationError('출처 자료가 파일이 아닙니다.')
        if (info.size > MAX_SOURCE_BYTES) throw new ValidationError('출처 자료가 너무 큽니다.')
        if (ref.contentHash && learningHash(await readFile(path)) !== ref.contentHash) throw new ValidationError('출처 자료가 변경되었습니다. 다시 읽어 주세요.')
      }
    }
  }
  async function immutable<T>(root: string, relPath: string, value: T): Promise<T> {
    const path = pathInside(root, relPath)
    await mkdir(dirname(path), { recursive: true })
    assertRealInside(root, path)
    const bytes = json(value)
    if (existsSync(path)) {
      const existing = JSON.parse(await readFile(path, 'utf8')) as unknown
      if (contentIdentity(existing) !== contentIdentity(value)) throw new ConflictError('동일한 식별자의 학습 자료가 이미 있습니다.')
      return existing as T
    }
    // IDs are host-owned; serialized project writes prevent competing publishers.
    await atomicWrite(path, bytes)
    return value
  }
  function history(tx: Transaction, kind: LearningProjectState['history'][number]['kind'], entityId: string, summary: string, resultRelPath?: string): void {
    tx.state.history.push({ id: randomUUID(), kind, entityId, summary, createdAt: tx.now,
      ...(resultRelPath === undefined ? {} : { resultRelPath }) })
  }
  async function exportMarkdown(tx: Transaction, preferred: string, markdown: string): Promise<string> {
    let relPath = preferred
    const pending = tx.exports.find((entry) => entry.relPath === preferred)
    if (pending) {
      pending.markdown = markdown
      const record = tx.state.exports.find((entry) => entry.relPath === preferred)!
      record.contentHash = learningHash(markdown)
      return preferred
    }
    let expectedHash: string | null = null
    for (let index = 1; index < 1_000; index += 1) {
      const path = pathInside(tx.root, relPath)
      if (!existsSync(path)) break
      const known = tx.state.exports.find((entry) => entry.relPath === relPath)
      const actualHash = learningHash(await readFile(path))
      if (known?.contentHash === actualHash) { expectedHash = actualHash; break }
      const extension = posix.extname(preferred)
      relPath = `${preferred.slice(0, -extension.length)}-${index + 1}${extension}`
      if (index === 999) throw new ConflictError('생성한 자료를 저장할 이름을 찾지 못했습니다.')
    }
    tx.state.exports = tx.state.exports.filter((entry) => entry.relPath !== relPath)
    tx.state.exports.push({ relPath, contentHash: learningHash(markdown) })
    tx.exports.push({ relPath, markdown, expectedHash })
    return relPath
  }
  async function vocabularyExport(tx: Transaction): Promise<void> {
    const lines = [`# ${tx.state.name} 단어장`, '', '읽은 기사에서 직접 고른 단어와 원문 예문입니다.', '']
    const attribution = (source: DictionarySource): string => `${source.modified ? '직접 수정한 뜻의 원래 사전 출처' : '사전 뜻 출처'}: [Wiktionary contributors](<${source.url}>) · koreader-dicts ${source.datasetVersion} / Kaikki / Wiktextract · [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)`
    for (const word of tx.state.words) {
      lines.push(`## ${word.lemma}`, '', `${word.meaning || '뜻을 아직 정리하지 않았어요.'}${word.partOfSpeech ? ` · ${word.partOfSpeech}` : ''}`, '')
      if (word.dictionarySource) lines.push(attribution(word.dictionarySource), '')
      for (const occurrence of tx.state.occurrences.filter((entry) => entry.wordId === word.id)) {
        lines.push(`> ${occurrence.sentence.replace(/\n/g, '\n> ')}`, '')
        if (occurrence.meaning) lines.push(occurrence.meaning, '')
        if (occurrence.dictionarySource) lines.push(attribution(occurrence.dictionarySource), '')
        const article = tx.state.articles.find((entry) => entry.id === occurrence.sourceRef.articleId)
        if (article) lines.push(`[${article.title}](${article.sourceUrl})`, '')
      }
    }
    await exportMarkdown(tx, '단어장.md', lines.join('\n'))
  }
  async function commit(binding: LearningBinding, loaded: Loaded, tx: Transaction): Promise<LearningProjectSnapshot> {
    tx.state.revision += 1; tx.state.updatedAt = tx.now
    validateLearningState(tx.state)
    // Detect independent/external changes made while preparing immutable assets.
    if (loaded.recovery === 'none' && await readFile(pathInside(tx.root, STATE), 'utf8') !== loaded.bytes) throw new ConflictError('학습 프로젝트가 다른 곳에서 변경되었습니다. 다시 열어 주세요.')
    await atomicWrite(pathInside(tx.root, PREVIOUS), loaded.bytes)
    await deps.beforeCommit?.()
    if (loaded.recovery === 'previous' && existsSync(pathInside(tx.root, STATE))) {
      await rename(pathInside(tx.root, STATE), pathInside(tx.root, `${STATE}.corrupt-${randomUUID()}`))
    }
    await atomicWrite(pathInside(tx.root, STATE), json(tx.state), async () => {
      const path = pathInside(tx.root, STATE)
      if (loaded.recovery === 'none' && await readFile(path, 'utf8') !== loaded.bytes) throw new ConflictError('학습 프로젝트가 다른 곳에서 변경되었습니다. 다시 열어 주세요.')
      if (loaded.recovery === 'previous' && existsSync(path)) throw new ConflictError('학습 프로젝트가 복원 중에 변경되었습니다. 다시 열어 주세요.')
    })
    const warnings = [...loaded.warnings]
    for (const entry of tx.exports) {
      try {
        const path = pathInside(tx.root, entry.relPath)
        const validateExport = async (): Promise<void> => {
          const currentPath = pathInside(tx.root, entry.relPath)
          if (existsSync(currentPath)) {
            if (entry.expectedHash === null || learningHash(await readFile(currentPath)) !== entry.expectedHash) throw new ConflictError('자료가 저장 중에 변경되었습니다.')
          } else if (entry.expectedHash !== null) throw new ConflictError('자료가 저장 중에 이동되었습니다.')
        }
        await validateExport()
        await mkdir(dirname(path), { recursive: true }); assertRealInside(tx.root, path)
        await atomicWrite(path, entry.markdown, validateExport)
      } catch { warnings.push(`«${entry.relPath}» 자료 내보내기에 실패했습니다. 학습 기록은 저장되었습니다.`) }
    }
    try { deps.onChanged?.(binding) } catch { /* A UI notification cannot undo durable learning data. */ }
    return snapshot(binding, { root: tx.root, state: tx.state, bytes: json(tx.state), recovery: loaded.recovery, warnings })
  }
  async function mutate(input: LearningMutation, work: (tx: Transaction) => Promise<boolean | void> | boolean | void, includeDeleted = false, recoveringPaths = false): Promise<LearningProjectSnapshot> {
    return serial(input.binding, async () => {
      const loaded = await load(input.binding, includeDeleted)
      if (!includeDeleted) requireActive(loaded.state)
      if (input.expectedRevision !== undefined && input.expectedRevision !== loaded.state.revision) throw new ConflictError('학습 프로젝트가 변경되었습니다. 최신 상태를 불러와 주세요.')
      const tx: Transaction = { state: structuredClone(loaded.state), root: loaded.root, binding: input.binding, now: now(), exports: [], articles: new Map() }
      if (await work(tx) === false) return snapshot(input.binding, loaded)
      return commit(input.binding, loaded, tx)
    }, false, includeDeleted, recoveringPaths)
  }
  async function addArticle(tx: Transaction, input: LearningArticleInput): Promise<string> {
    let article = normalizeLearningArticle(input, input.id ?? randomUUID(), tx.now)
    const duplicate = tx.state.articles.find((entry) => entry.canonicalUrl === article.canonicalUrl || entry.contentHash === article.contentHash)
    if (duplicate) return duplicate.id
    if (tx.state.articles.some((entry) => entry.id === article.id)) throw new ConflictError('같은 식별자의 다른 기사가 이미 있습니다.')
    const snapshotRelPath = `${LEARNING_DATA_DIR}/articles/${article.id}.json`
    article = await immutable(tx.root, snapshotRelPath, article)
    const exportRelPath = await exportMarkdown(tx, `기사/${safeName(article.title)}-${article.id.slice(0, 8)}.md`, articleMarkdown(article))
    const wordIds = learningArray(input.matchedWordIds ?? [], 'matchedWordIds', 1_000).map((id) => learningId(id))
    if (wordIds.some((id) => !tx.state.words.some((word) => word.id === id))) throw new ValidationError('기사에 연결할 단어를 찾지 못했습니다.')
    const ref: LearningArticleRef = { id: article.id, title: article.title, sourceUrl: article.sourceUrl,
      canonicalUrl: article.canonicalUrl, snapshotRelPath, exportRelPath, contentHash: article.contentHash,
      wordCount: article.wordCount, estimatedMinutes: article.estimatedMinutes, createdAt: article.createdAt,
      status: 'unread', progress: { paragraphId: null, scrollFraction: 0 }, completedAt: null, matchedWordIds: wordIds }
    tx.state.articles.push(ref); tx.articles.set(article.id, article)
    history(tx, 'article-added', article.id, `«${article.title}» 기사를 저장했습니다.`)
    return article.id
  }
  async function putArtifact(tx: Transaction, input: LearningArtifactDraft): Promise<string> {
    const draft = await validateLearningArtifact(input, context(tx))
    const id = draft.id ?? randomUUID()
    const base = { id, schemaVersion: 1 as const, revision: 1, title: draft.title, createdAt: tx.now,
      sourceRefs: draft.sourceRefs ?? [], articleIds: draft.articleIds ?? [], wordIds: draft.wordIds ?? [] }
    let artifact: LearningArtifact
    if (draft.kind === 'cards') {
      const cards = draft.cards.map((card) => ({ ...card, id: `card-${learningHash(JSON.stringify({
        front: normalizeLearningAnswer(card.front), back: normalizeLearningAnswer(card.back),
        wordId: card.wordId ?? null, sources: card.sourceRefs
      })).slice(0, 32)}` }))
      if (new Set(cards.map((card) => card.id)).size !== cards.length) throw new ValidationError('같은 내용의 플래시카드가 중복되었습니다.')
      artifact = { ...base, kind: 'cards', cards }
      for (const card of cards) {
        const current = tx.state.cards.find((entry) => entry.id === card.id)
        if (current) current.artifactId = id
        else tx.state.cards.push({ ...card, artifactId: id, status: 'new', dueAt: tx.now,
          intervalDays: 0, repetitions: 0, lapses: 0, lastReviewedAt: null })
      }
    } else if (draft.kind === 'quiz') artifact = { ...base, kind: 'quiz', questions: draft.questions }
    else artifact = { ...base, kind: 'summary', markdown: draft.markdown }
    if (tx.state.artifacts.some((entry) => entry.id === id)) {
      const existing = await artifactFrom(tx.root, tx.state, id, tx.binding)
      if (contentIdentity(existing) !== contentIdentity(artifact)) throw new ConflictError('같은 식별자의 다른 학습 자료가 이미 있습니다.')
      return id
    }
    const relPath = `${LEARNING_DATA_DIR}/artifacts/${id}.json`
    artifact = await immutable(tx.root, relPath, artifact)
    const markdown = artifact.kind === 'summary' ? artifact.markdown
      : artifact.kind === 'quiz' ? [`# ${artifact.title}`, '', ...artifact.questions.flatMap((question, index) => [
        `## ${index + 1}. ${question.prompt}`, '', ...(question.options?.map((option) => `- ${option.text}`) ?? []), '',
        `정답: ${question.type === 'choice' ? question.options?.find((option) => option.id === question.answer)?.text ?? question.answer : question.modelAnswer ?? question.answer}`, '', question.explanation, ''
      ])].join('\n')
        : [`# ${artifact.title}`, '', ...artifact.cards.flatMap((card) => [`## ${card.front}`, '', card.back, ''])].join('\n')
    const exportRelPath = await exportMarkdown(tx, `복습/${safeName(artifact.title)}-${id.slice(0, 8)}.md`, markdown)
    const individualSources = artifact.kind === 'quiz' ? artifact.questions.flatMap(question => question.sourceRefs)
      : artifact.kind === 'cards' ? artifact.cards.flatMap(card => card.sourceRefs) : []
    // The list needs all origins even when the model only cited individual questions/cards.
    // Immutable artifact content keeps its original per-item and top-level citations.
    const sourceRefs = [...new Map([...artifact.sourceRefs, ...individualSources].map(source => [
      JSON.stringify(Object.entries(source).sort(([a], [b]) => a.localeCompare(b))), source
    ])).values()]
    const ref: LearningArtifactRef = { id, kind: artifact.kind, title: artifact.title, relPath, exportRelPath, contentHash: learningHash(json(artifact)),
      createdAt: tx.now, sourceRefs, articleIds: artifact.articleIds, wordIds: artifact.wordIds }
    tx.state.artifacts.push(ref); history(tx, 'artifact-created', id, `«${artifact.title}» 학습 자료를 만들었습니다.`)
    return id
  }

  async function saveWord(tx: Transaction, input: LearningWordDraft): Promise<boolean> {
    const draft = await validateLearningWordDraft(input, context(tx))
    const { surface, sentence, sourceRef } = draft
    const lemma = normalizeLearningLemma(draft.lemma ?? surface)
    input = draft
    const partOfSpeech = input.partOfSpeech === undefined ? '' : learningString(input.partOfSpeech, 'partOfSpeech', 1_000, true)
    const compatible = (word: LearningProjectState['words'][number]): boolean => !partOfSpeech || !word.partOfSpeech
      || normalizeLearningLemma(word.partOfSpeech) === normalizeLearningLemma(partOfSpeech)
    const hasSurface = (word: LearningProjectState['words'][number]): boolean => normalizeLearningLemma(word.surface) === normalizeLearningLemma(surface)
      || tx.state.occurrences.some(occurrence => occurrence.wordId === word.id && normalizeLearningLemma(occurrence.surface) === normalizeLearningLemma(surface))
    let candidates = tx.state.words.filter(word => hasSurface(word) && compatible(word)
      && (input.lemma === undefined || normalizeLearningLemma(word.lemma) === lemma))
    if (!partOfSpeech && candidates.length > 1) {
      const unresolved = candidates.filter(word => !word.partOfSpeech)
      if (unresolved.length === 1) candidates = unresolved
    }
    if (!candidates.length && input.lemma !== undefined) candidates = tx.state.words.filter(word => normalizeLearningLemma(word.lemma) === lemma && compatible(word))
    let word = candidates.length === 1 ? candidates[0] : undefined
    if (!word) {
      word = { id: randomUUID(), surface, lemma, meaning: input.meaning ?? '', pronunciation: input.pronunciation ?? '',
        partOfSpeech, status: 'new', createdAt: tx.now, updatedAt: tx.now,
        ...(input.dictionarySource ? { dictionarySource: input.dictionarySource } : {}) }
      learningString(word.meaning, 'meaning', 20_000, true); learningString(word.pronunciation, 'pronunciation', 1_000, true)
      learningString(word.partOfSpeech, 'partOfSpeech', 1_000, true)
      tx.state.words.push(word)
    }
    const key = JSON.stringify(sourceRef)
    if (tx.state.occurrences.some((entry) => entry.wordId === word!.id && JSON.stringify(entry.sourceRef) === key)) return false
    // A new encounter can complete an empty record; never replace a personal
    // definition just because a dictionary offers another sense.
    if (!word.meaning.trim() && input.meaning?.trim()) {
      word.meaning = input.meaning
      if (input.dictionarySource) word.dictionarySource = input.dictionarySource
      else delete word.dictionarySource
      if (!word.pronunciation && input.pronunciation) word.pronunciation = input.pronunciation
      if (!word.partOfSpeech && partOfSpeech) word.partOfSpeech = partOfSpeech
      word.updatedAt = tx.now
    }
    tx.state.occurrences.push({ id: randomUUID(), wordId: word.id, surface, sentence, sourceRef, meaning: input.meaning ?? '', createdAt: tx.now,
      ...(input.dictionarySource ? { dictionarySource: input.dictionarySource } : {}) })
    history(tx, 'word-saved', word.id, `«${surface}» 단어와 예문을 저장했습니다.`)
    return true
  }

  async function discoverProjects(courseId: string, input: { includeDeleted?: boolean } = {}, strict = false): Promise<LearningProjectSummary[]> {
    const binding = { courseId, rootRelPath: '' }
    const course = courseFolder(binding, input.includeDeleted)
    const found: LearningProjectSummary[] = []
    let count = 0
    async function walk(rootRelPath: string, depth: number): Promise<void> {
      if (depth > 12 || count >= 20_000) {
        if (strict) throw new ConflictError('학습 프로젝트 탐색 한도를 넘었습니다. 경로 변경 기록을 보존했습니다.')
        return
      }
      const root = projectRoot({ courseId, rootRelPath }, false, input.includeDeleted)
      if (existsSync(join(root, MANIFEST))) {
        const projectBinding = { courseId, rootRelPath }
        try {
          const loaded = await load(projectBinding, input.includeDeleted); const state = loaded.state
          if (state.deletedAt && !input.includeDeleted) return
          found.push({ binding: projectBinding, projectId: state.projectId, name: state.name, topic: state.topic,
            purpose: state.purpose ?? 'unclassified', topicIds: state.topicIds ?? [], readingSetupConfirmed: state.readingSetupConfirmed ?? false,
            ...(state.ai ? { ai: state.ai } : {}), ...(state.linkedCourseId ? { linkedCourseId: state.linkedCourseId } : {}), ...(state.packId ? { packId: state.packId } : {}),
            level: state.level, readingMinutes: state.readingMinutes, articleCount: state.articles.length,
            completedArticleCount: state.articles.filter((article) => article.status === 'completed').length,
            wordCount: state.words.length, knownWordCount: state.words.filter((word) => word.status === 'known').length,
            dueCardCount: state.cards.filter((card) => Date.parse(card.dueAt) <= Date.parse(now())).length,
            updatedAt: state.updatedAt, warning: loaded.warnings[0] ?? null, ...(state.deletedAt ? { deletedAt: state.deletedAt } : {}) })
        } catch (error) {
          found.push({ binding: projectBinding, projectId: '', name: basename(root), topic: '', purpose: 'unclassified', topicIds: [], readingSetupConfirmed: false, level: 'intermediate',
            readingMinutes: 5, articleCount: 0, completedArticleCount: 0, wordCount: 0, knownWordCount: 0,
            dueCardCount: 0, updatedAt: '', warning: error instanceof Error ? error.message : '학습 데이터를 읽지 못했습니다.' })
        }
        return
      }
      const entries = await readdir(root, { withFileTypes: true })
      for (const entry of entries) {
        count += 1
        if (count >= 20_000) {
          if (strict) throw new ConflictError('학습 프로젝트 탐색 한도를 넘었습니다. 경로 변경 기록을 보존했습니다.')
          return
        }
        if (entry.isDirectory() && !entry.name.startsWith('.')) await walk(rootRelPath ? posix.join(rootRelPath, entry.name) : entry.name, depth + 1)
      }
    }
    assertRealInside(course, course); await walk('', 0)
    return found
  }

  const repo: LearningRepo = {
    async withExclusivePathAccess(work) {
      await deps.beforePathAccess?.()
      return withPathLock(async () => {
        const scopedDeps = { ...deps }
        delete scopedDeps.pathLock; delete scopedDeps.beforePathAccess
        const inner = createLearningRepo(scopedDeps)
        let active = true
        const pending = new Set<Promise<unknown>>()
        const scoped = Object.fromEntries(Object.entries(inner).map(([name, action]) => [name, (...args: unknown[]) => {
          if (!active) return Promise.reject(new ConflictError('학습 경로 접근 범위가 종료되었습니다.'))
          const task = Promise.resolve().then(() => (action as (...args: unknown[]) => unknown)(...args))
          pending.add(task)
          void task.then(() => pending.delete(task), () => pending.delete(task))
          return task
        }])) as unknown as LearningRepo
        try { return await work(scoped) }
        finally { active = false; await Promise.allSettled([...pending]) }
      })
    },
    async create(input) {
      return serial(input.binding, async () => {
        const root = projectRoot(input.binding, true)
        const course = courseFolder(input.binding)
        for (let ancestor = dirname(root); ancestor.length >= course.length && ancestor !== root; ancestor = dirname(ancestor)) {
          if (existsSync(join(ancestor, MANIFEST))) throw new ConflictError('학습 프로젝트 안에 다른 프로젝트를 만들 수 없습니다.')
          if (ancestor === course) break
        }
        if (existsSync(join(root, MANIFEST))) {
          const loaded = await load(input.binding); requireActive(loaded.state)
          return snapshot(input.binding, loaded)
        }
        if (existsSync(root)) {
          const descendants = await discoverProjects(input.binding.courseId)
          if (descendants.some((entry) => entry.binding.rootRelPath !== input.binding.rootRelPath
            && (!input.binding.rootRelPath || entry.binding.rootRelPath.startsWith(`${input.binding.rootRelPath}/`)))) throw new ConflictError('기존 학습 프로젝트를 포함하는 상위 프로젝트를 만들 수 없습니다.')
        }
        const name = learningString(input.name, 'name', 1_000).trim()
        const topic = learningString(input.topic, 'topic', 10_000).trim()
        const level = input.level ?? 'intermediate'
        if (!['beginner', 'intermediate', 'advanced'].includes(level)) throw new ValidationError('올바르지 않은 학습 난이도입니다.')
        const readingMinutes = learningNumber(input.readingMinutes ?? 4, 'readingMinutes', 1, 30)
        const settings = validateLearningSettings(input)
        if (settings.purpose === 'english-reading') requireEnglishReadingSettings(settings, input.level, input.readingMinutes)
        await mkdir(root, { recursive: true }); assertRealInside(course, root)
        await mkdir(pathInside(root, LEARNING_DATA_DIR), { recursive: true })
        let state: LearningProjectState
        if (existsSync(pathInside(root, STATE))) {
          // Creation interrupted before publishing the immutable root marker.
          state = validateLearningState((await readJsonFile(root, STATE)).value)
        } else {
          const timestamp = now()
          state = { schemaVersion: 1, projectId: randomUUID(), revision: 0, name, topic, level, readingMinutes,
            purpose: 'unclassified', topicIds: [], readingSetupConfirmed: false, ...settings,
            createdAt: timestamp, updatedAt: timestamp, articles: [], words: [], occurrences: [], artifacts: [],
            cards: [], quizAttempts: [], runs: [], history: [], exports: [], pathAliases: [] }
          const initialExports: Array<[string, string]> = settings.purpose === 'course-review' ? [] : [['단어장.md', '나의 단어장'], ['예문 모음.md', '예문 모음']]
          for (const [relPath, title] of initialExports) {
            const path = pathInside(root, relPath)
            if (existsSync(path)) continue
            const markdown = `# ${title}\n\n읽기 화면에서 모르는 표현을 저장하면 이곳에 함께 쌓입니다.\n`
            await atomicWrite(path, markdown)
            state.exports.push({ relPath, contentHash: learningHash(markdown) })
          }
          await atomicWrite(pathInside(root, STATE), json(state))
          await atomicWrite(pathInside(root, PREVIOUS), json(state))
        }
        for (const directory of settings.purpose === 'course-review' ? ['학습노트', '복습'] : ['기사', '학습노트', '복습']) await mkdir(pathInside(root, directory), { recursive: true })
        await atomicWrite(pathInside(root, MANIFEST), json({ format: 'bandal-learning', formatVersion: 1, projectId: state.projectId }))
        deps.onChanged?.(input.binding)
        return snapshot(input.binding, { root, state, bytes: json(state), recovery: 'none', warnings: [] })
      }, true)
    },
    updateSettings(input) {
      return mutate(input, tx => {
        const settings = validateLearningSettings(input)
        const merged = { ...tx.state, ...settings }
        if (merged.purpose === 'english-reading') requireEnglishReadingSettings(merged, input.level ?? tx.state.level, input.readingMinutes ?? tx.state.readingMinutes)
        Object.assign(tx.state, settings)
        if (input.name !== undefined) tx.state.name = learningString(input.name, 'name', 1_000).trim()
        if (input.topic !== undefined) tx.state.topic = learningString(input.topic, 'topic', 10_000).trim()
        if (input.level !== undefined) {
          if (!['beginner', 'intermediate', 'advanced'].includes(input.level)) throw new ValidationError('영어 읽기 수준을 선택하세요.')
          tx.state.level = input.level
        }
        if (input.readingMinutes !== undefined) tx.state.readingMinutes = learningNumber(input.readingMinutes, 'readingMinutes', 1, 30)
      })
    },
    rename(input) {
      return mutate(input, tx => { tx.state.name = learningString(input.name, 'name', 1_000).trim(); if (!tx.state.name) throw new ValidationError('학습 공간 이름을 입력하세요.') })
    },
    delete(input) {
      return mutate(input, tx => { if (tx.state.deletedAt) return false; tx.state.deletedAt = tx.now }, true)
    },
    restore(input) {
      return mutate(input, tx => { if (!tx.state.deletedAt) return false; tx.state.deletedAt = null }, true)
    },
    dismissRun(input) {
      return mutate(input, tx => {
        const run = tx.state.runs.find(entry => entry.id === learningId(input.runId, 'runId'))
        if (!run) throw new NotFoundError('learning run', input.runId)
        if (!['failed', 'interrupted', 'cancelled'].includes(run.status)) throw new ConflictError('종료된 실패 알림만 숨길 수 있습니다.')
        if (run.dismissedAt) return false
        run.dismissedAt = tx.now
      })
    },
    cancelPendingRuns(binding) {
      return mutate({ binding }, tx => {
        let changed = false
        for (const run of tx.state.runs) if (['queued', 'running', 'validating', 'awaiting-confirmation'].includes(run.status)) {
          Object.assign(run, { status: 'cancelled', draft: null, error: null, errorCode: 'cancelled', errorCategory: 'cancelled',
            message: '학습 공간이 닫혀 작업을 중지했어요.', updatedAt: tx.now })
          changed = true
        }
        return changed
      }, true)
    },
    async read(binding) { return serial(binding, async () => { const loaded = await load(binding); requireActive(loaded.state); return snapshot(binding, loaded) }) },
    async readDeleted(binding) { return serial(binding, async () => snapshot(binding, await load(binding, true)), false, true) },
    async readArticle(binding, id) { return serial(binding, async () => { const loaded = await load(binding); requireActive(loaded.state); return articleFrom(loaded.root, loaded.state, id) }) },
    async readArtifact(binding, id) { return serial(binding, async () => { const loaded = await load(binding); requireActive(loaded.state); return artifactFrom(loaded.root, loaded.state, id, binding) }) },
    async discover(courseId, input = {}) {
      await deps.beforePathAccess?.()
      return withPathLock(() => discoverProjects(courseId, input))
    },
    addArticle(input) { return mutate(input, async (tx) => { const size = tx.state.articles.length; await addArticle(tx, input.article); return tx.state.articles.length !== size }) },
    saveWord(input) {
      return mutate(input, async (tx) => {
        if (!await saveWord(tx, input)) return false
        await vocabularyExport(tx)
      })
    },
    updateWord(input) {
      return mutate(input, async (tx) => {
        const word = tx.state.words.find((entry) => entry.id === learningId(input.wordId, 'wordId'))
        if (!word) throw new NotFoundError('word', input.wordId)
        for (const key of ['lemma', 'meaning', 'pronunciation', 'partOfSpeech'] as const) {
          if (input[key] !== undefined) word[key] = learningString(input[key], key, key === 'meaning' ? 20_000 : 1_000, key !== 'lemma')
        }
        if (input.meaning !== undefined && word.dictionarySource) word.dictionarySource = { ...word.dictionarySource, modified: true }
        if (input.status !== undefined) {
          if (!['new', 'learning', 'known'].includes(input.status)) throw new ValidationError('올바르지 않은 단어 학습 상태입니다.')
          word.status = input.status
        }
        word.updatedAt = tx.now; await vocabularyExport(tx)
      })
    },
    updateOccurrence(input) {
      return mutate(input, async (tx) => {
        const occurrence = tx.state.occurrences.find(entry => entry.id === learningId(input.occurrenceId, 'occurrenceId'))
        if (!occurrence) throw new NotFoundError('word occurrence', input.occurrenceId)
        occurrence.meaning = learningString(input.meaning, 'meaning', 20_000, true)
        if (occurrence.dictionarySource) occurrence.dictionarySource = { ...occurrence.dictionarySource, modified: true }
        await vocabularyExport(tx)
      })
    },
    saveProgress(input) {
      return mutate(input, async (tx) => {
        const ref = tx.state.articles.find((entry) => entry.id === learningId(input.articleId, 'articleId'))
        if (!ref) throw new NotFoundError('article', input.articleId)
        const article = await context(tx).readArticle(ref.id)
        if (input.paragraphId !== null && !article.paragraphs.some((paragraph) => paragraph.id === input.paragraphId)) throw new ValidationError('읽기 위치를 찾지 못했습니다.')
        ref.progress = { paragraphId: input.paragraphId, scrollFraction: learningNumber(input.scrollFraction, 'scrollFraction', 0, 1) }
        if (ref.status === 'unread') ref.status = 'reading'
      })
    },
    completeArticle(input) {
      return mutate(input, (tx) => {
        const ref = tx.state.articles.find((entry) => entry.id === learningId(input.articleId, 'articleId'))
        if (!ref) throw new NotFoundError('article', input.articleId)
        if (ref.status === 'completed') return false
        ref.status = 'completed'; ref.completedAt = tx.now
        history(tx, 'article-completed', ref.id, `«${ref.title}» 기사를 다 읽었습니다.`)
      })
    },
    putArtifact(input) { return mutate(input, async (tx) => { const size = tx.state.artifacts.length; await putArtifact(tx, input.artifact); return size !== tx.state.artifacts.length }) },
    saveQuizAnswer(input) {
      return mutate(input, async (tx) => {
        const artifact = await artifactFrom(tx.root, tx.state, input.artifactId, tx.binding)
        if (artifact.kind !== 'quiz') throw new ValidationError('퀴즈 자료가 아닙니다.')
        const question = artifact.questions.find((entry) => entry.id === input.questionId)
        if (!question) throw new NotFoundError('quiz question', input.questionId)
        const attemptId = learningId(input.attemptId, 'attemptId')
        const answer = learningString(input.answer, 'answer', 20_000, question.type !== 'choice')
        if (question.type === 'choice' && !question.options?.some((option) => option.id === answer)) throw new ValidationError('선택지를 다시 확인해 주세요.')
        if (input.selfCheck !== undefined && typeof input.selfCheck !== 'boolean') throw new ValidationError('자기 평가가 올바르지 않습니다.')
        let attempt = tx.state.quizAttempts.find((entry) => entry.id === attemptId)
        if (attempt && attempt.artifactId !== artifact.id) throw new ConflictError('퀴즈 실행 식별자가 다른 자료에서 사용 중입니다.')
        if (attempt?.completedAt) throw new ConflictError('이미 완료한 퀴즈입니다. 새로 시작해 주세요.')
        if (!attempt) {
          attempt = { id: attemptId, artifactId: artifact.id, answers: [], startedAt: tx.now, completedAt: null,
            score: 0, total: artifact.questions.filter((entry) => entry.type !== 'short-answer').length,
            selfCheckedCount: 0, selfPassedCount: 0, resultRelPath: null }
          tx.state.quizAttempts.push(attempt)
        }
        const graded = { questionId: question.id, answer, correct: gradeLearningAnswer(question, answer), answeredAt: tx.now,
          ...(question.type === 'short-answer' && input.selfCheck !== undefined ? { selfCheck: input.selfCheck } : {}) }
        const index = attempt.answers.findIndex((entry) => entry.questionId === question.id)
        if (index >= 0) attempt.answers[index] = graded; else attempt.answers.push(graded)
        attempt.score = attempt.answers.filter((entry) => entry.correct === true).length
        attempt.selfCheckedCount = attempt.answers.filter((entry) => entry.selfCheck !== undefined).length
        attempt.selfPassedCount = attempt.answers.filter((entry) => entry.selfCheck === true).length
      })
    },
    finishQuiz(input) {
      return mutate(input, async (tx) => {
        const attempt = tx.state.quizAttempts.find((entry) => entry.id === learningId(input.attemptId, 'attemptId'))
        if (!attempt || attempt.artifactId !== input.artifactId) throw new NotFoundError('quiz attempt', input.attemptId)
        if (attempt.completedAt) return false
        const artifact = await artifactFrom(tx.root, tx.state, attempt.artifactId, tx.binding)
        if (artifact.kind !== 'quiz') throw new ValidationError('퀴즈 자료가 아닙니다.')
        if (artifact.questions.some((question) => !attempt.answers.some((answer) => answer.questionId === question.id && answer.answer.trim().length > 0
          && (question.type !== 'short-answer' || answer.selfCheck !== undefined)))) throw new ValidationError('모든 문항에 답하고 서술형 답안을 자기 점검해 주세요.')
        attempt.completedAt = tx.now
        attempt.resultRelPath = `${LEARNING_DATA_DIR}/results/quiz-${attempt.id}-${learningHash(json(attempt)).slice(0, 16)}.json`
        await immutable(tx.root, attempt.resultRelPath, attempt)
        history(tx, 'quiz-completed', attempt.id, `«${artifact.title}» 퀴즈를 완료했습니다.`, attempt.resultRelPath)
      })
    },
    reviewCard(input) {
      return mutate(input, async (tx) => {
        const reviewId = learningId(input.reviewId, 'reviewId')
        const reviewed = tx.state.history.find((entry) => entry.id === reviewId && entry.kind === 'card-reviewed')
        if (reviewed) {
          if (reviewed.entityId !== input.cardId) throw new ConflictError('복습 식별자가 다른 카드에서 사용 중입니다.')
          return false
        }
        const index = tx.state.cards.findIndex((entry) => entry.id === learningId(input.cardId, 'cardId'))
        const card = tx.state.cards[index]
        if (!card) throw new NotFoundError('card', input.cardId)
        const next = scheduleLearningCard(card, input.rating, tx.now)
        const result = { id: reviewId, cardId: card.id, rating: input.rating, reviewedAt: tx.now, before: card, after: next }
        const resultRelPath = `${LEARNING_DATA_DIR}/results/review-${reviewId}-${learningHash(json(result)).slice(0, 16)}.json`
        await immutable(tx.root, resultRelPath, result)
        tx.state.cards[index] = next
        history(tx, 'card-reviewed', card.id, '플래시카드를 복습했습니다.', resultRelPath)
        tx.state.history[tx.state.history.length - 1]!.id = reviewId
      })
    },
    updateRun(input) {
      return mutate(input, (tx) => {
        const run = validateLearningRun(input.run)
        const index = tx.state.runs.findIndex((entry) => entry.id === run.id)
        if (index < 0) tx.state.runs.push(run)
        else {
          // The filesystem hook can repoint a queued/running job while its adapter
          // still holds the original request. Its persisted source is authoritative.
          const source = tx.state.runs[index]!.source
          tx.state.runs[index] = { ...run, ...(source ? { source: structuredClone(source) } : {}) }
        }
      })
    },
    importDraft(input) {
      return mutate(input, async (tx) => {
        const run = input.runId ? tx.state.runs.find(entry => entry.id === learningId(input.runId, 'runId')) : undefined
        if (input.runId && !run) throw new NotFoundError('learning run', input.runId)
        if (run?.status === 'complete') return false
        if (run && !['validating', 'awaiting-confirmation'].includes(run.status)) throw new ConflictError('저장 가능한 학습 작업 상태가 아닙니다.')
        const validation = context(tx)
        const draft = await normalizeLearningDraft(input.draft, tx.state, validation.readArticle, validation.validateMaterial)
        const resultArticleIds: string[] = []
        const resultArtifactIds: string[] = []
        for (const article of draft.articles ?? []) resultArticleIds.push(await addArticle(tx, article))
        for (const word of draft.words ?? []) await saveWord(tx, word)
        for (const artifact of draft.artifacts ?? []) resultArtifactIds.push(await putArtifact(tx, artifact))
        for (const update of draft.wordUpdates ?? []) {
          const word = tx.state.words.find((entry) => entry.id === update.wordId)!
          word.meaning = update.meaning
          delete word.dictionarySource
          if (update.lemma !== undefined) word.lemma = normalizeLearningLemma(update.lemma)
          if (update.pronunciation !== undefined) word.pronunciation = update.pronunciation
          if (update.partOfSpeech !== undefined) word.partOfSpeech = update.partOfSpeech
          word.updatedAt = tx.now
          if (update.occurrenceId !== undefined) {
            const occurrence = tx.state.occurrences.find((entry) => entry.id === update.occurrenceId)!
            occurrence.meaning = update.meaning
            delete occurrence.dictionarySource
          }
        }
        if (draft.wordUpdates?.length || draft.words?.length) await vocabularyExport(tx)
        if (run) {
          run.status = 'complete'; run.updatedAt = tx.now; run.draft = null; run.error = null; run.message = '학습 자료가 준비되었어요.'
          run.resultArticleIds = [...new Set(resultArticleIds)]; run.resultArtifactIds = [...new Set(resultArtifactIds)]
        }
      })
    },
    async validateDraft(binding, draft) {
      return serial(binding, async () => {
        const loaded = await load(binding)
        requireActive(loaded.state)
        const tx: Transaction = { state: loaded.state, root: loaded.root, binding, now: now(), articles: new Map(), exports: [] }
        const validation = context(tx)
        return normalizeLearningDraft(draft, loaded.state, validation.readArticle, validation.validateMaterial)
      })
    },
    async repoint(input) {
      // The outbox owns the interprocess path lock until all projects acknowledge this ID.
      if (input.operationId !== undefined) learningId(input.operationId, 'operationId')
      // Called after filesystem rename. Rediscovery naturally mounts a moved project root.
      const projects: LearningProjectSummary[] = []
      for (const courseId of new Set([input.courseId, ...(deps.listCourseIds?.() ?? [])])) {
        try { projects.push(...await discoverProjects(courseId, { includeDeleted: true }, input.operationId !== undefined)) }
        catch (error) { if (input.operationId !== undefined) throw error /* Keep durable event pending; no silent partial acknowledgement. */ }
      }
      for (const project of projects) {
        // A corrupt project cannot tell us whether it cites this course. Keep
        // the event until it can be read, even when its owner is another course.
        if (project.warning) {
          if (input.operationId !== undefined) throw new ConflictError(`학습 경로 변경을 완료하지 못했습니다: ${project.warning}`)
          continue
        }
        const ownsPaths = project.binding.courseId === input.courseId
        if (!ownsPaths && project.linkedCourseId !== input.courseId) continue
        const root = project.binding.rootRelPath
        const withinRoot = (path: string): string | null => {
          if (!root) return path
          return path.startsWith(`${root}/`) ? path.slice(root.length + 1) : null
        }
        const from = withinRoot(input.fromRelPath); const to = withinRoot(input.toRelPath)
        await mutate({ binding: project.binding }, (tx) => {
          if (input.operationId !== undefined) {
            const receipt = tx.state.pathAliases?.find(alias => alias.operationId === input.operationId)
            if (receipt) {
              if (receipt.scope !== 'course' || receipt.fromRelPath !== input.fromRelPath || receipt.toRelPath !== input.toRelPath || receipt.isDirectory !== input.isDirectory || (receipt.sourceCourseId ?? project.binding.courseId) !== input.courseId) throw new ConflictError('학습 경로 변경 식별자가 다른 변경에 재사용되었습니다.')
              return false
            }
          }
          let changed = false
          const update = (path: string, scope: 'project' | 'course' = 'project', sourceCourseId = project.binding.courseId): string => {
            if (sourceCourseId !== input.courseId || (scope === 'project' && !ownsPaths)) return path
            const next = scope === 'course' ? replacePath(path, input.fromRelPath, input.toRelPath, input.isDirectory)
              : from !== null && to !== null ? replacePath(path, from, to, input.isDirectory) : path
            changed ||= path !== next; return next
          }
          for (const article of tx.state.articles) if (article.exportRelPath) article.exportRelPath = update(article.exportRelPath)
          for (const artifact of tx.state.artifacts) if (artifact.exportRelPath) artifact.exportRelPath = update(artifact.exportRelPath)
          for (const exported of tx.state.exports) exported.relPath = update(exported.relPath)
          for (const occurrence of tx.state.occurrences) {
            if (occurrence.sourceRef.relPath) occurrence.sourceRef.relPath = update(occurrence.sourceRef.relPath, occurrence.sourceRef.pathScope, occurrence.sourceRef.sourceCourseId)
          }
          for (const card of tx.state.cards) for (const source of card.sourceRefs) if (source.relPath) source.relPath = update(source.relPath, source.pathScope, source.sourceCourseId)
          for (const artifact of tx.state.artifacts) for (const source of artifact.sourceRefs) if (source.relPath) source.relPath = update(source.relPath, source.pathScope, source.sourceCourseId)
          for (const run of tx.state.runs) {
            if (run.source?.relPath) run.source.relPath = update(run.source.relPath, 'course', run.source.sourceCourseId)
            const repointSources = (refs: LearningSourceRef[]): void => {
              for (const source of refs) if (source.relPath) source.relPath = update(source.relPath, source.pathScope, source.sourceCourseId)
            }
            for (const word of run.draft?.words ?? []) repointSources([word.sourceRef])
            for (const artifact of run.draft?.artifacts ?? []) {
              repointSources(artifact.sourceRefs ?? [])
              if (artifact.kind === 'quiz') artifact.questions.forEach(question => repointSources(question.sourceRefs))
              if (artifact.kind === 'cards') artifact.cards.forEach(card => repointSources(card.sourceRefs))
            }
          }
          // Immutable artifact JSON retains its original citation. Resolve moved files at read time.
          tx.state.pathAliases ??= []
          tx.state.pathAliases.push({ fromRelPath: input.fromRelPath, toRelPath: input.toRelPath,
            isDirectory: input.isDirectory, scope: 'course', ...(ownsPaths ? {} : { sourceCourseId: input.courseId }),
            ...(input.operationId === undefined ? {} : { operationId: input.operationId }) })
          if (ownsPaths && from !== null && to !== null) tx.state.pathAliases.push({ fromRelPath: from, toRelPath: to,
            isDirectory: input.isDirectory, scope: 'project' })
          changed = true
          return changed
        }, true, input.operationId !== undefined)
      }
    }
  }
  return repo
}
