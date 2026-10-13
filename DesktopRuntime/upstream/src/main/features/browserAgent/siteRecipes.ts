/**
 * Reading a course's LMS without opening a page.
 *
 * The cheapest rung of the ladder, and the one that carries most of the value:
 * Canvas exposes a full REST API to a plain session cookie, and Canvas is
 * roughly half of the 18 schools in `shared/universities` (docs/university-sites.md
 * §4.1). Because `course_links` already stores the core host and the numeric
 * course id, the agent can ask "what is new in 자료구조" and get JSON — with no
 * guest, no DOM, no snapshot, no clicking, and no tab even being open.
 *
 * The fetch goes through `persist:browsing`, the same session the student
 * logged into by hand. `linkDownload.ts` already proves this works for files;
 * this is the same trick applied to a JSON endpoint.
 *
 * Moodle has no cookie-auth REST API, so it is NOT handled here — a Moodle
 * course needs the HTML rung, which is a separate, later piece of work. This
 * module reports `unsupported` rather than pretending.
 */

import type { CourseLinkSpec, LmsPlatform } from '../../../shared/types/university'

export type LmsListKind = 'announcements' | 'assignments' | 'modules' | 'files'

export interface LmsItem {
  id: string
  title: string
  /** ISO date the item is about (posted / due), when the platform gives one. */
  at: string | null
  /** Page a student would open to see it. */
  url: string
}

export type LmsListResult =
  | { status: 'ok'; items: LmsItem[] }
  | { status: 'unsupported'; platform: LmsPlatform | null; message: string }
  | { status: 'failed'; message: string }

/** Canvas REST paths, keyed by what a student would ask for. */
const CANVAS_PATHS: Record<LmsListKind, string> = {
  announcements: 'discussion_topics?only_announcements=true&per_page=20',
  assignments: 'assignments?per_page=40&order_by=due_at',
  modules: 'modules?include[]=items&per_page=40',
  files: 'files?per_page=40&sort=created_at&order=desc'
}

export interface LmsTarget {
  platform: LmsPlatform
  /** Core host origin, e.g. `https://myetl.snu.ac.kr`. */
  origin: string
  lmsCourseId: string
}

/** Derives the API target from a saved course link, or null when it cannot. */
export function lmsTargetFor(
  link: { url: string; lmsCourseId: string | null },
  spec: Pick<CourseLinkSpec, 'platform'> | null
): LmsTarget | null {
  if (link.lmsCourseId === null || link.lmsCourseId === '') return null
  if (spec === null) return null
  try {
    const parsed = new URL(link.url)
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    return {
      platform: spec.platform,
      origin: parsed.origin,
      lmsCourseId: link.lmsCourseId
    }
  } catch {
    return null
  }
}

interface CanvasRow {
  id?: number | string
  title?: string
  name?: string
  display_name?: string
  posted_at?: string | null
  created_at?: string | null
  due_at?: string | null
  html_url?: string
  url?: string
}

/** Canvas uses a different name field per resource; this is the union of them. */
function canvasTitle(row: CanvasRow): string {
  return row.title ?? row.name ?? row.display_name ?? ''
}

function canvasDate(row: CanvasRow, kind: LmsListKind): string | null {
  if (kind === 'assignments') return row.due_at ?? null
  return row.posted_at ?? row.created_at ?? null
}

export function parseCanvasList(
  payload: unknown,
  kind: LmsListKind,
  target: LmsTarget
): LmsItem[] {
  if (!Array.isArray(payload)) return []
  return payload.flatMap((raw) => {
    if (typeof raw !== 'object' || raw === null) return []
    const row = raw as CanvasRow
    const title = canvasTitle(row).trim()
    if (title === '') return []
    const id = String(row.id ?? title)
    // `html_url` is the page a student opens; `url` is the API resource, which
    // is useless to a human, so it is only a last resort.
    const href =
      row.html_url ??
      `${target.origin}/courses/${target.lmsCourseId}`
    return [{ id, title, at: canvasDate(row, kind), url: href }]
  })
}

export interface LmsFetchDeps {
  /** Session-bound fetch — must be the browsing partition's. */
  fetch: (url: string) => Promise<Response>
}

export async function fetchLmsList(
  deps: LmsFetchDeps,
  target: LmsTarget,
  kind: LmsListKind
): Promise<LmsListResult> {
  if (target.platform !== 'canvas') {
    return {
      status: 'unsupported',
      platform: target.platform,
      message:
        '이 학교 강의실은 아직 목록을 바로 읽지 못해요. 브라우저에서 직접 확인해 주세요.'
    }
  }

  const url = `${target.origin}/api/v1/courses/${target.lmsCourseId}/${CANVAS_PATHS[kind]}`
  try {
    const response = await deps.fetch(url)
    if (response.status === 401 || response.status === 403) {
      return {
        status: 'failed',
        message: '강의실에 로그인되어 있지 않아요. 브라우저에서 먼저 로그인해 주세요.'
      }
    }
    if (!response.ok) {
      return { status: 'failed', message: '강의실이 응답하지 않았어요.' }
    }
    return { status: 'ok', items: parseCanvasList(await response.json(), kind, target) }
  } catch {
    return { status: 'failed', message: '강의실에 연결하지 못했어요.' }
  }
}
