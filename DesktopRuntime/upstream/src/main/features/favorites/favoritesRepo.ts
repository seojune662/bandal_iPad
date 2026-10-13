/**
 * Favorites repository. A favorite stores the complete TabDescriptor needed
 * to reopen a tab, rather than a feature-specific identifier or URL.
 */

import { randomUUID } from 'node:crypto'
import type { Database } from 'better-sqlite3'
import type {
  CreateFavoriteInput,
  Favorite,
  RenameFavoriteInput,
  ReorderFavoritesInput
} from '../../../shared/types/favorite'
import { NotFoundError, ValidationError } from '../../db/errors'
import { nowIso, requireId, requireNonEmptyString } from '../../db/validate'
import { parseDescriptor, serializeDescriptor } from './descriptorJson'

export interface FavoritesRepo {
  list(courseId: string | null): Favorite[]
  add(input: CreateFavoriteInput): Favorite
  rename(input: RenameFavoriteInput): Favorite
  softDelete(id: string): void
  reorder(input: ReorderFavoritesInput): void
}

interface FavoriteRow {
  id: string
  course_id: string | null
  label: string
  descriptor_json: string
  sort_order: number
  created_at: string
  updated_at: string
}

function requireCourseId(value: unknown): string | null {
  return value === null ? null : requireId(value, 'courseId')
}

function requireLabel(value: unknown): string {
  return requireNonEmptyString(value, 'label').trim()
}

/** Corrupt legacy/manual rows are ignored by list instead of breaking the rail. */
function rowToFavorite(row: FavoriteRow): Favorite | null {
  try {
    const descriptor = parseDescriptor(row.descriptor_json)
    return {
      id: row.id,
      courseId: row.course_id,
      label: row.label,
      descriptor,
      sortOrder: row.sort_order,
      createdAt: row.created_at,
      updatedAt: row.updated_at
    }
  } catch {
    return null
  }
}

export function createFavoritesRepo(db: Database): FavoritesRepo {
  function assertCourseExists(courseId: string): void {
    const row = db
      .prepare('SELECT id FROM courses WHERE id = ? AND deleted_at IS NULL')
      .get(courseId)
    if (row === undefined) throw new NotFoundError('course', courseId)
  }

  function getRowOrThrow(id: string): FavoriteRow {
    const row = db
      .prepare('SELECT * FROM favorites WHERE id = ? AND deleted_at IS NULL')
      .get(id) as FavoriteRow | undefined
    if (row === undefined) throw new NotFoundError('favorite', id)
    return row
  }

  function nextSortOrder(courseId: string | null): number {
    const row = (courseId === null
      ? db
          .prepare(
            `SELECT COALESCE(MAX(sort_order), -1) AS max_order
             FROM favorites WHERE course_id IS NULL AND deleted_at IS NULL`
          )
          .get()
      : db
          .prepare(
            `SELECT COALESCE(MAX(sort_order), -1) AS max_order
             FROM favorites WHERE course_id = ? AND deleted_at IS NULL`
          )
          .get(courseId)) as { max_order: number }
    return row.max_order + 1
  }

  const reorderTransaction = db.transaction(
    (courseId: string | null, ids: string[]): void => {
      const rows = (courseId === null
        ? db
            .prepare(
              `SELECT * FROM favorites
               WHERE course_id IS NULL AND deleted_at IS NULL`
            )
            .all()
        : db
            .prepare(
              `SELECT * FROM favorites
               WHERE course_id = ? AND deleted_at IS NULL`
            )
            .all(courseId)) as FavoriteRow[]

      // The ordering contract covers the same healthy rows returned by list;
      // a corrupt descriptor that list skips must not make reordering unusable.
      const existing = new Set(
        rows.filter((row) => rowToFavorite(row) !== null).map((row) => row.id)
      )
      if (existing.size !== ids.length || ids.some((id) => !existing.has(id))) {
        throw new ValidationError(
          'ids must contain every active favorite in the requested course exactly once'
        )
      }

      const now = nowIso()
      const update =
        courseId === null
          ? db.prepare(
              `UPDATE favorites SET sort_order = ?, updated_at = ?
               WHERE id = ? AND course_id IS NULL AND deleted_at IS NULL`
            )
          : db.prepare(
              `UPDATE favorites SET sort_order = ?, updated_at = ?
               WHERE id = ? AND course_id = ? AND deleted_at IS NULL`
            )

      ids.forEach((id, index) => {
        const result =
          courseId === null
            ? update.run(index, now, id)
            : update.run(index, now, id, courseId)
        if (result.changes !== 1) {
          throw new NotFoundError('favorite', id)
        }
      })
    }
  )

  return {
    list(rawCourseId) {
      const courseId = requireCourseId(rawCourseId)
      const rows = (courseId === null
        ? db
            .prepare(
              `SELECT * FROM favorites
               WHERE course_id IS NULL AND deleted_at IS NULL
               ORDER BY sort_order ASC, created_at ASC`
            )
            .all()
        : db
            .prepare(
              `SELECT * FROM favorites
               WHERE course_id = ? AND deleted_at IS NULL
               ORDER BY sort_order ASC, created_at ASC`
            )
            .all(courseId)) as FavoriteRow[]

      return rows
        .map(rowToFavorite)
        .filter((favorite): favorite is Favorite => favorite !== null)
    },

    add(input) {
      const courseId = requireCourseId(input.courseId)
      if (courseId !== null) assertCourseExists(courseId)
      const label = requireLabel(input.label)
      const serialized = serializeDescriptor(input.descriptor)
      const now = nowIso()
      const favorite: Favorite = {
        id: randomUUID(),
        courseId,
        label,
        descriptor: serialized.descriptor,
        sortOrder: nextSortOrder(courseId),
        createdAt: now,
        updatedAt: now
      }

      db.prepare(
        `INSERT INTO favorites
           (id, course_id, label, descriptor_json, sort_order, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      ).run(
        favorite.id,
        favorite.courseId,
        favorite.label,
        serialized.json,
        favorite.sortOrder,
        now,
        now
      )
      return favorite
    },

    rename(input) {
      const row = getRowOrThrow(requireId(input.id, 'id'))
      const label = requireLabel(input.label)
      const favorite = rowToFavorite(row)
      if (favorite === null) {
        throw new ValidationError(`favorite "${row.id}" has a corrupt descriptor`)
      }
      const now = nowIso()
      db.prepare('UPDATE favorites SET label = ?, updated_at = ? WHERE id = ?').run(
        label,
        now,
        row.id
      )
      return { ...favorite, label, updatedAt: now }
    },

    softDelete(rawId) {
      const row = getRowOrThrow(requireId(rawId, 'id'))
      const now = nowIso()
      db.prepare(
        'UPDATE favorites SET deleted_at = ?, updated_at = ? WHERE id = ?'
      ).run(now, now, row.id)
    },

    reorder(input) {
      const courseId = requireCourseId(input.courseId)
      if (!Array.isArray(input.ids)) {
        throw new ValidationError('ids must be an array')
      }
      const ids = input.ids.map((id) => requireId(id, 'id'))
      if (new Set(ids).size !== ids.length) {
        throw new ValidationError('ids must not contain duplicates')
      }
      reorderTransaction(courseId, ids)
    }
  }
}
