import type { PackStudyToolDefinition } from './studyToolsStore'

export const FEATURED_STUDY_TOOLS = ['summary', 'quiz', 'flashcards'] as const
export const STUDY_TOOL_GROUPS = ['이해하기', '정리하기', '시험 준비', '설치한 도구'] as const
export type StudyToolGroup = typeof STUDY_TOOL_GROUPS[number]

export function studyToolLabel(tool: PackStudyToolDefinition): string {
  if (tool.source === 'user') return tool.label
  return ({ summary: '핵심 요약', quiz: '퀴즈 만들기', flashcards: '복습 카드' } as Record<string, string>)[tool.id] ?? tool.label
}

export function studyToolGroup(tool: PackStudyToolDefinition): StudyToolGroup {
  if (tool.source === 'user') return '설치한 도구'
  if (tool.id === 'structured-notes') return '정리하기'
  if (['quiz', 'flashcards', 'exam-predictions'].includes(tool.id)) return '시험 준비'
  return '이해하기'
}

export function studyToolOutput(tool: PackStudyToolDefinition): string {
  if (tool.experience === 'quiz') return '직접 푸는 퀴즈'
  if (tool.experience === 'flashcards') return '넘겨 보는 카드'
  return '노트로 저장'
}

export function studyToolDescription(tool: PackStudyToolDefinition): string {
  if (tool.source === 'user') return tool.description
  if (tool.experience === 'quiz') return '핵심 내용을 문제로 풀고, 정답과 해설로 확인해요.'
  if (tool.experience === 'flashcards') return '질문과 답을 카드로 넘기며 중요한 개념을 복습해요.'
  return tool.description
}

export function studyToolMatches(tool: PackStudyToolDefinition, query: string): boolean {
  const needle = query.trim().toLocaleLowerCase()
  return !needle || `${studyToolLabel(tool)} ${tool.label} ${studyToolDescription(tool)} ${studyToolGroup(tool)} ${studyToolOutput(tool)} ${tool.followUp?.label ?? tool.followUpLabel ?? ''}`.toLocaleLowerCase().includes(needle)
}

export function studyToolFollowUpLabel(tool: PackStudyToolDefinition): string | null {
  return tool.followUp?.label ?? tool.followUpLabel ?? null
}

export function isPackFollowUpAvailable(tool: PackStudyToolDefinition, relPath: string | null): boolean {
  if (tool.experience || relPath === null || tool.enabled === false || studyToolFollowUpLabel(tool) === null) return false
  const directory = (tool.outputs?.dir ?? tool.outputDir ?? tool.outputsDir)?.replace(/^\.\//, '').replace(/\/+$/, '')
  const target = relPath.replace(/^\.\//, '')
  return !!directory && target.startsWith(`${directory}/`)
}
