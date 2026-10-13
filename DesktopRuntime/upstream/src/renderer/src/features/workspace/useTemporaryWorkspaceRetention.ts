import { useLayoutEffect, useState } from 'react'
import { useWorkspaceStore } from '../../stores/workspaceStore'

/** Keep a temporary workspace only after it has hosted real tabs. */
export function useTemporaryWorkspaceRetention(): boolean {
  const used = useWorkspaceStore(state => state.activeCourseId === null && Object.keys(state.openTabs).length > 0)
  const [retained, setRetained] = useState(false)
  useLayoutEffect(() => { if (used) setRetained(true) }, [used])
  // Course selection renders before setActiveCourse replaces the store snapshot.
  // Preserve its DOM in that same commit, without waiting for the latch effect.
  return retained || used
}
