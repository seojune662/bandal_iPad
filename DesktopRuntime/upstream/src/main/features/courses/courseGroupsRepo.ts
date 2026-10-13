/**
 * 과목 그룹(학기) repository. A group is a named sidebar section; membership
 * lives on `courses.group_id` (see coursesRepo.organize), so this repo only
 * manages the group rows themselves. Deleting a group un-groups its member
 * courses — it NEVER deletes a course.
 *
 * `courseGroups:` manages local sidebar sections.
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type { CourseGroup } from '../../../shared/types/course'
import { NotFoundError } from '../../db/errors'
import { nowIso, requireId, requireNonEmptyString } from '../../db/validate'

export interface CourseGroupsRepo {
  /** Live groups, sidebar order. */
  list(): CourseGroup[]
  create(input: { name: string }): CourseGroup
  rename(input: { groupId: string; name: string }): CourseGroup
  /** Soft-deletes the group and NULLs member courses' group_id, atomically. */
  delete(input: { groupId: string }): { ok: true }
}

interface CourseGroupRow {
  id: string
  name: string
  sort_order: number
  created_at: string
  updated_at: string
}

function rowToGroup(row: CourseGroupRow): CourseGroup {
  return {
    id: row.id,
    name: row.name,
    sortOrder: row.sort_order,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  }
}

export function createCourseGroupsRepo(db: Database): CourseGroupsRepo {
  function getRowOrThrow(groupId: string): CourseGroupRow {
    const id = requireId(groupId, 'groupId')
    const row = db
      .prepare('SELECT * FROM course_groups WHERE id = ? AND deleted_at IS NULL')
      .get(id) as CourseGroupRow | undefined
    if (row === undefined) {
      throw new NotFoundError('course group', id)
    }
    return row
  }

  function nextSortOrder(): number {
    const row = db
      .prepare(
        `SELECT COALESCE(MAX(sort_order), -1) AS max_order
         FROM course_groups WHERE deleted_at IS NULL`
      )
      .get() as { max_order: number }
    return row.max_order + 1
  }

  const deleteTransaction = db.transaction((groupId: string): void => {
    const now = nowIso()
    // 멤버 과목은 그룹만 잃는다 — 과목 자체는 절대 지우지 않는다.
    db.prepare(
      'UPDATE courses SET group_id = NULL, updated_at = ? WHERE group_id = ?'
    ).run(now, groupId)
    db.prepare(
      'UPDATE course_groups SET deleted_at = ?, updated_at = ? WHERE id = ?'
    ).run(now, now, groupId)
  })

  return {
    list() {
      const rows = db
        .prepare(
          `SELECT * FROM course_groups
           WHERE deleted_at IS NULL
           ORDER BY sort_order ASC, created_at ASC`
        )
        .all() as CourseGroupRow[]
      return rows.map(rowToGroup)
    },

    create(input) {
      const name = requireNonEmptyString(input.name, 'name').trim()
      const now = nowIso()
      const group: CourseGroup = {
        id: randomUUID(),
        name,
        sortOrder: nextSortOrder(),
        createdAt: now,
        updatedAt: now
      }
      db.prepare(
        `INSERT INTO course_groups (id, name, sort_order, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?)`
      ).run(group.id, group.name, group.sortOrder, now, now)
      return group
    },

    rename(input) {
      const row = getRowOrThrow(input.groupId)
      const name = requireNonEmptyString(input.name, 'name').trim()
      const now = nowIso()
      db.prepare(
        'UPDATE course_groups SET name = ?, updated_at = ? WHERE id = ?'
      ).run(name, now, row.id)
      return rowToGroup({ ...row, name, updated_at: now })
    },

    delete(input) {
      const row = getRowOrThrow(input.groupId)
      deleteTransaction(row.id)
      return { ok: true }
    }
  }
}
