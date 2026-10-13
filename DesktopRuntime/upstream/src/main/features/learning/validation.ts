import type {
  LearningArticleInput, LearningArticleSnapshot, LearningArtifactDraft,
  LearningCardDefinition, LearningDraft, LearningProjectState, LearningQuizQuestion,
  LearningRun, LearningSourceRef, LearningWordDraft, LearningProjectSettings, LearningAiSettings, LearningBinding
} from '../../../shared/types/learning'
import { LEARNING_TOPICS } from '../../../shared/types/learning'
import { isAgentProvider } from '../../../shared/types/agent-events'
import { ValidationError } from '../../db/errors'
import { learningHash } from './model'
import type { DictionarySource } from '../../../shared/types/dictionary'

/** Only our attributed dictionary URLs may be embedded in portable exports. */
export function validateDictionarySource(value: unknown): DictionarySource {
  const input = learningObject(value, 'dictionarySource')
  const headword = learningString(input['headword'], 'dictionary headword', 120).trim()
  const datasetVersion = learningString(input['datasetVersion'], 'dictionary version', 64)
  const url = learningString(input['url'], 'dictionary URL', 2_048)
  const canonical = `https://en.wiktionary.org/wiki/${encodeURIComponent(headword)}`
  if (/[\r\n\u0000-\u001f]/.test(headword) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(datasetVersion) || (url !== canonical && url !== `${canonical}#English`)
    || (input['modified'] !== undefined && input['modified'] !== true)) {
    throw new ValidationError('올바른 사전 출처가 필요합니다.')
  }
  return { headword, datasetVersion, url, ...(input['modified'] === true ? { modified: true } : {}) }
}

export function learningObject(value: unknown, field: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new ValidationError(`${field}은(는) 객체여야 합니다.`)
  return value as Record<string, unknown>
}
export function learningString(value: unknown, field: string, max = 100_000, allowEmpty = false): string {
  if (typeof value !== 'string' || value.length > max || (!allowEmpty && !value.trim())) throw new ValidationError(`${field}에 올바른 텍스트가 필요합니다.`)
  return value
}
export function learningId(value: unknown, field = 'id'): string {
  const id = learningString(value, field, 128)
  if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new ValidationError(`${field}에 올바른 식별자가 필요합니다.`)
  return id
}
export function learningArray(value: unknown, field: string, max = 100_000): unknown[] {
  if (!Array.isArray(value) || value.length > max) throw new ValidationError(`${field}에 올바른 목록이 필요합니다.`)
  return value
}
export function learningNumber(value: unknown, field: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) throw new ValidationError(`${field}에 올바른 숫자가 필요합니다.`)
  return value
}
export function learningPage(value: unknown, field = 'page'): number {
  const page = learningNumber(value, field, 1, Number.MAX_SAFE_INTEGER)
  if (!Number.isInteger(page)) throw new ValidationError('올바르지 않은 페이지입니다.')
  return page
}
export function learningTime(value: unknown, field: string): string {
  const time = learningString(value, field, 64)
  if (!Number.isFinite(Date.parse(time))) throw new ValidationError(`${field}에 올바른 시간이 필요합니다.`)
  return time
}
export function learningUrl(value: unknown, field: string): string {
  const text = learningString(value, field, 20_000)
  let url: URL
  try { url = new URL(text) } catch { throw new ValidationError(`${field}에 올바른 웹 주소가 필요합니다.`) }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new ValidationError(`${field}에는 HTTP(S) 웹 주소만 사용할 수 있습니다.`)
  url.hash = ''
  for (const key of [...url.searchParams.keys()]) if (/^(utm_|fbclid$|gclid$)/i.test(key)) url.searchParams.delete(key)
  return url.href
}
function optionalText(value: unknown, field: string): string | null {
  return value === null || value === undefined ? null : learningString(value, field, 10_000, true)
}
export function normalizeLearningArticle(value: unknown, id: string, now: string): LearningArticleSnapshot {
  const input = learningObject(value, 'article')
  const paragraphs = learningArray(input['paragraphs'], 'paragraphs', 2_000).map((entry) => {
    const paragraph = learningObject(entry, 'paragraph')
    const text = learningString(paragraph['text'], 'paragraph.text')
    const sentences = learningArray(paragraph['sentences'], 'sentences', 2_000).map((item) => {
      const sentence = learningObject(item, 'sentence')
      const start = learningNumber(sentence['start'], 'sentence.start', 0, text.length)
      const end = learningNumber(sentence['end'], 'sentence.end', start, text.length)
      const sentenceText = learningString(sentence['text'], 'sentence.text')
      if (!Number.isInteger(start) || !Number.isInteger(end) || text.slice(start, end) !== sentenceText) throw new ValidationError('문장의 본문 위치가 일치하지 않습니다.')
      return { id: learningId(sentence['id']), text: sentenceText, start, end }
    })
    if (!sentences.length || new Set(sentences.map((sentence) => sentence.id)).size !== sentences.length) throw new ValidationError('문장 식별자가 중복되거나 비어 있습니다.')
    return { id: learningId(paragraph['id']), text, sentences }
  })
  if (!paragraphs.length || new Set(paragraphs.map((paragraph) => paragraph.id)).size !== paragraphs.length) throw new ValidationError('기사 문단 식별자가 중복되거나 비어 있습니다.')
  const body = paragraphs.map((paragraph) => paragraph.text).join('\n\n')
  if (body.length > 500_000) throw new ValidationError('기사가 너무 깁니다.')
  const wordCount = body.match(/[A-Za-z]+(?:['’-][A-Za-z]+)*/g)?.length ?? 0
  if (!wordCount) throw new ValidationError('영어 기사 본문을 찾지 못했습니다.')
  const sourceUrl = learningUrl(input['sourceUrl'], 'sourceUrl')
  const access = input['access'] ?? 'public'
  if (!['public', 'source-tab'].includes(String(access))) throw new ValidationError('올바르지 않은 기사 접근 방식입니다.')
  return {
    id: learningId(id), sourceUrl, canonicalUrl: learningUrl(input['canonicalUrl'] ?? sourceUrl, 'canonicalUrl'),
    title: learningString(input['title'], 'title', 1_000), byline: optionalText(input['byline'], 'byline'),
    publishedAt: optionalText(input['publishedAt'], 'publishedAt'), siteName: optionalText(input['siteName'], 'siteName'),
    language: learningString(input['language'] ?? 'en', 'language', 100), wordCount,
    estimatedMinutes: Math.max(1, Math.ceil(wordCount / 150)), paragraphs,
    contentHash: learningHash(body), fetchedAt: learningTime(input['fetchedAt'] ?? now, 'fetchedAt'),
    access: access as 'public' | 'source-tab', createdAt: now
  }
}

/** Validates saved preferences without silently selecting a provider or classifying legacy data. */
export function validateLearningAi(value: unknown): LearningAiSettings {
  const ai = learningObject(value, 'ai')
  if (!isAgentProvider(ai['provider'])) throw new ValidationError('사용할 AI를 선택하세요.')
  const model = learningString(ai['model'], 'ai.model', 300).trim()
  const effort = ai['effort'] === null ? null : learningString(ai['effort'], 'ai.effort', 100)
  return { provider: ai['provider'], model, effort }
}
export function validateLearningSettings(value: unknown): Partial<LearningProjectSettings> {
  const input = learningObject(value, 'settings')
  const settings: Partial<LearningProjectSettings> = {}
  if (input['purpose'] !== undefined) {
    if (!['english-reading', 'course-review', 'unclassified'].includes(String(input['purpose']))) throw new ValidationError('학습 공간의 용도를 선택하세요.')
    settings.purpose = input['purpose'] as LearningProjectSettings['purpose']
  }
  if (input['topicIds'] !== undefined) {
    const ids = learningArray(input['topicIds'], 'topicIds', 3).map(id => learningId(id, 'topicId'))
    if (new Set(ids).size !== ids.length || ids.some(id => !LEARNING_TOPICS.some(topic => topic.id === id))) throw new ValidationError('관심 주제를 다시 선택하세요.')
    settings.topicIds = ids
  }
  if (input['readingSetupConfirmed'] !== undefined) {
    if (typeof input['readingSetupConfirmed'] !== 'boolean') throw new ValidationError('읽기 설정 확인 값이 올바르지 않습니다.')
    settings.readingSetupConfirmed = input['readingSetupConfirmed']
  }
  if (input['ai'] !== undefined) settings.ai = validateLearningAi(input['ai'])
  if (input['linkedCourseId'] !== undefined) settings.linkedCourseId = learningId(input['linkedCourseId'], 'linkedCourseId')
  if (input['packId'] !== undefined) settings.packId = learningString(input['packId'], 'packId', 200)
  return settings
}
export function requireEnglishReadingSettings(settings: Partial<LearningProjectSettings>, level: unknown, minutes: unknown): void {
  if (settings.purpose !== 'english-reading' || settings.readingSetupConfirmed !== true || !settings.topicIds?.length || !settings.ai) throw new ValidationError('관심 주제와 AI를 선택하고 영어 읽기 설정을 확인하세요.')
  if (!['beginner', 'intermediate', 'advanced'].includes(String(level))) throw new ValidationError('영어 읽기 수준을 선택하세요.')
  learningNumber(minutes, 'readingMinutes', 1, 30)
}

export interface LearningValidationContext {
  state: LearningProjectState
  binding?: LearningBinding
  readArticle(id: string): Promise<LearningArticleSnapshot>
  validateMaterial?(ref: LearningSourceRef): Promise<void>
}

export async function validateLearningSource(value: unknown, context: LearningValidationContext): Promise<LearningSourceRef> {
  const input = learningObject(value, 'sourceRef')
  const kind = input['kind']
  if (kind !== 'article' && kind !== 'material' && kind !== 'web') throw new ValidationError('올바르지 않은 자료 출처입니다.')
  const ref: LearningSourceRef = { kind, quote: learningString(input['quote'], 'quote', 100_000) }
  if (input['title'] !== undefined) ref.title = learningString(input['title'], 'title', 1_000, true)
  if (input['contentHash'] !== undefined) {
    const hash = learningString(input['contentHash'], 'contentHash', 64)
    if (!/^[a-f0-9]{64}$/.test(hash)) throw new ValidationError('올바르지 않은 자료 해시입니다.')
    ref.contentHash = hash
  }
  if (kind === 'article') {
    ref.articleId = learningId(input['articleId'], 'articleId')
    const article = await context.readArticle(ref.articleId)
    if (ref.contentHash && ref.contentHash !== article.contentHash) throw new ValidationError('기사 출처의 해시가 원문과 일치하지 않습니다.')
    ref.contentHash = article.contentHash
    const paragraphId = input['paragraphId']
    const paragraph = paragraphId === undefined ? article.paragraphs.find((entry) => entry.text.includes(ref.quote))
      : article.paragraphs.find((entry) => entry.id === paragraphId)
    if (!paragraph || !paragraph.text.includes(ref.quote)) throw new ValidationError('예문이 저장된 원문에 없습니다.')
    ref.paragraphId = paragraph.id
    if (input['sentenceId'] !== undefined) {
      ref.sentenceId = learningId(input['sentenceId'], 'sentenceId')
      const sentence = paragraph.sentences.find((entry) => entry.id === ref.sentenceId)
      if (!sentence || !sentence.text.includes(ref.quote)) throw new ValidationError('선택한 문장의 출처가 일치하지 않습니다.')
    }
    if (input['start'] !== undefined || input['end'] !== undefined) {
      ref.start = learningNumber(input['start'], 'start', 0, paragraph.text.length)
      ref.end = learningNumber(input['end'], 'end', ref.start, paragraph.text.length)
      if (!Number.isInteger(ref.start) || !Number.isInteger(ref.end) || paragraph.text.slice(ref.start, ref.end).trim() !== ref.quote.trim()) throw new ValidationError('선택한 단어 위치가 원문과 일치하지 않습니다.')
    }
  } else if (kind === 'material') {
    ref.relPath = learningString(input['relPath'], 'relPath', 8_192)
    if (input['pathScope'] !== undefined) {
      if (input['pathScope'] !== 'project' && input['pathScope'] !== 'course') throw new ValidationError('올바르지 않은 출처 경로 범위입니다.')
      ref.pathScope = input['pathScope']
    }
    if (input['sourceCourseId'] !== undefined) {
      ref.sourceCourseId = learningId(input['sourceCourseId'], 'sourceCourseId')
      if (ref.pathScope !== 'course') throw new ValidationError('외부 과목 출처는 과목 경로를 사용해야 합니다.')
      if (context.binding && ref.sourceCourseId !== context.binding.courseId && ref.sourceCourseId !== context.state.linkedCourseId) throw new ValidationError('연결되지 않은 과목의 출처입니다.')
    }
    if (input['page'] !== undefined) {
      ref.page = learningPage(input['page'])
    }
    await context.validateMaterial?.(ref)
  } else ref.url = learningUrl(input['url'], 'url')
  return ref
}

export async function validateLearningWordDraft(value: unknown, context: LearningValidationContext): Promise<LearningWordDraft> {
  const input = learningObject(value, 'word')
  const surface = learningString(input['surface'], 'surface', 1_000).trim()
  if (!surface || surface.split(/\s+/).length > 10) throw new ValidationError('단어나 짧은 표현을 선택해 주세요.')
  const sourceRef = await validateLearningSource(input['sourceRef'], context)
  if (sourceRef.kind === 'web') throw new ValidationError('단어는 저장된 기사나 원본 자료의 인용에서 가져와야 합니다.')
  let sentence = learningString(input['sentence'], 'sentence', 20_000).trim()
  if (sourceRef.kind === 'article') {
    const article = await context.readArticle(sourceRef.articleId!)
    const paragraph = article.paragraphs.find(entry => entry.id === sourceRef.paragraphId)!
    const actual = paragraph.sentences.find(entry => entry.id === sourceRef.sentenceId)
      ?? paragraph.sentences.find(entry => entry.text.includes(sourceRef.quote))
    if (!actual || !actual.text.includes(surface)) throw new ValidationError('단어가 선택한 원문 문장에 없습니다.')
    sentence = actual.text; sourceRef.sentenceId = actual.id
  } else if (!sentence.includes(surface) || !sourceRef.quote.includes(sentence)) {
    throw new ValidationError('가져올 단어와 문장은 보존한 출처 인용에 포함되어야 합니다.')
  }
  const word: LearningWordDraft = { surface, sentence, sourceRef }
  for (const field of ['lemma', 'meaning', 'pronunciation', 'partOfSpeech'] as const) {
    if (input[field] !== undefined) word[field] = learningString(input[field], field, field === 'meaning' ? 20_000 : 1_000, field !== 'lemma')
  }
  if (input['dictionarySource'] !== undefined) word.dictionarySource = validateDictionarySource(input['dictionarySource'])
  return word
}

async function sources(value: unknown, context: LearningValidationContext): Promise<LearningSourceRef[]> {
  const list = learningArray(value, 'sourceRefs', 1_000)
  return Promise.all(list.map((ref) => validateLearningSource(ref, context)))
}
function knownIds(value: unknown, field: 'articleIds' | 'wordIds', state: LearningProjectState): string[] {
  const ids = learningArray(value ?? [], field, 10_000).map((id) => learningId(id, field))
  const known = new Set((field === 'articleIds' ? state.articles : state.words).map((record) => record.id))
  if (ids.some((id) => !known.has(id))) throw new ValidationError(`${field}의 출처 자료를 찾지 못했습니다.`)
  return [...new Set(ids)]
}
export async function validateLearningArtifact(value: unknown, context: LearningValidationContext): Promise<LearningArtifactDraft> {
  const input = learningObject(value, 'artifact')
  const base = {
    ...(input['id'] === undefined ? {} : { id: learningId(input['id']) }),
    title: learningString(input['title'], 'title', 1_000),
    sourceRefs: await sources(input['sourceRefs'] ?? [], context),
    articleIds: knownIds(input['articleIds'], 'articleIds', context.state),
    wordIds: knownIds(input['wordIds'], 'wordIds', context.state)
  }
  if (input['kind'] === 'quiz') {
    const questions: LearningQuizQuestion[] = []
    for (const entry of learningArray(input['questions'], 'questions', 100)) {
      const question = learningObject(entry, 'question')
      const type = question['type']
      if (!['choice', 'cloze', 'short-answer'].includes(String(type))) throw new ValidationError('지원하지 않는 퀴즈 문항입니다.')
      const refs = await sources(question['sourceRefs'], context)
      if (!refs.length) throw new ValidationError('퀴즈 문항에는 출처가 필요합니다.')
      const item: LearningQuizQuestion = {
        id: learningId(question['id']), type: type as LearningQuizQuestion['type'],
        prompt: learningString(question['prompt'], 'prompt', 10_000), answer: learningString(question['answer'] ?? '', 'answer', 10_000, type === 'short-answer'),
        explanation: learningString(question['explanation'] ?? '', 'explanation', 20_000, true), sourceRefs: refs
      }
      if (type === 'choice') {
        item.options = learningArray(question['options'], 'options', 20).map((option) => {
          const record = learningObject(option, 'option')
          return { id: learningId(record['id']), text: learningString(record['text'], 'option.text', 10_000) }
        })
        if (item.options.length < 2 || new Set(item.options.map((option) => option.id)).size !== item.options.length || !item.options.some((option) => option.id === item.answer)) throw new ValidationError('선택지와 정답 식별자가 일치하지 않습니다.')
      }
      if (type === 'cloze' && question['acceptedAnswers'] !== undefined) item.acceptedAnswers = learningArray(question['acceptedAnswers'], 'acceptedAnswers', 100).map((answer) => learningString(answer, 'acceptedAnswer', 10_000))
      if (question['modelAnswer'] !== undefined) item.modelAnswer = learningString(question['modelAnswer'], 'modelAnswer', 20_000, true)
      if (question['checkingPoints'] !== undefined) item.checkingPoints = learningArray(question['checkingPoints'], 'checkingPoints', 100).map((point) => learningString(point, 'checkingPoint', 10_000))
      if (type === 'short-answer' && !item.modelAnswer && !item.checkingPoints?.length) throw new ValidationError('서술형 문항에는 모범 답안이나 자기 점검 기준이 필요합니다.')
      if (question['wordId'] !== undefined) item.wordId = knownIds([question['wordId']], 'wordIds', context.state)[0]!
      questions.push(item)
    }
    if (!questions.length || new Set(questions.map((question) => question.id)).size !== questions.length) throw new ValidationError('문항이 없거나 식별자가 중복되었습니다.')
    return { ...base, kind: 'quiz', questions }
  }
  if (input['kind'] === 'cards') {
    const cards: LearningCardDefinition[] = []
    for (const entry of learningArray(input['cards'], 'cards', 1_000)) {
      const card = learningObject(entry, 'card')
      const refs = await sources(card['sourceRefs'], context)
      if (!refs.length) throw new ValidationError('플래시카드에는 출처가 필요합니다.')
      const item: LearningCardDefinition = { id: learningId(card['id']), front: learningString(card['front'], 'front', 20_000), back: learningString(card['back'], 'back', 20_000), sourceRefs: refs }
      if (card['wordId'] !== undefined) item.wordId = knownIds([card['wordId']], 'wordIds', context.state)[0]!
      cards.push(item)
    }
    if (!cards.length) throw new ValidationError('플래시카드가 없습니다.')
    return { ...base, kind: 'cards', cards }
  }
  if (input['kind'] === 'summary') {
    if (!base.sourceRefs.length) throw new ValidationError('요약 자료에는 출처가 필요합니다.')
    return { ...base, kind: 'summary', markdown: learningString(input['markdown'], 'markdown', 500_000) }
  }
  throw new ValidationError('지원하지 않는 학습 자료입니다.')
}

/** Validates structural content without committing any files. */
export async function validateLearningDraft(value: unknown, context: LearningValidationContext): Promise<LearningDraft> {
  const input = learningObject(value, 'draft')
  if (input['version'] !== 1) throw new ValidationError('지원하지 않는 학습 초안 버전입니다.')
  const draft: LearningDraft = { version: 1 }
  const stagedArticles = new Map<string, LearningArticleSnapshot>()
  if (input['articles'] !== undefined) {
    draft.articles = learningArray(input['articles'], 'articles', 20).map((article) => {
      const record = learningObject(article, 'article')
      const normalized = normalizeLearningArticle(record, record['id'] === undefined ? `draft-${learningHash(JSON.stringify(record)).slice(0, 20)}` : learningId(record['id']), new Date().toISOString())
      stagedArticles.set(normalized.id, normalized)
      return { ...normalized, ...(record['matchedWordIds'] === undefined ? {} : {
        matchedWordIds: knownIds(record['matchedWordIds'], 'wordIds', context.state)
      }) } as LearningArticleInput
    })
  }
  const stagedContext: LearningValidationContext = {
    ...context, state: { ...context.state, articles: [...context.state.articles,
      ...[...stagedArticles.values()].filter((article) => !context.state.articles.some((entry) => entry.id === article.id)).map((article) => ({
        id: article.id, title: article.title, sourceUrl: article.sourceUrl, canonicalUrl: article.canonicalUrl,
        snapshotRelPath: '', exportRelPath: null, contentHash: article.contentHash,
        wordCount: article.wordCount, estimatedMinutes: article.estimatedMinutes, createdAt: article.createdAt,
        status: 'unread' as const, progress: { paragraphId: null, scrollFraction: 0 }, completedAt: null, matchedWordIds: []
      }))] },
    readArticle: (id) => stagedArticles.has(id) ? Promise.resolve(stagedArticles.get(id)!) : context.readArticle(id)
  }
  if (input['artifacts'] !== undefined) {
    draft.artifacts = []
    for (const artifact of learningArray(input['artifacts'], 'artifacts', 20)) draft.artifacts.push(await validateLearningArtifact(artifact, stagedContext))
  }
  if (input['words'] !== undefined) {
    draft.words = []
    for (const word of learningArray(input['words'], 'words', 500)) draft.words.push(await validateLearningWordDraft(word, stagedContext))
  }
  if (input['wordUpdates'] !== undefined) {
    draft.wordUpdates = learningArray(input['wordUpdates'], 'wordUpdates', 1_000).map((entry) => {
      const record = learningObject(entry, 'wordUpdate')
      const wordId = knownIds([record['wordId']], 'wordIds', context.state)[0]!
      const occurrenceId = record['occurrenceId'] === undefined ? undefined : learningId(record['occurrenceId'], 'occurrenceId')
      if (occurrenceId !== undefined && !context.state.occurrences.some((entry) => entry.id === occurrenceId && entry.wordId === wordId)) throw new ValidationError('설명할 단어의 출현 문장을 찾지 못했습니다.')
      return { wordId, meaning: learningString(record['meaning'], 'meaning', 20_000),
        ...(occurrenceId === undefined ? {} : { occurrenceId }),
        ...(record['lemma'] === undefined ? {} : { lemma: learningString(record['lemma'], 'lemma', 1_000) }),
        ...(record['pronunciation'] === undefined ? {} : { pronunciation: learningString(record['pronunciation'], 'pronunciation', 1_000, true) }),
        ...(record['partOfSpeech'] === undefined ? {} : { partOfSpeech: learningString(record['partOfSpeech'], 'partOfSpeech', 1_000, true) }) }
    })
  }
  if (!draft.articles?.length && !draft.artifacts?.length && !draft.words?.length && !draft.wordUpdates?.length) throw new ValidationError('저장할 학습 결과가 없습니다.')
  return draft
}

export function normalizeLearningDraft(
  value: unknown, state: LearningProjectState,
  readArticle: (id: string) => Promise<LearningArticleSnapshot>,
  validateMaterial?: (ref: LearningSourceRef) => Promise<void>
): Promise<LearningDraft> {
  return validateLearningDraft(value, { state, readArticle,
    ...(validateMaterial === undefined ? {} : { validateMaterial }) })
}

export function validateLearningRun(value: unknown): LearningRun {
  const input = learningObject(value, 'run')
  learningId(input['id'])
  if (input['packId'] !== undefined) learningString(input['packId'], 'packId', 200)
  if (!['find-articles', 'explain-word', 'create-quiz', 'create-cards', 'create-summary', 'import-material'].includes(String(input['kind']))) throw new ValidationError('올바르지 않은 학습 실행 종류입니다.')
  if (!['queued', 'running', 'validating', 'interrupted', 'awaiting-confirmation', 'complete', 'failed', 'cancelled'].includes(String(input['status']))) throw new ValidationError('올바르지 않은 학습 실행 상태입니다.')
  learningString(input['provider'], 'provider', 100, true)
  for (const field of ['model', 'sessionId', 'errorCode', 'actionable'] as const) if (input[field] !== undefined) learningString(input[field], field, field === 'actionable' ? 10_000 : 300, true)
  if (input['effort'] !== undefined && input['effort'] !== null) learningString(input['effort'], 'effort', 100)
  if (input['errorCategory'] !== undefined && !['connection', 'model', 'quota', 'network', 'tool', 'source', 'validation', 'timeout', 'cancelled', 'unknown'].includes(String(input['errorCategory']))) throw new ValidationError('올바르지 않은 오류 분류입니다.')
  validateLearningSettings(input)
  learningString(input['message'], 'message', 10_000, true)
  optionalText(input['error'], 'error')
  learningTime(input['createdAt'], 'createdAt'); learningTime(input['updatedAt'], 'updatedAt')
  if (input['dismissedAt'] !== undefined && input['dismissedAt'] !== null) learningTime(input['dismissedAt'], 'dismissedAt')
  for (const field of ['resultArticleIds', 'resultArtifactIds'] as const) if (input[field] !== undefined) learningArray(input[field], field, 10_000).forEach(id => learningId(id))
  learningArray(input['articleIds'], 'articleIds', 10_000).forEach((id) => learningId(id))
  learningArray(input['wordIds'], 'wordIds', 10_000).forEach((id) => learningId(id))
  if (input['source'] !== undefined) {
    const source = learningObject(input['source'], 'source')
    if (!['course', 'material', 'article', 'vocabulary'].includes(String(source['kind']))) throw new ValidationError('올바르지 않은 실행 출처입니다.')
    if (source['page'] !== undefined) {
      if (source['kind'] !== 'material') throw new ValidationError('페이지 출처는 원본 자료에서만 사용할 수 있습니다.')
      learningPage(source['page'], 'source.page')
    }
    if (source['relPath'] !== undefined) learningString(source['relPath'], 'source.relPath', 8_192)
    if (source['sourceCourseId'] !== undefined) learningId(source['sourceCourseId'], 'sourceCourseId')
    if (source['selection'] !== undefined) learningString(source['selection'], 'source.selection', 100_000, true)
  }
  return structuredClone(input) as unknown as LearningRun
}

/** Loading validation keeps a damaged file from silently becoming an empty project. */
export function validateLearningState(value: unknown): LearningProjectState {
  const state = learningObject(value, 'state')
  if (state['schemaVersion'] !== 1) throw new ValidationError('지원하지 않는 학습 데이터 버전입니다.')
  learningId(state['projectId'], 'projectId')
  const revision = learningNumber(state['revision'], 'revision')
  if (!Number.isInteger(revision)) throw new ValidationError('올바르지 않은 데이터 버전입니다.')
  const settings = validateLearningSettings(state)
  learningString(state['name'], 'name', 1_000); learningString(state['topic'], 'topic', 10_000)
  if (!['beginner', 'intermediate', 'advanced'].includes(String(state['level']))) throw new ValidationError('올바르지 않은 학습 난이도입니다.')
  learningNumber(state['readingMinutes'], 'readingMinutes', 1, 30)
  learningTime(state['createdAt'], 'createdAt'); learningTime(state['updatedAt'], 'updatedAt')
  if (state['deletedAt'] !== undefined && state['deletedAt'] !== null) learningTime(state['deletedAt'], 'deletedAt')
  for (const key of ['articles', 'words', 'occurrences', 'artifacts', 'cards', 'quizAttempts', 'runs', 'history'] as const) {
    const entries = learningArray(state[key], key)
    const seen = new Set<string>()
    for (const entry of entries) {
      const record = learningObject(entry, key)
      const id = learningId(record['id'], `${key}.id`)
      if (seen.has(id)) throw new ValidationError(`${key}의 식별자가 중복되었습니다.`)
      seen.add(id)
    }
  }
  learningArray(state['exports'], 'exports').forEach((entry) => {
    const record = learningObject(entry, 'export'); learningString(record['relPath'], 'export.relPath', 8_192); learningString(record['contentHash'], 'export.contentHash', 64)
  })
  const sourcesShape = (value: unknown): void => {
    for (const item of learningArray(value, 'sourceRefs', 1_000)) {
      const source = learningObject(item, 'sourceRef')
      learningString(source['quote'], 'quote')
      if (source['kind'] === 'article') learningId(source['articleId'], 'articleId')
      else if (source['kind'] === 'material') {
        learningString(source['relPath'], 'relPath', 8_192)
        if (source['sourceCourseId'] !== undefined) learningId(source['sourceCourseId'], 'sourceCourseId')
        if (source['page'] !== undefined) learningPage(source['page'])
        if (source['pathScope'] !== undefined && source['pathScope'] !== 'project' && source['pathScope'] !== 'course') throw new ValidationError('올바르지 않은 출처 경로 범위입니다.')
      } else if (source['kind'] === 'web') learningUrl(source['url'], 'url')
      else throw new ValidationError('올바르지 않은 출처입니다.')
    }
  }
  const articles = learningArray(state['articles'], 'articles').map((entry) => learningObject(entry, 'article'))
  const wordIds = new Set(learningArray(state['words'], 'words').map((entry) => learningObject(entry, 'word')['id']))
  const artifactIds = new Set(learningArray(state['artifacts'], 'artifacts').map((entry) => learningObject(entry, 'artifact')['id']))
  for (const article of articles) {
    learningString(article['title'], 'title', 1_000); learningUrl(article['sourceUrl'], 'sourceUrl'); learningUrl(article['canonicalUrl'], 'canonicalUrl')
    learningString(article['snapshotRelPath'], 'snapshotRelPath', 8_192)
    if (article['exportRelPath'] !== null) learningString(article['exportRelPath'], 'exportRelPath', 8_192)
    learningString(article['contentHash'], 'contentHash', 64); learningTime(article['createdAt'], 'createdAt')
    learningNumber(article['wordCount'], 'wordCount'); learningNumber(article['estimatedMinutes'], 'estimatedMinutes', 1)
    if (!['unread', 'reading', 'completed'].includes(String(article['status']))) throw new ValidationError('올바르지 않은 기사 읽기 상태입니다.')
    const progress = learningObject(article['progress'], 'progress')
    learningNumber(progress['scrollFraction'], 'scrollFraction', 0, 1)
    if (progress['paragraphId'] !== null) learningId(progress['paragraphId'], 'paragraphId')
    if (article['completedAt'] !== null) learningTime(article['completedAt'], 'completedAt')
    learningArray(article['matchedWordIds'], 'matchedWordIds').forEach((id) => learningId(id))
  }
  for (const entry of learningArray(state['words'], 'words')) {
    const word = learningObject(entry, 'word')
    if (word['dictionarySource'] !== undefined) validateDictionarySource(word['dictionarySource'])
    learningString(word['surface'], 'surface', 1_000); learningString(word['lemma'], 'lemma', 1_000)
    for (const field of ['meaning', 'pronunciation', 'partOfSpeech'] as const) learningString(word[field], field, 20_000, true)
    if (!['new', 'learning', 'known'].includes(String(word['status']))) throw new ValidationError('올바르지 않은 단어 상태입니다.')
    learningTime(word['createdAt'], 'createdAt'); learningTime(word['updatedAt'], 'updatedAt')
  }
  for (const entry of learningArray(state['occurrences'], 'occurrences')) {
    const occurrence = learningObject(entry, 'occurrence')
    if (occurrence['dictionarySource'] !== undefined) validateDictionarySource(occurrence['dictionarySource'])
    learningId(occurrence['wordId'], 'wordId')
    if (!wordIds.has(occurrence['wordId'])) throw new ValidationError('예문의 단어가 없습니다.')
    learningString(occurrence['surface'], 'surface', 1_000); learningString(occurrence['sentence'], 'sentence', 20_000)
    learningString(occurrence['meaning'], 'meaning', 20_000, true); learningTime(occurrence['createdAt'], 'createdAt')
    sourcesShape([occurrence['sourceRef']])
  }
  for (const entry of learningArray(state['artifacts'], 'artifacts')) {
    const artifact = learningObject(entry, 'artifact')
    if (!['quiz', 'cards', 'summary'].includes(String(artifact['kind']))) throw new ValidationError('올바르지 않은 학습 자료 종류입니다.')
    learningString(artifact['title'], 'title', 1_000); learningString(artifact['relPath'], 'relPath', 8_192)
    learningString(artifact['contentHash'], 'contentHash', 64)
    if (artifact['exportRelPath'] !== null) learningString(artifact['exportRelPath'], 'exportRelPath', 8_192)
    learningTime(artifact['createdAt'], 'createdAt'); sourcesShape(artifact['sourceRefs'])
    learningArray(artifact['articleIds'], 'articleIds').forEach((id) => learningId(id)); learningArray(artifact['wordIds'], 'wordIds').forEach((id) => learningId(id))
  }
  for (const entry of learningArray(state['cards'], 'cards')) {
    const card = learningObject(entry, 'card')
    learningId(card['artifactId'], 'artifactId')
    if (!artifactIds.has(card['artifactId'])) throw new ValidationError('카드의 원본 자료가 없습니다.')
    learningString(card['front'], 'front', 20_000); learningString(card['back'], 'back', 20_000); sourcesShape(card['sourceRefs'])
    if (!['new', 'learning', 'review'].includes(String(card['status']))) throw new ValidationError('올바르지 않은 복습 상태입니다.')
    learningTime(card['dueAt'], 'dueAt')
    for (const field of ['intervalDays', 'repetitions', 'lapses'] as const) learningNumber(card[field], field)
    if (card['lastReviewedAt'] !== null) learningTime(card['lastReviewedAt'], 'lastReviewedAt')
  }
  for (const entry of learningArray(state['quizAttempts'], 'quizAttempts')) {
    const attempt = learningObject(entry, 'quizAttempt')
    learningId(attempt['artifactId'], 'artifactId')
    if (!artifactIds.has(attempt['artifactId'])) throw new ValidationError('퀴즈의 원본 자료가 없습니다.')
    learningTime(attempt['startedAt'], 'startedAt')
    if (attempt['completedAt'] !== null) learningTime(attempt['completedAt'], 'completedAt')
    for (const field of ['score', 'total', 'selfCheckedCount', 'selfPassedCount'] as const) learningNumber(attempt[field], field)
    if (attempt['resultRelPath'] !== null) learningString(attempt['resultRelPath'], 'resultRelPath', 8_192)
    const answerIds = new Set<string>()
    for (const item of learningArray(attempt['answers'], 'answers', 100)) {
      const answer = learningObject(item, 'answer')
      const id = learningId(answer['questionId'], 'questionId')
      if (answerIds.has(id)) throw new ValidationError('같은 문항의 응답이 중복되었습니다.')
      answerIds.add(id); learningString(answer['answer'], 'answer', 20_000, true); learningTime(answer['answeredAt'], 'answeredAt')
      if (answer['correct'] !== null && typeof answer['correct'] !== 'boolean') throw new ValidationError('올바르지 않은 채점 결과입니다.')
      if (answer['selfCheck'] !== undefined && typeof answer['selfCheck'] !== 'boolean') throw new ValidationError('올바르지 않은 자기 점검입니다.')
    }
  }
  learningArray(state['runs'], 'runs').forEach(validateLearningRun)
  for (const entry of learningArray(state['history'], 'history')) {
    const history = learningObject(entry, 'history')
    if (!['article-added', 'article-completed', 'word-saved', 'artifact-created', 'quiz-completed', 'card-reviewed'].includes(String(history['kind']))) throw new ValidationError('올바르지 않은 학습 이력입니다.')
    learningId(history['entityId'], 'entityId'); learningTime(history['createdAt'], 'createdAt'); learningString(history['summary'], 'summary', 10_000)
  }
  if (state['pathAliases'] !== undefined) for (const entry of learningArray(state['pathAliases'], 'pathAliases')) {
    const alias = learningObject(entry, 'pathAlias')
    if (alias['sourceCourseId'] !== undefined) learningId(alias['sourceCourseId'], 'sourceCourseId')
    learningString(alias['fromRelPath'], 'fromRelPath', 8_192); learningString(alias['toRelPath'], 'toRelPath', 8_192)
    if (typeof alias['isDirectory'] !== 'boolean' || !['project', 'course'].includes(String(alias['scope']))) throw new ValidationError('올바르지 않은 이동 경로입니다.')
  }
  return { ...structuredClone(state), ...settings, purpose: settings.purpose ?? (state['name'] === 'AI 학습자료' && state['topic'] === '과목 자료' ? 'course-review' : 'unclassified'), topicIds: settings.topicIds ?? [], readingSetupConfirmed: settings.readingSetupConfirmed ?? false } as unknown as LearningProjectState
}
