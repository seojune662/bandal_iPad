/**
 * Legacy shared-whiteboard data shapes, retained for saved-data compatibility.
 *
 * Scope decision: "같이 보고 각자 그리기" — a completed stroke is persisted and
 * shows up for everyone within a second or two. There is no per-point op
 * stream and no shared cursor, which is what keeps this buildable:
 *
 *  - The `messages` table cannot carry ink. Its token bucket is capacity 20 /
 *    refill 2 per second (0006_messages.sql), which a single pen stroke would
 *    blow through.
 *  - One row per FINISHED shape instead. A minute of drawing is tens of rows,
 *    not thousands of ops, so it fits comfortably in a normal insert budget
 *    and needs no CRDT.
 *  - Conflict resolution is therefore trivial: shapes are immutable once
 *    written and only ever soft-deleted, so two people drawing at once cannot
 *    produce a conflict — only a union.
 *
 * Ids are generated CLIENT-side (same trick as `messages`): a retry after a
 * dropped response collides on the primary key, which makes the write
 * idempotent without a dedupe table.
 */

import type { DrawingImageSource, DrawingShape } from './drawing'
import type { MaterialFileContent } from './materials'

export interface Whiteboard {
  id: string
  groupId: string
  title: string
  createdBy: string
  createdAt: string
  updatedAt: string
}

export interface WhiteboardShape extends DrawingShape {
  boardId: string
  /** Remote user id of whoever drew it. */
  authorId: string
}

export interface AddWhiteboardShapeInput {
  boardId: string
  /** Client-generated uuid — retrying with the same id is a no-op, not a duplicate. */
  id: string
  shape: Omit<DrawingShape, 'id' | 'createdAt' | 'updatedAt'>
}

/**
 * Edit a shape in place.
 *
 * Without this the UI faked an edit as delete + insert under a NEW id, which
 * broke three things at once: undo entries pointed at ids that no longer
 * existed (and undo then jammed permanently), `createdAt` was re-stamped so an
 * edited shape jumped to the front of the z-order, and one drag cost two
 * round-trips that could half-fail.
 *
 * Immutability is kept where it actually earned its keep: RLS lets you edit
 * only shapes YOU drew, so two people can never contend for the same row and
 * the "union, no CRDT" property still holds for everyone else's work.
 */
export interface UpdateWhiteboardShapeInput {
  boardId: string
  id: string
  shape: Omit<DrawingShape, 'id' | 'createdAt' | 'updatedAt'>
}

export interface RemoveWhiteboardShapesInput {
  boardId: string
  ids: string[]
}

/** One optimized image uploaded to the private storage area of a group board. */
export interface PutWhiteboardAssetInput {
  boardId: string
  assetId: string
  label: string
  mimeType: 'image/webp'
  base64: string
  widthPx: number
  heightPx: number
}

export interface ReadWhiteboardAssetInput {
  boardId: string
  assetId: string
}

export type ReadWhiteboardAssetResult = Extract<
  MaterialFileContent,
  { encoding: 'base64' }
>

export type WhiteboardAssetSource = DrawingImageSource & {
  assetId: string
  storage: 'shared'
  widthPx: number
  heightPx: number
}

/**
 * Why the board can be unusable even when the group is fine: the remote
 * schema for whiteboards ships as its own migration, so a project that has
 * not applied it yet must degrade to a clear message instead of a crash.
 */
export type WhiteboardAvailability =
  | { state: 'ready' }
  | { state: 'signed-out' }
  | { state: 'unconfigured' }
  /** Tables missing — the 0010 migration has not been applied to the project. */
  | { state: 'not-provisioned' }

export interface OpenWhiteboardResult {
  availability: WhiteboardAvailability
  board: Whiteboard | null
  shapes: WhiteboardShape[]
}

// -- personal whiteboards -----------------------------------------------------

/**
 * A board that never leaves the machine. No account, no sync, works offline —
 * the student's own space for organising or sketching a mind map.
 */
/** What the board is ruled with. `blank` is plain paper. */
export type BoardBackground = 'grid' | 'dots' | 'lines' | 'blank'

/** Paper colour. Dark is the original look; light suits printing and export. */
export type BoardSurface = 'dark' | 'light'

export const BOARD_BACKGROUNDS = [
  'grid',
  'dots',
  'lines',
  'blank'
] as const satisfies readonly BoardBackground[]

export const BOARD_SURFACES = [
  'dark',
  'light'
] as const satisfies readonly BoardSurface[]

export interface PersonalBoard {
  id: string
  courseId: string
  title: string
  background: BoardBackground
  surface: BoardSurface
  /** How many pages the board has. At least 1. */
  pageCount: number
  sortOrder: number
  createdAt: string
  /** New-material timestamp; legacy boards deliberately have no value. */
  addedAt?: number
  updatedAt: string
}

/** Personal-board shapes carry the page they live on; group boards are 1-page. */
export interface SetBoardPageCountInput {
  boardId: string
  pageCount: number
}

export interface SetBoardBackgroundInput {
  boardId: string
  background?: BoardBackground
  surface?: BoardSurface
}

export interface CreatePersonalBoardInput {
  courseId: string
  title?: string
}

export interface RenamePersonalBoardInput {
  id: string
  title: string
}

export interface PutPersonalShapeInput {
  boardId: string
  /** Client-generated; re-putting the same id updates in place. */
  id: string
  /** 1-based page. Defaults to 1 so pre-pages callers keep working. */
  page?: number
  shape: Omit<DrawingShape, 'id' | 'createdAt' | 'updatedAt'>
  /**
   * Explicitly bring a soft-deleted shape back. Only undo sets this.
   *
   * Without the flag a plain put silently cleared `deleted_at`, so anything
   * that re-sent a shape after the eraser ran — a late in-flight save, a
   * pending move — quietly resurrected it. The student erased something,
   * reopened the board, and it was back. Deletion is a tombstone now, and
   * un-deleting has to say so.
   */
  restore?: boolean
}

export interface RemovePersonalShapesInput {
  boardId: string
  ids: string[]
}

/** A board shape knows which page it sits on; geometry stays 0..1 in-page. */
export interface PersonalBoardShape extends DrawingShape {
  page: number
}

export interface OpenPersonalBoardResult {
  board: PersonalBoard
  shapes: PersonalBoardShape[]
}
