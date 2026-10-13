import type { TaskKind, TaskStatus, UpdateTaskInput } from '../../../../shared/types/board'
import {
  cancelled,
  has,
  nullableStringField,
  optionalBoolean,
  optionalInteger,
  optionalString,
  stringField,
  type ToolContext,
  type ToolHandlerMap
} from './context'

export function boardTools(ctx: ToolContext) {
  const {
    deps,
    currentTurn,
    reserve,
    release,
    approve,
    record,
    findTask
  } = ctx

  return {
    list_tasks(input) {
      const includeDone = optionalBoolean(input, 'includeDone')
      const courseId = has(input, 'courseId')
        ? nullableStringField(input, 'courseId')
        : undefined
      return deps.boardRepo.list({
        ...(courseId !== undefined ? { courseId } : {}),
        ...(includeDone !== undefined ? { includeDone } : {})
      })
    },

    create_task(input) {
      const context = currentTurn()
      const courseId = nullableStringField(input, 'courseId')
      const title = stringField(input, 'title', { nonEmpty: true })
      const notes = optionalString(input, 'notes')
      const status = optionalString(input, 'status') as TaskStatus | undefined
      const kind = optionalString(input, 'kind') as TaskKind | undefined
      const dueAt = has(input, 'dueAt')
        ? input['dueAt'] === null
          ? null
          : stringField(input, 'dueAt')
        : undefined
      const startAt = has(input, 'startAt') ? nullableStringField(input, 'startAt') : undefined
      const allDay = optionalBoolean(input, 'allDay')

      reserve('tasks', 1)
      let task
      try {
        task = deps.boardRepo.create({
          courseId,
          title,
          ...(notes !== undefined ? { notes } : {}),
          ...(status !== undefined ? { status } : {}),
          ...(kind !== undefined ? { kind } : {}),
          ...(startAt !== undefined ? { startAt } : {}),
          ...(dueAt !== undefined ? { dueAt } : {}),
          ...(allDay !== undefined ? { allDay } : {})
        })
      } catch (error) {
        release('tasks', 1)
        throw error
      }
      record(context, task.courseId ?? context.courseId, 'create_task', 'task', task.id, `할 일 «${task.title}»`, true)
      return task
    },

    update_task(input) {
      const context = currentTurn()
      const id = stringField(input, 'id', { nonEmpty: true })
      const update: UpdateTaskInput = { id }
      if (has(input, 'courseId')) update.courseId = nullableStringField(input, 'courseId')
      if (has(input, 'title')) update.title = stringField(input, 'title')
      if (has(input, 'notes')) update.notes = stringField(input, 'notes')
      if (has(input, 'status')) update.status = stringField(input, 'status') as TaskStatus
      if (has(input, 'kind')) update.kind = stringField(input, 'kind') as TaskKind
      if (has(input, 'startAt')) update.startAt = nullableStringField(input, 'startAt')
      if (has(input, 'dueAt')) {
        update.dueAt = input['dueAt'] === null ? null : stringField(input, 'dueAt')
      }
      if (has(input, 'allDay')) {
        update.allDay = optionalBoolean(input, 'allDay') as boolean
      }
      if (has(input, 'sortOrder')) {
        update.sortOrder = optionalInteger(input, 'sortOrder', 0) as number
      }
      const task = deps.boardRepo.update(update)
      record(context, task.courseId ?? context.courseId, 'update_task', 'task', task.id, `할 일 «${task.title}»`, false)
      return task
    },

    async delete_task(input) {
      const context = currentTurn()
      const id = stringField(input, 'id', { nonEmpty: true })
      const task = findTask(id)
      if (!await approve(
        context,
        'delete_task',
        `할 일 «${task.title}»을(를) 삭제합니다.`,
        [task.title]
      )) return cancelled('delete_task')
      const result = deps.boardRepo.softDelete({ id })
      record(context, task.courseId ?? context.courseId, 'delete_task', 'task', id, `할 일 «${task.title}»`, false)
      return result
    }
  } satisfies Partial<ToolHandlerMap>
}
