/**
 * CourseLinkSpec builders.
 *
 * Korean university LMS is a Canvas / Moodle duopoly — 15 of the 18 surveyed
 * schools (docs/university-sites.md §4.1), so two adapters cover almost
 * everything and iLOS / Blackboard are the long tail. Building the specs from
 * a host keeps the regexes identical across schools instead of 15 hand-typed
 * patterns that drift.
 *
 * Every value produced here is a plain string — a spec is JSON-serializable
 * and travels through settings/IPC unchanged.
 */

import type { CourseLinkSpec } from '../types/university'

/** Escapes a hostname (dots, and the colon of a non-standard port) for regex. */
export function escapeForRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Canvas (often wrapped by Xinics LearningX): `https://<core>/courses/{id}`.
 *
 * ⚠️ The route only exists on the CORE host (`canvas.*`, `myetl.*`) — the
 * front host (`lms.*`, `icampus.*`, `etl.*`) 404s on it. Always pass the core.
 */
export function canvasCourseLink(
  host: string,
  options: { reliable?: boolean; hint?: string } = {}
): CourseLinkSpec {
  return {
    platform: 'canvas',
    template: `https://${host}/courses/{id}`,
    idPattern: `^https?://${escapeForRegex(host)}/courses/(\\d+)(?:[/?#].*)?$`,
    hint:
      options.hint ??
      `강의실에서 과목을 연 뒤 주소창을 통째로 붙여넣어 주세요. (${host}/courses/12345)`,
    reliable: options.reliable ?? true
  }
}

/** Moodle (Coursemos / 유비온 / OKlass): `/course/view.php?id={id}`. */
export function moodleCourseLink(
  host: string,
  options: { reliable?: boolean; hint?: string } = {}
): CourseLinkSpec {
  return {
    platform: 'moodle',
    template: `https://${host}/course/view.php?id={id}`,
    idPattern: `^https?://${escapeForRegex(host)}/course/view\\.php\\?(?:[^#]*&)?id=(\\d+)`,
    hint:
      options.hint ??
      `강의실에서 과목을 연 뒤 주소창을 통째로 붙여넣어 주세요. (${host}/course/view.php?id=12345)`,
    reliable: options.reliable ?? true
  }
}

/**
 * iLOS (`.acl`): the course key is a STRING (`KJKEY`), not an integer, and it
 * may be bound to the session — always shipped as 베타 (`reliable: false`).
 */
export function ilosCourseLink(host: string): CourseLinkSpec {
  return {
    platform: 'ilos',
    template: `https://${host}/ilos/st/course/submain_form.acl?KJKEY={id}`,
    idPattern: `^https?://${escapeForRegex(host)}/ilos/st/course/submain_form\\.acl\\?(?:[^#]*&)?KJKEY=([A-Za-z0-9_-]+)`,
    hint: `강의실 주소를 붙여넣어 주세요. 이 학교의 과목 키는 숫자가 아니라 문자열(KJKEY)이라 로그인 세션에 따라 달라질 수 있어요.`,
    reliable: false
  }
}

/** Blackboard: the id is wrapped as `_{숫자}_1` in both Ultra and Original. */
export function blackboardCourseLink(host: string): CourseLinkSpec {
  return {
    platform: 'blackboard',
    template: `https://${host}/ultra/courses/_{id}_1/cl/outline`,
    idPattern: `^https?://${escapeForRegex(host)}/\\S*_(\\d+)_1`,
    hint: `강의실 주소를 붙여넣어 주세요. Blackboard는 과목 번호를 _12345_1 형태로 씁니다.`,
    reliable: false
  }
}
