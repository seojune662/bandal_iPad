// An active capture may be displayed in the library or its own file tab.
// Reuse that view when the global indicator is clicked, including split panes.
const views = new Map<string, { sessionId: string; activate: () => void }>()

export function registerRecordingView(
  panelId: string,
  sessionId: string,
  activate: () => void
): () => void {
  const view = { sessionId, activate }
  views.set(panelId, view)
  return () => {
    if (views.get(panelId) === view) views.delete(panelId)
  }
}
export function activateRecordingView(sessionId: string): boolean {
  const view = [...views.values()].find(
    (candidate) => candidate.sessionId === sessionId
  )
  if (!view) return false
  const panelId = [...views.entries()].find(([, entry]) => entry === view)?.[0]
  const placement = panelId ? workspaceCourseForPanel(panelId) : null
  if (placement) useCoursesStore.getState().selectCourse(placement)
  view.activate()
  return true
}
import { useCoursesStore } from '../../stores/coursesStore'
import { workspaceCourseForPanel } from '../../stores/workspaceStore'
