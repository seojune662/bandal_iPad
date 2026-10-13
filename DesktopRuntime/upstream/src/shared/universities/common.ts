/**
 * Services every school shares, merged into the sidebar after the school's
 * own presets and before the user's custom entries (`resolveServices`).
 *
 * Ids live in the `common.` namespace — never under a university id, so the
 * catalog invariant "every preset id is namespaced under its school" keeps
 * holding for `University.services`. Like every other service id, a
 * `common.*` id is never renamed: settings (hidden list, order, tier
 * overrides) reference it by string.
 */

import type { UniversityService } from '../types/university'

export const COMMON_SERVICES: readonly UniversityService[] = [
  {
    id: 'common.everytime',
    kind: 'community',
    label: '에브리타임',
    labelEn: 'Everytime',
    url: 'https://everytime.kr/',
    verification: 'partial',
    note: '학교 인증을 마친 계정으로 로그인하면 우리 학교 게시판·시간표가 보여요.'
  }
]
