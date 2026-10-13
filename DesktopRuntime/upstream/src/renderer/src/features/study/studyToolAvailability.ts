import type { StudyToolDefinition } from '../../../../shared/types/study'

export function isStudyToolEnabled(
  tool: Pick<StudyToolDefinition, 'worksOnCourse'>,
  relPath: string | null
): boolean {
  return relPath !== null || tool.worksOnCourse
}
