import { useCourseActive } from './courseActivity'
import { useEffect, useState } from 'react'
import type { IDockviewPanelProps } from 'dockview'

/**
 * 이 dockview 패널이 지금 사용자 입력의 주인인지(활성 + 표시).
 * CanvasTab/WhiteboardTab 에 복제돼 있던 훅의 공용화 지점.
 */
export function usePanelActive(api: IDockviewPanelProps['api']): boolean {
  const courseActive = useCourseActive()
  const [active, setActive] = useState(() => api.isActive && api.isVisible)

  useEffect(() => {
    const update = (): void => setActive(api.isActive && api.isVisible)
    update()
    const activeDisposable = api.onDidActiveChange(update)
    const visibleDisposable = api.onDidVisibilityChange(update)
    return () => {
      activeDisposable.dispose()
      visibleDisposable.dispose()
    }
  }, [api])

  return courseActive && active
}
