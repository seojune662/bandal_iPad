import type { TabDescriptor } from '../../../../shared/tabs'
import type { RecordingSession } from '../../../../shared/recording'

export const MATERIAL_NEW_DURATION_MS = 24 * 60 * 60 * 1000

export function isRecentMaterial(addedAt: number | undefined, now: number): boolean {
  return addedAt !== undefined && Number.isFinite(addedAt) && addedAt <= now && now < addedAt + MATERIAL_NEW_DURATION_MS
}

export function materialStatusKey(courseId: string, relPath: string): string {
  return `file:${courseId}\0${relPath}`
}

export function whiteboardStatusKey(courseId: string, boardId: string): string {
  return `board:${courseId}\0${boardId}`
}

/** Match source bindings, never titles, instance IDs, or workspace placement. */
export function openMaterialKeys(tabs: readonly TabDescriptor[], recordings: readonly RecordingSession[]): Set<string> {
  const keys = new Set<string>()
  const audioPaths = new Map(recordings.map(session => [`${session.courseId}\0${session.id}`, session.audioRelPath]))
  for (const tab of tabs) {
    switch (tab.kind) {
      case 'pdf': case 'note': case 'image': case 'file':
        keys.add(materialStatusKey(tab.payload.courseId, tab.payload.relPath))
        break
      case 'whiteboard':
        keys.add(whiteboardStatusKey(tab.payload.courseId, tab.payload.boardId))
        break
      case 'recording': {
        const path = audioPaths.get(`${tab.payload.courseId}\0${tab.payload.sessionId}`)
        if (path) keys.add(materialStatusKey(tab.payload.courseId, path))
        break
      }
    }
  }
  return keys
}
