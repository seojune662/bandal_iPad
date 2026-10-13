import { randomUUID } from 'node:crypto'
import type { BoardBackground, BoardSurface } from '../../../../shared/types/whiteboard'
import { ValidationError } from '../../../db/errors'
import { resolveInsideReal } from '../../../db/validate'
import { assertAgentBoardShape } from '../shapeValidation'
import {
  cancelled,
  errorText,
  has,
  inputObject,
  optionalInteger,
  optionalString,
  stringArrayField,
  stringField,
  type ToolContext,
  type ToolHandlerMap
} from './context'

interface ShapeRequest {
  id: string
  shape: ReturnType<typeof assertAgentBoardShape>
}

export function canvasTools(ctx: ToolContext) {
  const {
    deps,
    currentTurn,
    reserve,
    approve,
    record,
    courseFolder
  } = ctx

  return {
    list_boards(input) {
      return deps.canvasRepo.listBoards(
        stringField(input, 'courseId', { nonEmpty: true })
      )
    },

    create_board(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const title = optionalString(input, 'title')
      const background = optionalString(input, 'background') as BoardBackground | undefined
      const surface = optionalString(input, 'surface') as BoardSurface | undefined
      if (background !== undefined && !['grid', 'dots', 'lines', 'blank'].includes(background)) {
        throw new ValidationError('background must be one of grid, dots, lines, blank')
      }
      if (surface !== undefined && !['dark', 'light'].includes(surface)) {
        throw new ValidationError('surface must be one of dark, light')
      }
      let board = deps.canvasRepo.createBoard({
        courseId,
        ...(title !== undefined ? { title } : {})
      })
      if (background !== undefined || surface !== undefined) {
        board = deps.canvasRepo.setBackground({
          boardId: board.id,
          ...(background !== undefined ? { background } : {}),
          ...(surface !== undefined ? { surface } : {})
        })
      }
      record(context, board.courseId, 'create_board', 'board', board.id, `화이트보드 «${board.title}»`, true)
      return board
    },

    add_page(input) {
      const context = currentTurn()
      const boardId = stringField(input, 'boardId', { nonEmpty: true })
      const before = deps.canvasRepo.open(boardId).board
      const board = deps.canvasRepo.setPageCount({
        boardId,
        pageCount: before.pageCount + 1
      })
      record(
        context,
        board.courseId,
        'add_page',
        'board',
        board.id,
        `화이트보드 «${board.title}» ${board.pageCount}쪽`,
        false
      )
      return board
    },

    add_shapes(input) {
      const context = currentTurn()
      const boardId = stringField(input, 'boardId', { nonEmpty: true })
      const page = optionalInteger(input, 'page', 1) ?? 1
      const rawShapes = input['shapes']
      if (!Array.isArray(rawShapes) || rawShapes.length === 0) {
        throw new ValidationError('shapes must be a non-empty array')
      }
      const board = deps.canvasRepo.open(boardId).board
      if (page > board.pageCount) {
        throw new ValidationError(`page must be <= board pageCount (${board.pageCount})`)
      }

      const validated: ShapeRequest[] = []
      const ids = new Set<string>()
      const errors: string[] = []
      const folder = courseFolder(board.courseId)
      for (const [index, raw] of rawShapes.entries()) {
        try {
          const shape = assertAgentBoardShape(raw)
          const rawObject = inputObject(raw)
          const id = has(rawObject, 'id')
            ? stringField(rawObject, 'id', { nonEmpty: true })
            : randomUUID()
          if (ids.has(id)) {
            throw new ValidationError(`duplicate shape id "${id}"`)
          }
          ids.add(id)
          const referencedPath = shape.data.clip?.relPath ?? shape.data.image?.relPath
          if (referencedPath !== undefined) resolveInsideReal(folder, referencedPath)
          validated.push({ id, shape })
        } catch (error) {
          errors.push(`shapes[${index}]: ${errorText(error)}`)
        }
      }
      if (errors.length > 0) {
        throw new ValidationError(
          `도형 ${errors.length}개가 잘못되어 아무 도형도 저장하지 않았습니다:\n- ${errors.join('\n- ')}`
        )
      }

      reserve('shapes', validated.length)
      const created = []
      try {
        for (const candidate of validated) {
          created.push(deps.canvasRepo.putShape({
            boardId,
            id: candidate.id,
            page,
            shape: candidate.shape
          }))
        }
      } catch (error) {
        // A repository failure can happen only after validation. Keep the
        // reservation because preceding puts may already have succeeded.
        throw error
      }
      for (const shape of created) {
        record(
          context,
          board.courseId,
          'add_shapes',
          'shape',
          shape.id,
          `화이트보드 도형 «${shape.kind}»`,
          true
        )
      }
      return { boardId, page, count: created.length, shapes: created }
    },

    async rename_board(input) {
      const context = currentTurn()
      const id = stringField(input, 'id', { nonEmpty: true })
      const title = stringField(input, 'title', { nonEmpty: true })
      const before = deps.canvasRepo.open(id).board
      if (!await approve(
        context,
        'rename_board',
        `화이트보드 «${before.title}»의 이름을 «${title.trim()}»(으)로 바꿉니다.`,
        [before.title, title.trim()]
      )) return cancelled('rename_board')
      const board = deps.canvasRepo.renameBoard({ id, title })
      record(context, board.courseId, 'rename_board', 'board', board.id, `화이트보드 «${board.title}»`, false)
      return board
    },

    async delete_board(input) {
      const context = currentTurn()
      const id = stringField(input, 'id', { nonEmpty: true })
      const board = deps.canvasRepo.open(id).board
      if (!await approve(
        context,
        'delete_board',
        `화이트보드 «${board.title}»와 그 안의 도형을 삭제합니다.`,
        [board.title, `페이지 ${board.pageCount}개`]
      )) return cancelled('delete_board')
      deps.canvasRepo.removeBoard(id)
      record(context, board.courseId, 'delete_board', 'board', id, `화이트보드 «${board.title}»`, false)
      return { ok: true }
    },

    async remove_shapes(input) {
      const context = currentTurn()
      const boardId = stringField(input, 'boardId', { nonEmpty: true })
      const ids = [...new Set(stringArrayField(input, 'ids'))]
      const board = deps.canvasRepo.open(boardId).board
      if (!await approve(
        context,
        'remove_shapes',
        `화이트보드 «${board.title}»에서 도형 ${ids.length}개를 삭제합니다.`,
        ids
      )) return cancelled('remove_shapes')
      deps.canvasRepo.removeShapes({ boardId, ids })
      for (const id of ids) {
        record(context, board.courseId, 'remove_shapes', 'shape', `${boardId}\u0000${id}`, `화이트보드 도형 «${id}»`, false)
      }
      return { ok: true as const }
    }
  } satisfies Partial<ToolHandlerMap>
}
