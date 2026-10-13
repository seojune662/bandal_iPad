/**
 * Searching INSIDE course material, and noticing what has not been touched.
 *
 * Filename search already exists (`materials:search`). This is the other half:
 * a student who remembers a concept but not which file it was in.
 */

export type SearchHitKind = 'note' | 'pdf' | 'text'

export interface SearchHit {
  kind: SearchHitKind
  relPath: string
  /** 1-based page for pdf hits, null for whole-file text. */
  page: number | null
  /** Matched line/sentence with surrounding context, already trimmed. */
  snippet: string
  /** Higher is better. Ordering only — not a percentage. */
  score: number
}

export type StudyGapKind =
  /** Material that exists in the course folder but was never opened. */
  | 'never-opened'
  /** Opened and highlighted, but no note was ever written about it. */
  | 'no-notes'
  /** A deadline is close and its material has had little attention. */
  | 'deadline-untouched'
  /** Nothing recorded in this course for a while. */
  | 'stale-course'

export interface StudyGap {
  kind: StudyGapKind
  /** Course-relative path when the gap is about a file. */
  relPath: string | null
  /** One Korean line the UI can show as-is. */
  message: string
  /** Higher first. Ordering only. */
  weight: number
}
