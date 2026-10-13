import { posix } from 'node:path'
import type { Database } from 'better-sqlite3'
import type { MaterialKind } from '../../../shared/types/materials'
import type { StudyGap, StudyGapKind } from '../../../shared/types/search'
import { requireId } from '../../db/validate'

const DAY_MS = 24 * 60 * 60 * 1000

export const INSIGHTS_THRESHOLDS = {
  recentMaterialDays: 3,
  deadlineDays: 7,
  deadlineActivityLookbackDays: 14,
  minimumDeadlineActivity: 2,
  staleCourseDays: 10,
  maxGaps: 5
} as const

const PER_KIND_LIMIT: Readonly<Record<StudyGapKind, number>> = {
  'deadline-untouched': 2,
  'no-notes': 2,
  'never-opened': 3,
  'stale-course': 1
}

const MEANINGFUL_ACTIVITY_KINDS = [
  'material-opened',
  'note-created',
  'note-edited',
  'highlight-created',
  'drawing-created',
  'question-asked',
  'study-tool-run'
] as const

const DEADLINE_STOP_WORDS = new Set([
  '과제',
  '제출',
  '마감',
  '시험',
  '중간고사',
  '기말고사',
  '퀴즈',
  '레포트',
  '리포트',
  '자료',
  'assignment',
  'deadline',
  'exam',
  'homework',
  'report',
  'task',
  'pdf',
  'md',
  'markdown'
])

interface MaterialRow {
  rel_path: string
  kind: MaterialKind
  mtime: number
}

interface AnnotationSummaryRow {
  rel_path: string
  highlight_count: number
  comment_count: number
}

interface DeadlineRow {
  title: string
  due_at: string
}

interface LatestRow {
  latest: string | null
}

interface CourseCreatedRow {
  created_at: string
}

interface CountRow {
  count: number
}

function compactLine(value: string, maxLength = 64): string {
  return Array.from(value.replace(/\s+/g, ' ').trim()).slice(0, maxLength).join('')
}

function materialLabel(relPath: string): string {
  return compactLine(posix.basename(relPath), 52)
}

function gapSort(a: StudyGap, b: StudyGap): number {
  return (
    b.weight - a.weight ||
    a.kind.localeCompare(b.kind) ||
    (a.relPath ?? '').localeCompare(b.relPath ?? '')
  )
}

function tokensFor(value: string): string[] {
  return value
    .normalize('NFKC')
    .toLocaleLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter(
      (token) =>
        Array.from(token).length >= 2 && !DEADLINE_STOP_WORDS.has(token)
    )
}

function materialMatchScore(title: string, relPath: string): number {
  const titleTokens = tokensFor(title)
  const pathTokens = tokensFor(relPath)
  let score = 0

  for (const titleToken of titleTokens) {
    for (const pathToken of pathTokens) {
      if (titleToken === pathToken) {
        score = Math.max(score, Array.from(titleToken).length * 4)
        continue
      }
      const shorter =
        titleToken.length <= pathToken.length ? titleToken : pathToken
      if (
        Array.from(shorter).length >= 3 &&
        (titleToken.includes(pathToken) || pathToken.includes(titleToken))
      ) {
        score = Math.max(score, Array.from(shorter).length * 2)
      }
    }
  }

  return score
}

/** Returns null when no material is a clear, unique filename/title match. */
function relatedMaterial(
  title: string,
  materials: readonly MaterialRow[]
): MaterialRow | null {
  const ranked = materials
    .map((material) => ({
      material,
      score: materialMatchScore(title, material.rel_path)
    }))
    .filter((candidate) => candidate.score > 0)
    .sort(
      (a, b) =>
        b.score - a.score || a.material.rel_path.localeCompare(b.material.rel_path)
    )

  const first = ranked[0]
  if (first === undefined || ranked[1]?.score === first.score) return null
  return first.material
}

function countMeaningfulActivity(
  db: Database,
  courseId: string,
  since: string,
  relPath: string | null
): number {
  const kinds = MEANINGFUL_ACTIVITY_KINDS.map(() => '?').join(', ')
  const pathClause = relPath === null ? '' : 'AND rel_path = ?'
  const params = [courseId, ...MEANINGFUL_ACTIVITY_KINDS, since]
  if (relPath !== null) params.push(relPath)
  const row = db
    .prepare(
      `SELECT COUNT(*) AS count
       FROM activity_events
       WHERE course_id = ?
         AND kind IN (${kinds})
         AND created_at >= ?
         ${pathClause}`
    )
    .get(...params) as CountRow
  return row.count
}

function readMaterials(db: Database, courseId: string): MaterialRow[] {
  return db
    .prepare(
      `SELECT rel_path, kind, mtime
       FROM materials_index
       WHERE course_id = ?
         AND deleted_at IS NULL
         AND rel_path NOT LIKE '.bandal/%'
       ORDER BY rel_path ASC`
    )
    .all(courseId) as MaterialRow[]
}

function neverOpenedGaps(
  db: Database,
  courseId: string,
  materials: readonly MaterialRow[],
  nowMs: number
): StudyGap[] {
  const recentCutoffMs =
    nowMs - INSIGHTS_THRESHOLDS.recentMaterialDays * DAY_MS
  const recentCutoffIso = new Date(recentCutoffMs).toISOString()
  const opened = new Set(
    (
      db
        .prepare(
          `SELECT DISTINCT rel_path
           FROM activity_events
           WHERE course_id = ? AND kind = 'material-opened' AND rel_path IS NOT NULL`
        )
        .all(courseId) as { rel_path: string }[]
    ).map((row) => row.rel_path)
  )
  const recentlyAdded = new Set(
    (
      db
        .prepare(
          `SELECT DISTINCT rel_path
           FROM activity_events
           WHERE course_id = ?
             AND kind = 'material-added'
             AND rel_path IS NOT NULL
             AND created_at >= ?`
        )
        .all(courseId, recentCutoffIso) as { rel_path: string }[]
    ).map((row) => row.rel_path)
  )

  return materials
    .filter(
      (material) =>
        !opened.has(material.rel_path) &&
        !recentlyAdded.has(material.rel_path) &&
        material.mtime < recentCutoffMs
    )
    .map((material) => {
      const ageDays = Math.floor((nowMs - material.mtime) / DAY_MS)
      return {
        kind: 'never-opened' as const,
        relPath: material.rel_path,
        message: `“${materialLabel(material.rel_path)}” 자료는 아직 열어보지 않았어요. 필요할 때 가볍게 살펴봐요.`,
        weight: 50 + Math.min(10, Math.floor(ageDays / 7))
      }
    })
    .sort(gapSort)
    .slice(0, PER_KIND_LIMIT['never-opened'])
}

function noteStems(materials: readonly MaterialRow[]): Set<string> {
  return new Set(
    materials
      .filter((material) => material.kind === 'note')
      .map((material) =>
        posix.basename(material.rel_path, posix.extname(material.rel_path))
      )
      .map((stem) => stem.normalize('NFKC').toLocaleLowerCase())
  )
}

function noNotesGaps(
  db: Database,
  courseId: string,
  materials: readonly MaterialRow[],
  citedMaterialPaths: ReadonlySet<string>
): StudyGap[] {
  const currentPaths = new Set(materials.map((material) => material.rel_path))
  const existingNoteStems = noteStems(materials)
  const noteActivityPaths = new Set(
    (
      db
        .prepare(
          `SELECT DISTINCT rel_path
           FROM activity_events
           WHERE course_id = ?
             AND kind IN ('note-created', 'note-edited')
             AND rel_path IS NOT NULL`
        )
        .all(courseId) as { rel_path: string }[]
    ).map((row) => row.rel_path)
  )
  const annotations = db
    .prepare(
      `SELECT rel_path,
              COUNT(*) AS highlight_count,
              SUM(CASE WHEN TRIM(COALESCE(comment, '')) = '' THEN 0 ELSE 1 END)
                AS comment_count
       FROM annotations
       WHERE course_id = ? AND deleted_at IS NULL
       GROUP BY rel_path
       ORDER BY rel_path ASC`
    )
    .all(courseId) as AnnotationSummaryRow[]

  return annotations
    .filter((row) => {
      if (!currentPaths.has(row.rel_path) || row.comment_count > 0) return false
      if (noteActivityPaths.has(row.rel_path)) return false
      if (citedMaterialPaths.has(row.rel_path)) return false
      const stem = posix
        .basename(row.rel_path, posix.extname(row.rel_path))
        .normalize('NFKC')
        .toLocaleLowerCase()
      return !existingNoteStems.has(stem)
    })
    .map((row) => ({
      kind: 'no-notes' as const,
      relPath: row.rel_path,
      message: `“${materialLabel(row.rel_path)}”의 하이라이트에 짧은 메모를 더하면 복습할 때 도움이 돼요.`,
      weight: 70 + Math.min(10, row.highlight_count)
    }))
    .sort(gapSort)
    .slice(0, PER_KIND_LIMIT['no-notes'])
}

function deadlineGaps(
  db: Database,
  courseId: string,
  materials: readonly MaterialRow[],
  nowMs: number
): StudyGap[] {
  const nowIso = new Date(nowMs).toISOString()
  const deadlineCutoff = new Date(
    nowMs + INSIGHTS_THRESHOLDS.deadlineDays * DAY_MS
  ).toISOString()
  const activityCutoff = new Date(
    nowMs - INSIGHTS_THRESHOLDS.deadlineActivityLookbackDays * DAY_MS
  ).toISOString()
  const deadlines = db
    .prepare(
      `SELECT title, due_at
       FROM board_tasks
       WHERE course_id = ?
         AND deleted_at IS NULL
         AND status != 'done'
         AND due_at IS NOT NULL
         AND due_at >= ?
         AND due_at <= ?
       ORDER BY due_at ASC, created_at ASC`
    )
    .all(courseId, nowIso, deadlineCutoff) as DeadlineRow[]

  return deadlines
    .flatMap((deadline): StudyGap[] => {
      const material = relatedMaterial(deadline.title, materials)
      const relPath = material?.rel_path ?? null
      const activityCount = countMeaningfulActivity(
        db,
        courseId,
        activityCutoff,
        relPath
      )
      if (activityCount >= INSIGHTS_THRESHOLDS.minimumDeadlineActivity) return []

      const dueMs = Date.parse(deadline.due_at)
      if (!Number.isFinite(dueMs)) return []
      const daysLeft = Math.max(0, Math.ceil((dueMs - nowMs) / DAY_MS))
      const title = compactLine(deadline.title)
      const message =
        material === null
          ? `“${title}” 마감이 가까워요. 준비할 자료를 가볍게 정리해 볼까요?`
          : `“${title}” 마감이 가까워요. “${materialLabel(material.rel_path)}”을 한 번 확인해 두면 좋아요.`

      return [
        {
          kind: 'deadline-untouched',
          relPath,
          message,
          weight: 100 + INSIGHTS_THRESHOLDS.deadlineDays - daysLeft
        }
      ]
    })
    .sort(gapSort)
    .slice(0, PER_KIND_LIMIT['deadline-untouched'])
}

function staleCourseGap(
  db: Database,
  courseId: string,
  nowMs: number
): StudyGap[] {
  const latest = (
    db
      .prepare(
        'SELECT MAX(created_at) AS latest FROM activity_events WHERE course_id = ?'
      )
      .get(courseId) as LatestRow
  ).latest
  const course = db
    .prepare(
      `SELECT created_at FROM courses
       WHERE id = ? AND deleted_at IS NULL`
    )
    .get(courseId) as CourseCreatedRow | undefined
  const baseline = latest ?? course?.created_at
  if (baseline === undefined) return []
  const baselineMs = Date.parse(baseline)
  if (!Number.isFinite(baselineMs)) return []
  const ageDays = Math.floor((nowMs - baselineMs) / DAY_MS)
  if (ageDays < INSIGHTS_THRESHOLDS.staleCourseDays) return []

  return [
    {
      kind: 'stale-course',
      relPath: null,
      message: '이 과목은 최근 활동이 없어요. 다음에 볼 자료 하나만 골라볼까요?',
      weight: 30 + Math.min(10, ageDays - INSIGHTS_THRESHOLDS.staleCourseDays)
    }
  ]
}

export interface InsightsDeps {
  db: Database
  getCourseFolder: (courseId: string) => string
  getMaterialCitations?: (courseId: string) => Set<string> | string[]
}

export function createInsights(deps: InsightsDeps): {
  gaps(courseId: string): StudyGap[]
} {
  return {
    gaps(courseIdInput) {
      const courseId = requireId(courseIdInput, 'courseId')
      // Course resolution is the established validation boundary for
      // course-scoped main features. Detection itself only reads SQLite.
      deps.getCourseFolder(courseId)
      const nowMs = Date.now()
      const materials = readMaterials(deps.db, courseId)
      const citedMaterialPaths = new Set(
        deps.getMaterialCitations?.(courseId) ?? []
      )
      return [
        ...deadlineGaps(deps.db, courseId, materials, nowMs),
        ...noNotesGaps(deps.db, courseId, materials, citedMaterialPaths),
        ...neverOpenedGaps(deps.db, courseId, materials, nowMs),
        ...staleCourseGap(deps.db, courseId, nowMs)
      ]
        .sort(gapSort)
        .slice(0, INSIGHTS_THRESHOLDS.maxGaps)
    }
  }
}
