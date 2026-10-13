import { createHash } from 'node:crypto'
import type {
  LearningArticleSnapshot, LearningCard, LearningCardRating, LearningParagraph,
  LearningQuizQuestion
} from '../../../shared/types/learning'
import { ValidationError } from '../../db/errors'

export function learningHash(value: string | Buffer): string {
  return createHash('sha256').update(value).digest('hex')
}

export function normalizeLearningAnswer(value: string): string {
  return value.normalize('NFKC').toLocaleLowerCase('en-US').trim()
}

export function normalizeLearningLemma(value: string): string {
  return value.normalize('NFKC').toLocaleLowerCase('en-US').replace(/[’‘]/g, "'")
    .replace(/\s+/g, ' ').trim()
}

export function gradeLearningAnswer(question: LearningQuizQuestion, answer: string): boolean | null {
  if (question.type === 'short-answer') return null
  if (question.type === 'choice') return answer === question.answer
  const normalized = normalizeLearningAnswer(answer)
  return [question.answer, ...(question.acceptedAnswers ?? [])]
    .some((candidate) => normalizeLearningAnswer(candidate) === normalized)
}

/** A conservative schedule: reading encounters never advance these intervals. */
export function scheduleLearningCard(card: LearningCard, rating: LearningCardRating, now: string): LearningCard {
  if (!['again', 'hard', 'good'].includes(rating)) throw new ValidationError('올바른 복습 평가를 선택해 주세요.')
  const milliseconds = Date.parse(now)
  if (!Number.isFinite(milliseconds)) throw new ValidationError('올바르지 않은 복습 시간입니다.')
  if (rating === 'again') return {
    ...card, status: 'learning', dueAt: new Date(milliseconds + 10 * 60_000).toISOString(),
    intervalDays: 0, repetitions: 0, lapses: card.lapses + 1, lastReviewedAt: now
  }
  if (rating === 'hard') return {
    ...card, status: 'learning', dueAt: new Date(milliseconds + 86_400_000).toISOString(), lastReviewedAt: now
  }
  const intervalDays = [1, 3, 7, 14, 30][Math.min(card.repetitions, 4)]!
  return {
    ...card, status: 'review', intervalDays,
    dueAt: new Date(milliseconds + intervalDays * 86_400_000).toISOString(),
    repetitions: card.repetitions + 1, lastReviewedAt: now
  }
}

/** Offsets are UTF-16 positions, matching native DOM Selection and JS slicing. */
export function splitLearningParagraphs(text: string): LearningParagraph[] {
  const segmenter = new Intl.Segmenter('en', { granularity: 'sentence' })
  return text.replace(/\r\n?/g, '\n').split(/\n\s*\n/).map((paragraph) => paragraph.trim())
    .filter(Boolean).map((paragraph, index) => ({
      id: `p${index + 1}`, text: paragraph,
      sentences: [...segmenter.segment(paragraph)].map((entry, sentenceIndex) => {
        const leading = entry.segment.length - entry.segment.trimStart().length
        const sentence = entry.segment.trim()
        return { id: `p${index + 1}-s${sentenceIndex + 1}`, text: sentence,
          start: entry.index + leading, end: entry.index + leading + sentence.length }
      })
    }))
}

export function articleMarkdown(article: LearningArticleSnapshot): string {
  const clean = (value: string): string => value.replace(/[\r\n]/g, ' ')
  return [`# ${clean(article.title)}`, '', `[원문 보기](${article.sourceUrl})`, '',
    `${article.siteName ?? new URL(article.sourceUrl).hostname} · ${article.wordCount}단어 · 약 ${article.estimatedMinutes}분`, '',
    ...article.paragraphs.flatMap((paragraph) => [paragraph.text, ''])].join('\n')
}
