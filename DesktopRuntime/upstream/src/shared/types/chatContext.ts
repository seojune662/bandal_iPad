export interface MaterialContext {
  unavailable?: boolean
  courseId: string
  kind: string
  title: string
  relPath?: string
  documentId?: string
  page?: number
  selection?: string
  text?: string
  unsaved?: boolean
  browserTabId?: string
  url?: string
}
export interface MessageContextSnapshot {
  id: string
  courseId: string
  courseName: string
  capturedAt: string
  material?: MaterialContext
  refresh: 'fresh' | 'cached' | 'failed'
}
