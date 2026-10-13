import type { LearningProjectSnapshot, LearningProjectSummary, LearningPurpose } from '../../../../shared/types/learning'

export function learningPurpose(project: Pick<LearningProjectSummary, 'purpose'>): LearningPurpose {
  return project.purpose ?? 'unclassified'
}
export function learningPurposeLabel(project: Pick<LearningProjectSummary, 'purpose'>): string {
  return project.purpose === 'english-reading' ? '영어 이어읽기' : project.purpose === 'course-review' ? '과목 복습' : '종류 확인 필요'
}
export function learningNeedsSettings(project: Pick<LearningProjectSnapshot, 'purpose' | 'readingSetupConfirmed' | 'ai'>): boolean {
  return !project.purpose || project.purpose === 'unclassified' || !project.ai?.model || project.purpose === 'english-reading' && !project.readingSetupConfirmed
}
