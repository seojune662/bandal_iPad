/**
 * Per-course shortcuts (docs/university-sites.md §6.4).
 *
 * A course link is a URL pinned under one course — most often that course's
 * LMS 강의실 page (Canvas `/courses/{id}`, Moodle `/course/view.php?id=`),
 * but any http(s) URL is allowed: 학과 홈페이지, 조교 노션, 공유 드라이브.
 * Stored in SQLite (migration 004), never in the preset catalog.
 */

import type { ServiceKind } from './university'

/** 'lms-course' means the URL matched the school's CourseLinkSpec. */
export type CourseLinkKind = ServiceKind | 'lms-course'

export interface CourseLink {
  id: string
  /** FK → courses.id, ON DELETE CASCADE. */
  courseId: string
  /** 사용자가 보는 이름. */
  label: string
  /** Normalised URL actually opened. */
  url: string
  /** Exactly what the user pasted — never lost, so we can always revert. */
  rawUrl: string
  kind: CourseLinkKind
  /** Set only for 'lms-course'. Lets us rebuild the URL if the host changes. */
  lmsCourseId: string | null
  sortOrder: number
  createdAt: string
  updatedAt: string
}

export interface CreateCourseLinkInput {
  courseId: string
  label: string
  /** Raw, user-pasted URL. The main process normalises and classifies it. */
  rawUrl: string
  kind: CourseLinkKind
  /** Normalised URL; omitted → the raw URL is stored as-is. */
  url?: string
  lmsCourseId?: string | null
}

export interface UpdateCourseLinkInput {
  id: string
  label?: string
  sortOrder?: number
}
