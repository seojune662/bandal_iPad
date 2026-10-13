/**
 * PDF annotation types. Annotations anchor to a page of a material file
 * (identified by courseId + relPath) with geometric rects plus a robust
 * text anchor for re-attachment after document changes.
 */

export type HighlightColor = 'yellow' | 'green' | 'pink' | 'blue'

/** Normalized rectangle in PDF page space (0..1 relative coordinates). */
export interface AnnotationRect {
  x: number
  y: number
  width: number
  height: number
}

/** Text-based anchor used to re-locate an annotation. */
export interface AnnotationAnchor {
  /** Exact text that was highlighted. */
  quote: string
  /** Some characters preceding the quote. */
  prefix: string
  /** Some characters following the quote. */
  suffix: string
}

export interface Annotation {
  id: string
  courseId: string
  relPath: string
  /** 1-based page number. */
  page: number
  color: HighlightColor
  rects: AnnotationRect[]
  anchor: AnnotationAnchor
  /** Optional user comment attached to the highlight. */
  comment: string | null
  createdAt: string
  updatedAt: string
}

export interface CreateAnnotationInput {
  courseId: string
  relPath: string
  page: number
  color: HighlightColor
  rects: AnnotationRect[]
  anchor: AnnotationAnchor
  comment?: string | null
}

export interface UpdateAnnotationInput {
  id: string
  color?: HighlightColor
  comment?: string | null
}
