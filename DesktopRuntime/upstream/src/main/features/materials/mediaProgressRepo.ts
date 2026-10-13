/**
 * [M18] 영상 이어보기 저장소. Derived view state keyed by (course, file) —
 * one upsert per save, no soft delete (losing a row only loses a resume
 * point, never user content).
 */

import type { Database } from 'better-sqlite3'
import type { MediaProgress } from '../../../shared/types/mediaProgress'
import { nowIso, requireId, requireNonEmptyString } from '../../db/validate'

interface MediaProgressRow {
  course_id: string
  rel_path: string
  position_sec: number
  duration_sec: number | null
  playback_rate: number
  updated_at: string
}

export interface MediaProgressRepo {
  get(courseId: string, relPath: string): MediaProgress | null
  set(input: {
    courseId: string
    relPath: string
    positionSec: number
    durationSec: number | null
    playbackRate: number
  }): MediaProgress
}

function toProgress(row: MediaProgressRow): MediaProgress {
  return {
    courseId: row.course_id,
    relPath: row.rel_path,
    positionSec: row.position_sec,
    durationSec: row.duration_sec,
    playbackRate: row.playback_rate,
    updatedAt: row.updated_at
  }
}

function finiteOrThrow(value: number, label: string): number {
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${label} must be a non-negative finite number`)
  }
  return value
}

export function createMediaProgressRepo(db: Database): MediaProgressRepo {
  const selectOne = db.prepare(
    `SELECT course_id, rel_path, position_sec, duration_sec, playback_rate, updated_at
       FROM media_progress WHERE course_id = ? AND rel_path = ?`
  )
  const upsert = db.prepare(
    `INSERT INTO media_progress
       (course_id, rel_path, position_sec, duration_sec, playback_rate, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT (course_id, rel_path) DO UPDATE SET
       position_sec = excluded.position_sec,
       duration_sec = excluded.duration_sec,
       playback_rate = excluded.playback_rate,
       updated_at = excluded.updated_at`
  )

  return {
    get(courseId, relPath) {
      requireId(courseId, 'courseId')
      requireNonEmptyString(relPath, 'relPath')
      const row = selectOne.get(courseId, relPath) as MediaProgressRow | undefined
      return row === undefined ? null : toProgress(row)
    },

    set(input) {
      requireId(input.courseId, 'courseId')
      requireNonEmptyString(input.relPath, 'relPath')
      const positionSec = finiteOrThrow(input.positionSec, 'positionSec')
      const playbackRate = finiteOrThrow(input.playbackRate, 'playbackRate')
      const durationSec =
        input.durationSec === null ? null : finiteOrThrow(input.durationSec, 'durationSec')
      const updatedAt = nowIso()
      upsert.run(
        input.courseId,
        input.relPath,
        positionSec,
        durationSec,
        playbackRate,
        updatedAt
      )
      return {
        courseId: input.courseId,
        relPath: input.relPath,
        positionSec,
        durationSec,
        playbackRate,
        updatedAt
      }
    }
  }
}
