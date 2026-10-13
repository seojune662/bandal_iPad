/**
 * Quote anchors: the text-based half of an annotation (shared contract
 * `AnnotationAnchor` = { quote, prefix, suffix }). Built from the page text
 * at highlight time; used later to detect annotations whose source text has
 * drifted ("stale") after the PDF was replaced or re-exported.
 *
 * Matching is whitespace-tolerant (pdf.js text extraction is not stable
 * about spaces/line breaks between versions) but deliberately cheap — no
 * fuzzy diffing.
 */

import type { AnnotationAnchor } from '../../../../../shared/types/annotation'

/** Max characters kept on each side of the quote. */
export const ANCHOR_CONTEXT_MAX = 32

/** Best-match context score below which a found quote counts as moved. */
export const STALE_SCORE_THRESHOLD = 0.3

/** Cap on quote occurrences scanned per page (pathological pages). */
const MAX_OCCURRENCES = 64

/** Collapses all whitespace runs to single spaces (trimmed). */
export function normalizeWhitespace(text: string): string {
  return text.replace(/\s+/g, ' ').trim()
}

/**
 * Collapses whitespace runs WITHOUT trimming — context strings must keep
 * their boundary space so a prefix ending in " " still matches the space
 * before the quote in the page text.
 */
function collapseWhitespace(text: string): string {
  return text.replace(/\s+/g, ' ')
}

/**
 * Builds an anchor from the page text and the selection's character range.
 * Offsets are into `pageText` (end exclusive). Returns null when the range
 * yields an empty quote.
 */
export function buildAnchor(
  pageText: string,
  start: number,
  end: number
): AnnotationAnchor | null {
  const safeStart = Math.max(0, Math.min(start, pageText.length))
  const safeEnd = Math.max(safeStart, Math.min(end, pageText.length))
  const quote = pageText.slice(safeStart, safeEnd)
  if (normalizeWhitespace(quote).length === 0) return null
  return {
    quote,
    prefix: pageText.slice(Math.max(0, safeStart - ANCHOR_CONTEXT_MAX), safeStart),
    suffix: pageText.slice(safeEnd, safeEnd + ANCHOR_CONTEXT_MAX)
  }
}

export interface AnchorMatch {
  /** Index of the quote in the normalized page text. */
  index: number
  /** 0..1 — how well the stored prefix/suffix matched around it. */
  score: number
}

/** Length of the common suffix of `a` with the text ending at `end`. */
function backwardOverlap(text: string, end: number, context: string): number {
  let matched = 0
  while (
    matched < context.length &&
    end - 1 - matched >= 0 &&
    text[end - 1 - matched] === context[context.length - 1 - matched]
  ) {
    matched += 1
  }
  return matched
}

/** Length of the common prefix of `context` with the text starting at `start`. */
function forwardOverlap(text: string, start: number, context: string): number {
  let matched = 0
  while (
    matched < context.length &&
    start + matched < text.length &&
    text[start + matched] === context[matched]
  ) {
    matched += 1
  }
  return matched
}

/**
 * Finds the best occurrence of the anchor's quote in the page text, scored
 * by how much of the stored prefix/suffix context still matches around it.
 * All comparisons run on whitespace-normalized strings. Returns null when
 * the quote no longer appears at all.
 */
export function findAnchor(
  pageText: string,
  anchor: AnnotationAnchor
): AnchorMatch | null {
  const text = normalizeWhitespace(pageText)
  const collapsedQuote = collapseWhitespace(anchor.quote)
  const quote = collapsedQuote.trim()
  if (quote.length === 0 || text.length === 0) return null

  // Whitespace trimmed off the quote's edges migrates into the context so
  // boundary spaces still line up against the normalized page text.
  const prefix = collapseWhitespace(
    anchor.prefix + (collapsedQuote.startsWith(' ') ? ' ' : '')
  )
  const suffix = collapseWhitespace(
    (collapsedQuote.endsWith(' ') ? ' ' : '') + anchor.suffix
  )
  const contextLength = prefix.length + suffix.length

  let best: AnchorMatch | null = null
  let from = 0
  for (let seen = 0; seen < MAX_OCCURRENCES; seen += 1) {
    const index = text.indexOf(quote, from)
    if (index === -1) break
    from = index + 1

    let score: number
    if (contextLength === 0) {
      score = 1
    } else {
      const matched =
        backwardOverlap(text, index, prefix) +
        forwardOverlap(text, index + quote.length, suffix)
      score = matched / contextLength
    }
    if (best === null || score > best.score) {
      best = { index, score }
      if (score === 1) break
    }
  }
  return best
}

/**
 * Stale = the page text no longer contains the quote, or it appears only in
 * places whose surrounding context barely matches what was stored.
 * `pageText === null` means "text not extracted yet" → not stale.
 */
export function isAnchorStale(
  pageText: string | null,
  anchor: AnnotationAnchor
): boolean {
  if (pageText === null) return false
  const match = findAnchor(pageText, anchor)
  if (match === null) return true
  const hasContext =
    normalizeWhitespace(anchor.prefix).length > 0 ||
    normalizeWhitespace(anchor.suffix).length > 0
  return hasContext && match.score < STALE_SCORE_THRESHOLD
}
