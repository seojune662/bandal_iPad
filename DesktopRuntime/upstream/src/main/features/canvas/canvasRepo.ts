import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type {
  DrawingData,
  DrawingKind,
  DrawingStyle
} from '../../../shared/types/drawing'
import { DRAWING_KINDS } from '../../../shared/types/drawing'
import type {
  BoardBackground,
  BoardSurface,
  CreatePersonalBoardInput,
  OpenPersonalBoardResult,
  PersonalBoard,
  PersonalBoardShape,
  PutPersonalShapeInput,
  RemovePersonalShapesInput,
  RenamePersonalBoardInput,
  SetBoardBackgroundInput,
  SetBoardPageCountInput
} from '../../../shared/types/whiteboard'
import {
  BOARD_BACKGROUNDS,
  BOARD_SURFACES
} from '../../../shared/types/whiteboard'
import { NotFoundError, ValidationError } from '../../db/errors'
import { nowIso, requireId, requireInt, requireNonEmptyString } from '../../db/validate'

interface BoardRow {
  id: string
  course_id: string
  title: string
  background: string
  surface: string
  page_count: number
  sort_order: number
  created_at: string
  updated_at: string
  added_at: number | null
}

interface ShapeRow {
  id: string
  board_id: string
  kind: string
  data_json: string
  style_json: string
  page: number
  created_at: string
  updated_at: string
}

export interface CanvasRepo {
  listBoards(courseId: string): PersonalBoard[]
  createBoard(input: CreatePersonalBoardInput): PersonalBoard
  renameBoard(input: RenamePersonalBoardInput): PersonalBoard
  setBackground(input: SetBoardBackgroundInput): PersonalBoard
  setPageCount(input: SetBoardPageCountInput): PersonalBoard
  removeBoard(id: string): void
  open(boardId: string): OpenPersonalBoardResult
  /** Read-only first-page sample with bounded JSON and stroke complexity. */
  hoverPreview(boardId: string): OpenPersonalBoardResult
  /**
   * 살아 있는 도형 개수만 센다 (COUNT(*)). 도시에처럼 개수만 필요한 곳이
   * `open()` 으로 도형 전체를 로드하지 않게 하는 값싼 경로다.
   */
  countShapes(boardId: string): number
  putShape(input: PutPersonalShapeInput): PersonalBoardShape
  removeShapes(input: RemovePersonalShapesInput): void
}

export const BOARD_HOVER_SHAPE_LIMIT = 160
export const BOARD_HOVER_SHAPE_BYTES = 32 * 1024
export const BOARD_HOVER_TOTAL_BYTES = 256 * 1024
export const BOARD_HOVER_POINTS_PER_SHAPE = 512
export const BOARD_HOVER_TOTAL_POINTS = 4096

function boundedPreviewShape(row: ShapeRow, pointBudget: number): PersonalBoardShape | null {
  try {
    const shape = rowToShape(row)
    if (!DRAWING_KINDS.includes(shape.kind) || !shape.data || Array.isArray(shape.data) ||
        !shape.style || Array.isArray(shape.style) || typeof shape.data !== 'object' || typeof shape.style !== 'object') return null
    if (shape.data.points !== undefined) {
      if (!Array.isArray(shape.data.points) || pointBudget < 2) return null
      const points = shape.data.points.filter(point => point && typeof point === 'object' &&
        Number.isFinite(point.x) && Number.isFinite(point.y) && Number.isFinite(point.p))
      const count = Math.min(points.length, pointBudget, BOARD_HOVER_POINTS_PER_SHAPE)
      shape.data.points = points.length <= count ? points : Array.from({ length: count }, (_, index) =>
        points[Math.round(index * (points.length - 1) / (count - 1))]!)
    }
    return shape
  } catch {
    // A damaged shape should not make an otherwise readable board unusable.
    return null
  }
}


function boardBackground(value: unknown): BoardBackground {
  const background = BOARD_BACKGROUNDS.find((candidate) => candidate === value)
  if (background === undefined) {
    throw new ValidationError(
      `background must be one of ${BOARD_BACKGROUNDS.join(', ')}`
    )
  }
  return background
}

function boardSurface(value: unknown): BoardSurface {
  const surface = BOARD_SURFACES.find((candidate) => candidate === value)
  if (surface === undefined) {
    throw new ValidationError(`surface must be one of ${BOARD_SURFACES.join(', ')}`)
  }
  return surface
}

function rowToBoard(row: BoardRow): PersonalBoard {
  return {
    id: row.id,
    courseId: row.course_id,
    title: row.title,
    background: boardBackground(row.background),
    surface: boardSurface(row.surface),
    pageCount: row.page_count,
    sortOrder: row.sort_order,
    createdAt: row.created_at,
    ...(row.added_at === null || row.added_at === undefined ? {} : { addedAt: row.added_at }),
    updatedAt: row.updated_at
  }
}

function rowToShape(row: ShapeRow): PersonalBoardShape {
  return {
    id: row.id,
    kind: row.kind as DrawingKind,
    data: JSON.parse(row.data_json) as DrawingData,
    style: JSON.parse(row.style_json) as DrawingStyle,
    page: row.page,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  }
}

function cleanTitle(value: unknown): string {
  return requireNonEmptyString(value, 'title').trim()
}

function assertShapeInput(
  input: PutPersonalShapeInput['shape']
): PutPersonalShapeInput['shape'] {
  if (typeof input !== 'object' || input === null) {
    throw new ValidationError('shape must be an object')
  }
  if (!DRAWING_KINDS.includes(input.kind)) {
    throw new ValidationError(`shape.kind must be one of ${DRAWING_KINDS.join(', ')}`)
  }
  if (typeof input.data !== 'object' || input.data === null || Array.isArray(input.data)) {
    throw new ValidationError('shape.data must be an object')
  }
  if (typeof input.style !== 'object' || input.style === null || Array.isArray(input.style)) {
    throw new ValidationError('shape.style must be an object')
  }
  return input
}

export function createCanvasRepo(db: Database): CanvasRepo {
  function assertCourseExists(courseId: string): void {
    const row = db
      .prepare('SELECT id FROM courses WHERE id = ? AND deleted_at IS NULL')
      .get(courseId)
    if (row === undefined) throw new NotFoundError('course', courseId)
  }

  function boardRowOrThrow(boardId: string): BoardRow {
    const row = db
      .prepare('SELECT * FROM whiteboards WHERE id = ? AND deleted_at IS NULL')
      .get(boardId) as BoardRow | undefined
    if (row === undefined) throw new NotFoundError('whiteboard', boardId)
    assertCourseExists(row.course_id)
    return row
  }

  const createBoardTransaction = db.transaction(
    (courseId: string, requestedTitle: string | undefined): PersonalBoard => {
      assertCourseExists(courseId)
      const orderRow = db
        .prepare(
          `SELECT COALESCE(MAX(sort_order), -1) AS max_order
             FROM whiteboards
            WHERE course_id = ? AND deleted_at IS NULL`
        )
        .get(courseId) as { max_order: number }
      const sortOrder = orderRow.max_order + 1
      const title = requestedTitle === undefined
        ? `화이트보드 ${sortOrder + 1}`
        : cleanTitle(requestedTitle)
      const now = nowIso()
      const board: PersonalBoard = {
        id: randomUUID(),
        courseId,
        title,
        background: 'grid',
        surface: 'dark',
        pageCount: 1,
        sortOrder,
        createdAt: now,
        addedAt: Date.parse(now),
        updatedAt: now
      }
      db.prepare(
        `INSERT INTO whiteboards
           (id, course_id, title, sort_order, created_at, updated_at, added_at, deleted_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`
      ).run(
        board.id,
        board.courseId,
        board.title,
        board.sortOrder,
        board.createdAt,
        board.updatedAt,
        board.addedAt
      )
      return board
    }
  )

  const removeBoardTransaction = db.transaction((boardId: string): void => {
    boardRowOrThrow(boardId)
    const now = nowIso()
    db.prepare(
      `UPDATE whiteboards
          SET deleted_at = ?, updated_at = ?
        WHERE id = ?`
    ).run(now, now, boardId)
    db.prepare(
      `UPDATE whiteboard_local_shapes
          SET deleted_at = ?, updated_at = ?
        WHERE board_id = ? AND deleted_at IS NULL`
    ).run(now, now, boardId)
  })

  return {
    listBoards(courseIdInput) {
      const courseId = requireId(courseIdInput, 'courseId')
      assertCourseExists(courseId)
      const rows = db
        .prepare(
          `SELECT * FROM whiteboards
            WHERE course_id = ? AND deleted_at IS NULL
            ORDER BY sort_order ASC, created_at ASC`
        )
        .all(courseId) as BoardRow[]
      return rows.map(rowToBoard)
    },

    createBoard(input) {
      const courseId = requireId(input.courseId, 'courseId')
      return createBoardTransaction(courseId, input.title)
    },

    renameBoard(input) {
      const id = requireId(input.id, 'id')
      const row = boardRowOrThrow(id)
      const title = cleanTitle(input.title)
      const updatedAt = nowIso()
      db.prepare(
        'UPDATE whiteboards SET title = ?, updated_at = ? WHERE id = ?'
      ).run(title, updatedAt, id)
      return rowToBoard({
        ...row,
        title,
        updated_at: updatedAt
      })
    },

    setBackground(input) {
      const boardId = requireId(input.boardId, 'boardId')
      const row = boardRowOrThrow(boardId)
      const background = input.background === undefined
        ? boardBackground(row.background)
        : boardBackground(input.background)
      const surface = input.surface === undefined
        ? boardSurface(row.surface)
        : boardSurface(input.surface)
      if (background === row.background && surface === row.surface) {
        return rowToBoard(row)
      }
      const updatedAt = nowIso()
      db.prepare(
        `UPDATE whiteboards
            SET background = ?, surface = ?, updated_at = ?
          WHERE id = ?`
      ).run(background, surface, updatedAt, boardId)
      return rowToBoard({
        ...row,
        background,
        surface,
        updated_at: updatedAt
      })
    },

    setPageCount(input) {
      const boardId = requireId(input.boardId, 'boardId')
      const row = boardRowOrThrow(boardId)
      const pageCount = requireInt(input.pageCount, 'pageCount', 1)
      if (pageCount === row.page_count) return rowToBoard(row)
      if (pageCount < row.page_count) {
        const truncatedShape = db
          .prepare(
            `SELECT id FROM whiteboard_local_shapes
              WHERE board_id = ? AND page > ? AND deleted_at IS NULL
              LIMIT 1`
          )
          .get(boardId, pageCount)
        if (truncatedShape !== undefined) {
          throw new ValidationError('cannot remove a page that contains shapes')
        }
      }
      const updatedAt = nowIso()
      db.prepare(
        'UPDATE whiteboards SET page_count = ?, updated_at = ? WHERE id = ?'
      ).run(pageCount, updatedAt, boardId)
      return rowToBoard({
        ...row,
        page_count: pageCount,
        updated_at: updatedAt
      })
    },

    removeBoard(idInput) {
      removeBoardTransaction(requireId(idInput, 'id'))
    },

    open(boardIdInput) {
      const boardId = requireId(boardIdInput, 'boardId')
      const board = rowToBoard(boardRowOrThrow(boardId))
      const rows = db
        .prepare(
          `SELECT * FROM whiteboard_local_shapes
            WHERE board_id = ? AND deleted_at IS NULL
            ORDER BY created_at ASC, id ASC`
        )
        .all(boardId) as ShapeRow[]
      return { board, shapes: rows.map(rowToShape) }
    },

    hoverPreview(boardIdInput) {
      const boardId = requireId(boardIdInput, 'boardId')
      const board = rowToBoard(boardRowOrThrow(boardId))
      // The page index bounds the scan before JSON is selected. Inspect only
      // sizes for at most 160 candidates, so a huge shape never crosses into JS.
      const candidates = db.prepare(`SELECT id,
        length(CAST(data_json AS BLOB)) + length(CAST(style_json AS BLOB)) AS bytes
        FROM whiteboard_local_shapes
        WHERE board_id = ? AND page = 1 AND deleted_at IS NULL
        ORDER BY created_at DESC, id DESC LIMIT ?`)
        .all(boardId, BOARD_HOVER_SHAPE_LIMIT) as { id: string; bytes: number }[]
      const read = db.prepare('SELECT * FROM whiteboard_local_shapes WHERE id = ? AND board_id = ? AND page = 1 AND deleted_at IS NULL')
      const shapes: PersonalBoardShape[] = []
      let readBytes = 0
      let payloadBytes = Buffer.byteLength(JSON.stringify({ board, shapes: [] }))
      let points = 0
      for (const candidate of candidates) {
        if (candidate.bytes > BOARD_HOVER_SHAPE_BYTES || readBytes + candidate.bytes > BOARD_HOVER_TOTAL_BYTES) continue
        const row = read.get(candidate.id, boardId) as ShapeRow | undefined
        if (!row) continue
        readBytes += candidate.bytes
        const shape = boundedPreviewShape(row, BOARD_HOVER_TOTAL_POINTS - points)
        if (!shape) continue
        let bytes: number
        try { bytes = Buffer.byteLength(JSON.stringify(shape)) + 1 } catch { continue }
        if (payloadBytes + bytes > BOARD_HOVER_TOTAL_BYTES) continue
        payloadBytes += bytes
        points += shape.data.points?.length ?? 0
        shapes.push(shape)
      }
      // Candidates favor recent marks; preserve normal paint order in the SVG.
      return { board, shapes: shapes.reverse() }
    },

    countShapes(boardIdInput) {
      const boardId = requireId(boardIdInput, 'boardId')
      // 보드 존재 검증을 생략한 값싼 경로: 없는 보드는 0으로 답한다.
      // 호출부(도시에)는 listBoards 로 얻은 살아 있는 보드만 넘긴다.
      const row = db
        .prepare(
          `SELECT COUNT(*) AS shape_count FROM whiteboard_local_shapes
            WHERE board_id = ? AND deleted_at IS NULL`
        )
        .get(boardId) as { shape_count: number }
      return row.shape_count
    },

    putShape(input) {
      const boardId = requireId(input.boardId, 'boardId')
      const board = boardRowOrThrow(boardId)
      const id = requireId(input.id, 'id')
      const page = requireInt(input.page ?? 1, 'page', 1)
      if (page > board.page_count) {
        throw new ValidationError(`page must be <= board pageCount (${board.page_count})`)
      }
      const shape = assertShapeInput(input.shape)
      const existing = db
        .prepare('SELECT * FROM whiteboard_local_shapes WHERE id = ?')
        .get(id) as ShapeRow | undefined
      if (existing !== undefined && existing.board_id !== boardId) {
        throw new NotFoundError('whiteboard shape', id)
      }

      const now = nowIso()
      const createdAt = existing?.created_at ?? now
      db.prepare(
        `INSERT INTO whiteboard_local_shapes
           (id, board_id, kind, data_json, style_json, page, created_at, updated_at, deleted_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
         ON CONFLICT(id) DO UPDATE SET
           kind = excluded.kind,
           data_json = excluded.data_json,
           style_json = excluded.style_json,
           page = excluded.page,
           updated_at = excluded.updated_at,
           -- A tombstone outranks a plain put. Only an explicit restore
           -- (undo) revives a shape the eraser removed; a stale in-flight
           -- save must never bring it back.
           deleted_at = CASE WHEN ? THEN NULL ELSE whiteboard_local_shapes.deleted_at END`
      ).run(
        id,
        boardId,
        shape.kind,
        JSON.stringify(shape.data),
        JSON.stringify(shape.style),
        page,
        createdAt,
        now,
        input.restore === true ? 1 : 0
      )
      return {
        id,
        ...shape,
        page,
        createdAt,
        updatedAt: now
      }
    },

    removeShapes(input) {
      const boardId = requireId(input.boardId, 'boardId')
      boardRowOrThrow(boardId)
      if (!Array.isArray(input.ids)) {
        throw new ValidationError('ids must be an array')
      }
      const ids = [...new Set(input.ids.map((id) => requireId(id, 'id')))]
      if (ids.length === 0) return
      const now = nowIso()
      const remove = db.transaction((shapeIds: readonly string[]): void => {
        const statement = db.prepare(
          `UPDATE whiteboard_local_shapes
              SET deleted_at = ?, updated_at = ?
            WHERE board_id = ? AND id = ? AND deleted_at IS NULL`
        )
        for (const id of shapeIds) statement.run(now, now, boardId, id)
      })
      remove(ids)
    }
  }
}
