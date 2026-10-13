import { createContext, useContext } from 'react'

/** Captured when an action starts; asynchronous work must not follow focus. */
export interface WorkspaceTarget {
  courseId: string | null
  groupId: string
}

/** Placement is independent of a document's original resource/course binding. */
export interface WorkspacePlacement {
  courseId: string | null
  panelId: string
  instanceId: string
}

export const WorkspacePlacementContext = createContext<WorkspacePlacement | null>(null)
/** Dockview presentation slots use this before their content has an instance. */
export const WorkspaceCourseContext = createContext<string | null>(null)
export function useWorkspacePlacement(): WorkspacePlacement | null {
  return useContext(WorkspacePlacementContext)
}
