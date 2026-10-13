import { useEffect, useState } from 'react'
import type { DockviewPanelApi } from 'dockview'
import { useCourseActive } from './courseActivity'

/** A split can be readable and scrollable while its neighbor owns shortcuts. */
export function usePanelVisible(api: DockviewPanelApi): boolean {
  const courseActive = useCourseActive()
  const [visible, setVisible] = useState(() => api.isVisible)
  useEffect(() => {
    const update = (): void => setVisible(api.isVisible)
    const subscription = api.onDidVisibilityChange(update)
    update()
    return () => subscription.dispose()
  }, [api])
  return courseActive && visible
}
