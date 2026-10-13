import type { CourseLinkKind } from '../../../../shared/types/courseLink'
import { NotFoundError } from '../../../db/errors'
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

export function courseTools(ctx: ToolContext) {
  const { deps, currentTurn, reserve, release, approve, record } = ctx

  return {
    list_courses(input) {
      const includeArchived = optionalBoolean(input, 'includeArchived') ?? false
      // groupName, not just groupId: a bare UUID is worse than nothing —
      // the agent can see something is there and cannot read it, so it guesses.
      const groups = new Map(
        deps.courseGroupsRepo.list().map((group) => [group.id, group.name])
      )
      return deps.coursesRepo.list({ includeArchived }).map((course) => ({
        ...course,
        groupName:
          course.groupId === null ? null : (groups.get(course.groupId) ?? null)
      }))
    },

    list_course_groups() {
      return deps.courseGroupsRepo.list()
    },

    create_course_group(input) {
      return deps.courseGroupsRepo.create({
        name: stringField(input, 'name', { nonEmpty: true })
      })
    },

    async rename_course_group(input) {
      const context = currentTurn()
      const groupId = stringField(input, 'groupId', { nonEmpty: true })
      const name = stringField(input, 'name', { nonEmpty: true })
      const before = deps.courseGroupsRepo
        .list()
        .find((group) => group.id === groupId)
      if (before === undefined) throw new NotFoundError('courseGroup', groupId)
      await approve(context, 'rename_course_group', `학기 이름을 «${name}» 로 바꿉니다.`, [
        `지금 이름: ${before.name}`,
        '안에 든 과목은 그대로 있습니다.'
      ])
      const group = deps.courseGroupsRepo.rename({ groupId, name })
      record(
        context,
        deps.courseId,
        'rename_course_group',
        'course',
        groupId,
        `${before.name} → ${name}`,
        false
      )
      return group
    },

    async delete_course_group(input) {
      const context = currentTurn()
      const groupId = stringField(input, 'groupId', { nonEmpty: true })
      const before = deps.courseGroupsRepo
        .list()
        .find((group) => group.id === groupId)
      if (before === undefined) throw new NotFoundError('courseGroup', groupId)
      await approve(context, 'delete_course_group', `학기 «${before.name}» 를 없앱니다.`, [
        '안에 든 과목은 삭제되지 않고 그룹에서 빠져 나옵니다.'
      ])
      deps.courseGroupsRepo.delete({ groupId })
      record(
        context,
        deps.courseId,
        'delete_course_group',
        'course',
        groupId,
        before.name,
        false
      )
      return { ok: true as const }
    },

    set_course_group(input) {
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const groupId = optionalString(input, 'groupId') ?? null
      const beforeCourseId = optionalString(input, 'beforeCourseId') ?? null
      return deps.coursesRepo.organize({ courseId, groupId, beforeCourseId })
    },

    async archive_course(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const archived = optionalBoolean(input, 'archived') ?? true
      const course = deps.coursesRepo.getById(courseId)
      await approve(
        context,
        'archive_course',
        archived ? `과목 «${course.name}» 을 보관합니다.` : `과목 «${course.name}» 의 보관을 풉니다.`,
        ['자료는 그대로 남고 목록에서만 빠집니다.']
      )
      deps.coursesRepo.archive({ courseId, archived })
      return { ok: true as const }
    },

    create_course(input) {
      const context = currentTurn()
      const name = stringField(input, 'name', { nonEmpty: true }).trim()
      const color = optionalString(input, 'color') ?? 'blue'
      const nameKey = name.normalize('NFC')
      const existing = deps.coursesRepo
        .list({ includeArchived: true })
        .find((course) => course.name.trim().normalize('NFC') === nameKey)
      if (existing !== undefined) {
        return { created: false, duplicate: true, course: existing }
      }

      reserve('courses', 1)
      let course
      try {
        course = deps.coursesRepo.create({ name, color })
      } catch (error) {
        release('courses', 1)
        throw error
      }
      record(context, course.id, 'create_course', 'course', course.id, `과목 «${course.name}»`, true)
      return { created: true, duplicate: false, course }
    },

    async rename_course(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const name = stringField(input, 'name', { nonEmpty: true })
      const before = deps.coursesRepo.getById(courseId)
      if (!await approve(
        context,
        'rename_course',
        `과목 «${before.name}»의 이름을 «${name.trim()}»(으)로 바꿉니다.`,
        [before.name, name.trim()]
      )) return cancelled('rename_course')
      const course = deps.coursesRepo.rename({ courseId, name })
      record(context, course.id, 'rename_course', 'course', course.id, `과목 «${course.name}»`, false)
      return course
    },

    async delete_course(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const course = deps.coursesRepo.getById(courseId)
      if (!await approve(
        context,
        'delete_course',
        `과목 «${course.name}»을(를) 앱에서 삭제합니다. 디스크의 폴더는 남습니다.`,
        [course.name, course.folderPath]
      )) return cancelled('delete_course')
      const result = deps.coursesRepo.softDelete({ courseId })
      record(context, courseId, 'delete_course', 'course', courseId, `과목 «${course.name}»`, false)
      return result
    },

    list_course_links(input) {
      return deps.courseLinksRepo.list({
        courseId: stringField(input, 'courseId', { nonEmpty: true })
      })
    },

    create_course_link(input) {
      const context = currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const link = deps.courseLinksRepo.create({
        courseId,
        label: stringField(input, 'label', { nonEmpty: true }),
        rawUrl: stringField(input, 'rawUrl', { nonEmpty: true }),
        kind: stringField(input, 'kind', { nonEmpty: true }) as CourseLinkKind,
        ...(has(input, 'url') ? { url: stringField(input, 'url', { nonEmpty: true }) } : {}),
        ...(has(input, 'lmsCourseId')
          ? { lmsCourseId: nullableStringField(input, 'lmsCourseId') }
          : {})
      })
      record(context, courseId, 'create_course_link', 'course', link.id, `바로가기 «${link.label}»`, false)
      return link
    },

    update_course_link(input) {
      const context = currentTurn()
      const link = deps.courseLinksRepo.update({
        id: stringField(input, 'id', { nonEmpty: true }),
        ...(has(input, 'label')
          ? { label: stringField(input, 'label', { nonEmpty: true }) }
          : {}),
        ...(has(input, 'sortOrder')
          ? { sortOrder: optionalInteger(input, 'sortOrder', 0) as number }
          : {})
      })
      record(context, link.courseId, 'update_course_link', 'course', link.id, `바로가기 «${link.label}»`, false)
      return link
    },

    async delete_course_link(input) {
      const context = currentTurn()
      const id = stringField(input, 'id', { nonEmpty: true })
      if (!await approve(
        context,
        'delete_course_link',
        `과목 바로가기 «${id}»을(를) 삭제합니다.`,
        [id]
      )) return cancelled('delete_course_link')
      const result = deps.courseLinksRepo.delete({ id })
      record(context, context.courseId, 'delete_course_link', 'course', id, `바로가기 «${id}»`, false)
      return result
    }
  } satisfies Partial<ToolHandlerMap>
}
