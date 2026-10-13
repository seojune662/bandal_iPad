/**
 * Korean copy for folder-registration failures (해요체, per docs/STYLEGUIDE.md
 * §7: 한 문장 사실 + 한 문장 안내).
 */

import type { CourseFolderProblem } from '../../../../shared/types/course'

const MESSAGES: Record<CourseFolderProblem, string> = {
  missing: '폴더를 찾을 수 없어요. 다른 폴더를 골라주세요.',
  'not-a-directory': '폴더가 아니에요. 폴더를 골라주세요.',
  unreadable: '폴더를 읽을 권한이 없어요. 접근 권한을 확인해주세요.'
}

export function folderProblemMessage(reason: CourseFolderProblem): string {
  return MESSAGES[reason]
}
