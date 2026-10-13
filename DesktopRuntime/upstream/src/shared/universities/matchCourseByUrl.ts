/**
 * Which course is this browser page about?
 *
 * A student who opens the LMS page for 자료구조 and downloads a handout means
 * it to land in 자료구조 — not in whichever course happens to be selected in
 * the sidebar. Every course that has an LMS link already carries the platform
 * host and the numeric course id (`course_links`), so the mapping is a pure
 * comparison and needs no network call, no page read, and no guessing.
 *
 * Deliberately strict: a wrong match files a lecture into the wrong course,
 * which is worse than no match at all (the download still lands in the
 * selected course, which the student can see).
 */

export interface CourseUrlCandidate {
  courseId: string
  /** The saved LMS URL, e.g. `https://myetl.snu.ac.kr/courses/12345`. */
  url: string
  /** Captured course id on the platform, when the link was recognised. */
  lmsCourseId: string | null
}

function originOf(url: string): string | null {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null
    // Port is part of the identity: 인하대 :8443 and 아주대 :30443 are real.
    return parsed.origin
  } catch {
    return null
  }
}

function pathOf(url: string): string {
  try {
    return new URL(url).pathname
  } catch {
    return ''
  }
}

/**
 * Returns the course this URL belongs to, or null.
 *
 * A candidate matches when the origin is identical AND the LMS course id
 * appears as a whole path segment. The segment test is what keeps
 * `/courses/123` from matching `/courses/1234`.
 */
export function matchCourseByUrl(
  url: string,
  candidates: readonly CourseUrlCandidate[]
): string | null {
  const origin = originOf(url)
  if (origin === null) return null
  const segments = pathOf(url).split('/').filter((part) => part !== '')

  const matches = candidates.filter((candidate) => {
    if (candidate.lmsCourseId === null || candidate.lmsCourseId === '') {
      return false
    }
    if (originOf(candidate.url) !== origin) return false
    return segments.includes(candidate.lmsCourseId)
  })

  // Two courses claiming the same page means the data is ambiguous; picking
  // one at random would file work into the wrong place silently.
  if (matches.length !== 1) return null
  return matches[0]?.courseId ?? null
}
