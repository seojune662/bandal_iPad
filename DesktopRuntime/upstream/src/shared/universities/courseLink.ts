/**
 * Course-URL parsing (docs/university-sites.md §4.3).
 *
 * UX principle: never ask a student for a "course id" — they know how to
 * copy an address bar, not what Canvas calls a course. So everything here
 * takes a pasted URL and decides what it is:
 *
 *  - matches the school's `CourseLinkSpec` → `lms-course`, normalised to the
 *    course root (`/assignments`, `#section-3` are dropped, the raw URL is
 *    kept so nothing is lost)
 *  - valid http(s) but not a course page → `generic`. **We never reject it** —
 *    학과 홈페이지, 조교 노션, 공유 드라이브 are all legitimate pins.
 *  - not a URL at all → `invalid`
 *
 * Pure, no I/O, no DOM. Two traps this module exists to avoid:
 *  1. `etl.snu.ac.kr`'s 24-hex `catalog_id` is NOT a Canvas course id.
 *  2. Non-standard ports are load-bearing (인하대 IdP `:8443`, 아주대
 *     학사서비스 `:30443` — 443 is not even open). Never strip the port.
 */

import type { CourseLinkSpec, LmsPlatform } from '../types/university'
import { canvasCourseLink, moodleCourseLink } from './specs'

export type CourseUrlInvalidReason = 'empty' | 'unsupported-scheme' | 'malformed'

export type CourseUrlParse =
  | {
      status: 'lms-course'
      /** Normalised course-root URL. */
      url: string
      rawUrl: string
      lmsCourseId: string
      platform: LmsPlatform
      /** false → surface a 베타 badge (iLOS session-bound keys). */
      reliable: boolean
    }
  | { status: 'generic'; url: string; rawUrl: string }
  | { status: 'invalid'; reason: CourseUrlInvalidReason }

/** `host[:port]` optionally followed by a path — no scheme typed by the user. */
const BARE_HOST = /^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?([/?#].*)?$/i
const HAS_SCHEME = /^[a-z][a-z0-9+.-]*:/i

/**
 * Trims, adds the implicit `https://`, and validates the scheme.
 * Returns the normalised absolute URL, or null when it is not http(s).
 * The port, query and fragment survive untouched.
 */
export function normalizeHttpUrl(rawUrl: string): string | null {
  const trimmed = rawUrl.trim()
  if (trimmed.length === 0) return null

  // Order matters: `inha.ac.kr:8443/x` looks scheme-ish to HAS_SCHEME.
  const candidate = BARE_HOST.test(trimmed)
    ? `https://${trimmed}`
    : HAS_SCHEME.test(trimmed)
      ? trimmed
      : null
  if (candidate === null) return null

  try {
    const parsed = new URL(candidate)
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    if (parsed.hostname.length === 0) return null
    return parsed.href
  } catch {
    return null
  }
}

/** Substitutes `{id}` into a spec template. */
export function buildCourseUrl(spec: CourseLinkSpec, courseId: string): string {
  return spec.template.replace('{id}', courseId)
}

/**
 * Classifies a pasted URL against the school's spec.
 * `spec` is null/undefined for custom schools with no known LMS — every URL
 * then lands as `generic`, which is the intended behaviour.
 */
export function parseCourseUrl(
  rawUrl: string,
  spec: CourseLinkSpec | null | undefined
): CourseUrlParse {
  if (typeof rawUrl !== 'string' || rawUrl.trim().length === 0) {
    return { status: 'invalid', reason: 'empty' }
  }
  const trimmed = rawUrl.trim()
  const normalized = normalizeHttpUrl(trimmed)
  if (normalized === null) {
    return {
      status: 'invalid',
      reason: HAS_SCHEME.test(trimmed) ? 'unsupported-scheme' : 'malformed'
    }
  }
  if (spec === null || spec === undefined) {
    return { status: 'generic', url: normalized, rawUrl: trimmed }
  }

  const match = matchCourseId(spec, normalized)
  if (match === null) {
    return { status: 'generic', url: normalized, rawUrl: trimmed }
  }
  return {
    status: 'lms-course',
    url: buildCourseUrl(spec, match),
    rawUrl: trimmed,
    lmsCourseId: match,
    platform: spec.platform,
    reliable: spec.reliable
  }
}

/** Runs the spec's anchored pattern; returns the captured id or null. */
export function matchCourseId(
  spec: CourseLinkSpec,
  url: string
): string | null {
  let pattern: RegExp
  try {
    pattern = new RegExp(spec.idPattern)
  } catch {
    // A malformed preset must degrade to "generic link", never throw.
    return null
  }
  const match = pattern.exec(url)
  const captured = match?.[1]
  return captured === undefined || captured.length === 0 ? null : captured
}

/**
 * Custom schools get a free deep-link adapter: Canvas and Moodle cover the
 * overwhelming majority of Korean LMS installs, and both are recognisable
 * from a single pasted course URL (docs/university-sites.md §6.3-3).
 */
export function inferCourseLinkSpec(rawUrl: string): CourseLinkSpec | null {
  const normalized = normalizeHttpUrl(rawUrl)
  if (normalized === null) return null

  let parsed: URL
  try {
    parsed = new URL(normalized)
  } catch {
    return null
  }
  // `host` (not `hostname`) so a non-standard port survives into the spec.
  const host = parsed.host

  if (/^\/courses\/\d+(?:\/|$)/.test(parsed.pathname)) {
    return canvasCourseLink(host)
  }
  if (
    parsed.pathname.endsWith('/course/view.php') &&
    /^\d+$/.test(parsed.searchParams.get('id') ?? '')
  ) {
    return moodleCourseLink(host)
  }
  return null
}

/** Default label for a new pin — the student can rename it right after. */
export function defaultCourseLinkLabel(parse: CourseUrlParse): string {
  if (parse.status === 'invalid') return ''
  if (parse.status === 'lms-course') return '강의실'
  try {
    return new URL(parse.url).hostname.replace(/^www\./, '')
  } catch {
    return '링크'
  }
}
