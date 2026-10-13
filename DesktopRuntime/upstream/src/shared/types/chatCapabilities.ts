export const CREATION_KINDS = ['image', 'document', 'pdf', 'spreadsheet', 'presentation'] as const
export type CreationKind = typeof CREATION_KINDS[number]
export const CREATION_LABELS: Record<CreationKind, string> = {
  image: '이미지', document: '문서', pdf: 'PDF', spreadsheet: '스프레드시트', presentation: '슬라이드'
}
export interface ChatSkill {
  id: string
  name: string
  description: string
  creationKinds: CreationKind[]
}
export interface ChatContext {
  sourcePanelId?: string
  snapshot?: import('./chatContext').MessageContextSnapshot
  excludeCurrentMaterial?: boolean
  outputDir?: string
  files?: { relPath: string; name: string }[]
  skillIds?: string[]
  skillNames?: string[]
  creation?: CreationKind
  browser?: boolean
  screen?: boolean
}
export interface ChatArtifact {
  courseId: string
  relPath: string
  name: string
  kind: 'pdf' | 'note' | 'image' | 'other'
}
