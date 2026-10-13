import type { LearningArticleSnapshot, LearningOccurrence, LearningSourceRef, LearningWord } from '../../../../shared/types/learning'

export interface ReaderWordSelection {
  surface: string
  sentence: string
  sourceRef: LearningSourceRef
}

export function readerSelectionKey(selection: ReaderWordSelection): string {
  const source = selection.sourceRef
  return JSON.stringify([source.articleId, source.paragraphId, source.start, source.end])
}

export function readerSavedOccurrence(occurrences: LearningOccurrence[], selection: ReaderWordSelection): LearningOccurrence | undefined {
  return occurrences.find(item => readerSelectionKey(item) === readerSelectionKey(selection))
}

export interface ReaderVocabularyMatch { wordId: string; start: number; end: number }
const normalizedSurface = (value: string): string => value.normalize('NFKC').toLocaleLowerCase('en-US').replace(/[’‘]/g, "'").replace(/\s+/g, ' ').trim()

export function learningWordForSurface(words: LearningWord[], surface: string): LearningWord | undefined {
  const normalized = normalizedSurface(surface)
  return words.find(word => normalizedSurface(word.surface) === normalized || normalizedSurface(word.lemma) === normalized)
}

/** Match literal expressions at whole-token boundaries, preferring complete phrases. */
export function readerVocabularyMatches(text: string, words: LearningWord[]): ReaderVocabularyMatch[] {
  const matches: ReaderVocabularyMatch[] = []
  for (const word of words) {
    for (const expression of new Set([word.surface.trim(), word.lemma.trim()].filter(Boolean))) {
      const literal = expression.split(/\s+/).map(token => token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('\\s+')
      const pattern = new RegExp(`(?<![A-Za-z’'\\-])${literal}(?![A-Za-z’'\\-])`, 'gi')
      for (const match of text.matchAll(pattern)) matches.push({ wordId: word.id, start: match.index, end: match.index + match[0].length })
    }
  }
  return matches.sort((a, b) => (b.end - b.start) - (a.end - a.start) || a.start - b.start)
    .filter((match, index, sorted) => !sorted.slice(0, index).some(prior => prior.start < match.end && prior.end > match.start))
    .sort((a, b) => a.start - b.start)
}

/** Offsets are measured against the saved paragraph, including repeated words. */
export function readerWordSelection(article: LearningArticleSnapshot, paragraphId: string, start: number, end: number): ReaderWordSelection | null {
  const paragraph = article.paragraphs.find(item => item.id === paragraphId)
  if (!paragraph || !Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end > paragraph.text.length || start >= end) return null
  const raw = paragraph.text.slice(start, end)
  const surface = raw.trim()
  if (!surface || surface.length > 120 || /\n/.test(surface)) return null
  const trimmedStart = start + raw.indexOf(surface)
  const trimmedEnd = trimmedStart + surface.length
  const sentence = paragraph.sentences.find(item => item.start <= trimmedStart && item.end >= trimmedEnd)
  if (!sentence) return null
  return { surface, sentence: sentence.text, sourceRef: { kind: 'article', quote: surface,
    articleId: article.id, paragraphId, sentenceId: sentence.id, start: trimmedStart, end: trimmedEnd,
    url: article.sourceUrl, title: article.title } }
}

export function selectionInReader(article: LearningArticleSnapshot, root: HTMLElement, selection: Selection | null): ReaderWordSelection | null {
  if (!selection || selection.isCollapsed || selection.rangeCount !== 1) return null
  const range = selection.getRangeAt(0)
  const anchor = range.startContainer instanceof Element ? range.startContainer : range.startContainer.parentElement
  const paragraph = anchor?.closest<HTMLElement>('[data-learning-paragraph]')
  if (!paragraph || !root.contains(paragraph) || !paragraph.contains(range.endContainer)) return null
  const prefix = document.createRange()
  prefix.selectNodeContents(paragraph)
  prefix.setEnd(range.startContainer, range.startOffset)
  const start = prefix.toString().length
  return readerWordSelection(article, paragraph.dataset.learningParagraph ?? '', start, start + range.toString().length)
}
