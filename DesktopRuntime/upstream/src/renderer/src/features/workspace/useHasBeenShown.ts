import { useCourseActive } from './courseActivity'
import { useEffect, useState } from 'react'
import type { DockviewPanelApi } from 'dockview'

function isShown(api: DockviewPanelApi): boolean {
  // isActive means the globally focused panel, not the selected tab of each
  // split group. A visible PDF must load while the neighboring note has focus.
  return api.isVisible
}

/**
 * Latches once the panel is visible, including an unfocused split group.
 */
export function useHasBeenShown(api: DockviewPanelApi): boolean {
  const active = useCourseActive()
  const [hasBeenShown, setHasBeenShown] = useState(() => active && isShown(api))

  useEffect(() => {
    if (hasBeenShown) return

    const update = (): void => {
      if (active && isShown(api)) setHasBeenShown(true)
    }
    const activeDisposable = api.onDidActiveChange(update)
    const visibleDisposable = api.onDidVisibilityChange(update)

    // Cover a state change between the initial render and effect subscription.
    update()

    return () => {
      activeDisposable.dispose()
      visibleDisposable.dispose()
    }
  }, [api, hasBeenShown, active])

  return hasBeenShown
}
