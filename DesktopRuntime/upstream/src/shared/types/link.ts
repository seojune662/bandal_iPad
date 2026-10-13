import type { TabDescriptor } from '../tabs'
import type { PdfPageSize } from '../pdfPageNote'

/**
 * Deep links between a note and the material it is about.
 *
 * Written into markdown as an ordinary link, so the file stays a plain `.md`
 * that opens correctly in any other editor — the target just does not resolve
 * outside Bandal. Storing a proprietary block instead would make the student's
 * notes unreadable elsewhere, which defeats the point of keeping them as files.
 *
 *   [3쪽 “해시 충돌…”](bandal://material?path=Chap1.pdf&page=3)
 */
export const BANDAL_LINK_SCHEME = 'bandal:'

/** A persisted relationship between any two tabs in one course. */
export interface MaterialLinkRecord {
  id: string
  courseId: string
  source: TabDescriptor
  target: TabDescriptor
  kind: MaterialLinkKind
  label: string
  metadata: PdfPageNoteLinkMetadata | null
  createdAt: string
}

export type MaterialLinkKind = 'related' | 'sequence' | 'pdf-page-note'

export interface PdfPageNoteLinkMetadata {
  version: 1
  syncScroll: boolean
  fingerprint: string
  pageSizes: PdfPageSize[]
}

export function isPdfPageNoteLinkMetadata(
  value: unknown
): value is PdfPageNoteLinkMetadata {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return (
    candidate['version'] === 1 &&
    typeof candidate['syncScroll'] === 'boolean' &&
    typeof candidate['fingerprint'] === 'string' &&
    Array.isArray(candidate['pageSizes']) &&
    candidate['pageSizes'].length > 0 &&
    candidate['pageSizes'].every((entry) => {
      if (typeof entry !== 'object' || entry === null) return false
      const size = entry as Record<string, unknown>
      return (
        typeof size['width'] === 'number' &&
        Number.isFinite(size['width']) &&
        size['width'] > 0 &&
        typeof size['height'] === 'number' &&
        Number.isFinite(size['height']) &&
        size['height'] > 0
      )
    })
  )
}

export interface MaterialLink {
  /** Course-relative path. */
  relPath: string
  /** 1-based page for PDFs; null for whole-file links. */
  page: number | null
  /** Annotation to flash on arrival, when the link came from a highlight. */
  annotationId?: string
}

export interface SendHighlightToNoteInput {
  courseId: string
  /** Source material. */
  relPath: string
  page: number
  quote: string
  comment: string | null
  annotationId: string
  /**
   * Target note. Omit to append to the course's default study note, which is
   * created on first use.
   */
  noteRelPath?: string
}

/**
 * A quote clipped from a web page in the embedded browser.
 *
 * Deliberately a sibling of `SendHighlightToNoteInput` rather than a widening
 * of it: that one's `relPath`/`page`/`annotationId` are required and carry the
 * backlink index. A web clip has no material behind it, so the source line is
 * an ordinary markdown link and the note stays readable in any editor.
 */
export interface SendWebClipToNoteInput {
  courseId: string
  /** Page the quote came from. */
  url: string
  /** Page title; falls back to the host when a page has none. */
  title: string
  quote: string
  comment: string | null
  /** Omit to append to the course's default study note. */
  noteRelPath?: string
}

export interface SendHighlightToNoteResult {
  /** Note that was written to. */
  relPath: string
  created: boolean
}

/**
 * One place that points at a material — the reverse of `MaterialLink`.
 *
 * The forward direction (note → PDF page) has always worked: the markdown
 * holds a `bandal://material?…` href you can click. The reverse — "which of
 * my notes quote this page?" — had no representation at all, because those
 * hrefs live in file text rather than in a table.
 */
export interface MaterialBacklink {
  /** Note: course-relative path. Whiteboard: board id. */
  ref: string
  /** What to show: note filename or board title. */
  label: string
  /** Page of the target material, when the citation named one. */
  page: number | null
}

export interface MaterialBacklinks {
  notes: MaterialBacklink[]
  boards: MaterialBacklink[]
}

/** A backlink with the payload retained by the derived cache. */
export interface DetailedMaterialBacklink extends MaterialBacklink {
  /** Annotation id for a note, clip label for a whiteboard, or an empty string. */
  detail: string
  /** How the note referenced the target; absent means `bandal://` (material). */
  linkKind?: 'material' | 'wikilink'
}

/** All sources for one material, grouped for dossier/insights/graph consumers. */
export interface MaterialBacklinkGroup {
  /** Actual course-relative filesystem spelling, not its normalized match key. */
  relPath: string
  notes: DetailedMaterialBacklink[]
  boards: DetailedMaterialBacklink[]
}
