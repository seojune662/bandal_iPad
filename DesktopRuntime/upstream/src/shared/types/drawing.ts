/**
 * Free-form PDF markup (pen, highlighter, shapes, text boxes).
 *
 * Deliberately SEPARATE from `types/annotation.ts`: that system anchors to
 * extracted text (quote/prefix/suffix) so it can detect drift when the source
 * PDF changes. Drawings have no text to anchor to — they are pure geometry.
 * Keeping them apart leaves the well-tested highlight path untouched.
 *
 * ALL coordinates are normalized to 0..1 against the *unrotated* page box, so
 * zoom, window resize and DPI changes need no migration. Same convention as
 * `AnnotationRect`.
 */

export type DrawingKind =
  | 'ink'
  | 'highlighter'
  | 'rect'
  | 'ellipse'
  | 'arrow'
  | 'line'
  | 'textbox'
  /**
   * A clipping of course material placed on a board — a PDF page region or a
   * whole page. Stores a REFERENCE (path + page + crop), never pixels: a page
   * crop as base64 would be hundreds of KB per shape, and the remote board
   * caps `data_json` at 64KB. The renderer already has the PDF open, so it
   * re-renders the region at display time.
   */
  | 'clip'
  /**
   * An image the student put on a board or a PDF page. Stores a course-relative
   * PATH, never pixels — the same reasoning as `clip`: the bytes are already on
   * disk, and a base64 copy per shape would blow past the 64KB remote row cap.
   */
  | 'image'

/**
 * Runtime witness for `DrawingKind`, so validators cannot silently fall behind
 * the type. They did: `clip` was added to the union but not to the personal
 * board's hand-copied list, so every clip a student put on a board was
 * rejected on save and vanished when the board was reopened.
 *
 * The assignment below stops compiling if a kind is missing from the list.
 */
export const DRAWING_KINDS = [
  'ink',
  'highlighter',
  'rect',
  'ellipse',
  'arrow',
  'line',
  'textbox',
  'clip',
  'image'
] as const satisfies readonly DrawingKind[]

type MissingDrawingKind = Exclude<DrawingKind, (typeof DRAWING_KINDS)[number]>
const _allDrawingKindsListed: MissingDrawingKind extends never ? true : never =
  true
void _allDrawingKindsListed

/** Named palette entry. Renderer maps these to theme tokens, never to hex. */
export type DrawingColor =
  | 'ink'
  | 'red'
  | 'orange'
  | 'yellow'
  | 'green'
  | 'blue'
  | 'violet'

/** Runtime witness for `DrawingColor` — validators and pickers iterate this. */
export const DRAWING_COLORS = [
  'ink',
  'red',
  'orange',
  'yellow',
  'green',
  'blue',
  'violet'
] as const satisfies readonly DrawingColor[]

type MissingDrawingColor = Exclude<DrawingColor, (typeof DRAWING_COLORS)[number]>
const _allDrawingColorsListed: MissingDrawingColor extends never ? true : never =
  true
void _allDrawingColorsListed

/** textbox only — horizontal alignment of the text inside its box. */
export type TextAlign = 'left' | 'center' | 'right'

export const TEXT_ALIGNS = ['left', 'center', 'right'] as const satisfies readonly TextAlign[]

export interface DrawingPoint {
  x: number
  y: number
  /** Pointer pressure 0..1; 0.5 when the device reports none. */
  p: number
}

export interface DrawingBox {
  x: number
  y: number
  width: number
  height: number
}

/** Kind-specific geometry. `points` for strokes, `box` for shapes/text. */
/** `clip` only — where the pinned material came from. */
export interface DrawingClipSource {
  /** Course-relative path of the source file. */
  relPath: string
  /** 1-based page for PDFs. */
  page: number
  /** Region of that page, normalized 0..1. Omit for the whole page. */
  crop?: DrawingBox
  /**
   * 원본 페이지의 height/width. 첫 배치의 종횡비 추정에 쓴다 — 없으면
   * A4 세로(√2) 가정으로 폴백하던 옛 동작(슬라이드 PDF 왜곡의 원인).
   */
  pageAspect?: number
  /** Shown when the source cannot be rendered (file moved, not shared yet). */
  label: string
}

export interface DrawingData {
  points?: DrawingPoint[]
  box?: DrawingBox
  /** textbox only. */
  text?: string
  /**
   * Textbox-only inline formatting. Ranges use JavaScript string offsets and
   * contain overrides of the box-level style. Missing means the whole string
   * uses `DrawingStyle`, which keeps every pre-v0.37 drawing compatible.
   */
  textRuns?: DrawingTextRun[]
  /** clip only. */
  clip?: DrawingClipSource
  /** image only — course-relative path of the picture to draw in `box`. */
  image?: DrawingImageSource
}

export interface DrawingInlineStyle {
  color?: DrawingColor
  fontSizePt?: number
  bold?: boolean
  italic?: boolean
  underline?: boolean
  strike?: boolean
}

export interface DrawingTextRun {
  from: number
  to: number
  style: DrawingInlineStyle
}

export interface DrawingImageSource {
  relPath: string
  /** Shown while loading and when the file has gone missing. */
  label: string
  /** Shared-board asset id. Absent for course-local material images. */
  assetId?: string
  /** Shared assets live in the private group storage bucket, not a course. */
  storage?: 'shared'
  /** Persisted dimensions avoid a layout jump before the image is decoded. */
  widthPx?: number
  heightPx?: number
}

export interface DrawingStyle {
  color: DrawingColor
  /** Stroke width as a fraction of page width, so it scales with zoom. */
  width: number
  opacity: number
  /** textbox only — multiplier on the base note font size. */
  fontScale?: number
  /** textbox only — physical point size for new/rich text boxes. */
  fontSizePt?: number
  /** textbox only — bold text. */
  bold?: boolean
  /** textbox only — italic text (exported as a synthetic skew). */
  italic?: boolean
  /** textbox only — underline. */
  underline?: boolean
  /** textbox only — strikethrough. */
  strike?: boolean
  /** textbox only — horizontal alignment; absent = left. */
  align?: TextAlign
  /** textbox only — background tint behind the text; absent = transparent. */
  fill?: DrawingColor
}

/**
 * A drawn shape with no idea what surface it sits on.
 *
 * Split out of `Drawing` so the same geometry can back both PDF markup and
 * the shared whiteboard: everything above this line is already surface-free
 * (0..1 normalized), and only `relPath`/`page` were ever PDF-specific.
 */
export interface DrawingShape {
  id: string
  kind: DrawingKind
  data: DrawingData
  style: DrawingStyle
  createdAt: string
  updatedAt: string
}

export interface Drawing extends DrawingShape {
  courseId: string
  relPath: string
  /** 1-based, matching `Annotation.page`. */
  page: number
}

export interface CreateDrawingInput {
  courseId: string
  relPath: string
  page: number
  kind: DrawingKind
  data: DrawingData
  style: DrawingStyle
}

export interface UpdateDrawingInput {
  id: string
  data?: DrawingData
  style?: DrawingStyle
}

export interface ExportAnnotatedPdfInput {
  courseId: string
  relPath: string
}

export interface ExportAnnotatedPdfResult {
  /** Absolute path written, or null when the user cancelled the dialog. */
  savedPath: string | null
}
