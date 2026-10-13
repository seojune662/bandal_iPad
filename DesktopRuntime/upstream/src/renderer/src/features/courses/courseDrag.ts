/**
 * 과목 드래그(사이드바 재배치/그룹 이동)의 순수 로직.
 *
 * HTML5 dnd 의 dragover 에서는 getData 를 읽을 수 없으므로, dragstart 에서
 * 모듈 레벨 ref 에 페이로드를 넣고 dragend 에서 비운다. drop 시에는 커스텀
 * MIME 페이로드를 방어적으로 파싱한다 (패턴: favoriteDrop.ts).
 */

export const COURSE_DRAG_MIME = 'application/x-bandal-course'

export interface CourseDragPayload {
  version: 1
  courseId: string
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}

export function serializeCourseDrag(courseId: string): string {
  return JSON.stringify({ version: 1, courseId } satisfies CourseDragPayload)
}

/** 적대적/깨진 데이터에도 절대 throw 하지 않는다. */
export function parseCourseDrag(raw: string): CourseDragPayload | null {
  try {
    const value: unknown = JSON.parse(raw)
    if (!isRecord(value)) return null
    if (value['version'] !== 1) return null
    if (!nonEmptyString(value['courseId'])) return null
    return { version: 1, courseId: value['courseId'].trim() }
  } catch {
    return null
  }
}

export function canAcceptCourseDrag(types: readonly string[]): boolean {
  return types.includes(COURSE_DRAG_MIME)
}

// dragover 는 getData 를 읽을 수 없으므로(브라우저 보안 제약) 진행 중인
// 드래그를 모듈 레벨 ref 로 공유한다. dragstart 에서 set, dragend 에서 clear.
let currentCourseDrag: CourseDragPayload | null = null

export function setCurrentCourseDrag(payload: CourseDragPayload): void {
  currentCourseDrag = payload
}

export function clearCurrentCourseDrag(): void {
  currentCourseDrag = null
}

export function getCurrentCourseDrag(): CourseDragPayload | null {
  return currentCourseDrag
}
