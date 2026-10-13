import type { MaterialNode } from '../../../../shared/types/materials'
import { useMaterialsStore } from '../../stores/materialsStore'
import { studyTargetContext } from '../launcher/launcherContext'
import { StudyToolsIcon } from './StudyToolIcons'
import { requestStudyPalette } from './studyPaletteEvents'

interface MaterialsStudyToolMenuItemProps {
  target: MaterialNode | null
  returnFocus: HTMLElement | null
  onClose: () => void
}

export function MaterialsStudyToolMenuItem({ target, returnFocus, onClose }: MaterialsStudyToolMenuItemProps): JSX.Element | null {
  const courseId = useMaterialsStore(state => state.activeCourseId)
  if (target?.kind === 'dir') return null
  return <button
    type="button"
    role="menuitem"
    aria-haspopup="dialog"
    disabled={courseId === null}
    title={courseId === null ? '먼저 과목을 선택하세요.' : undefined}
    onClick={() => {
      if (courseId === null) return
      const context = studyTargetContext(courseId, target?.relPath ?? null, '')
      onClose()
      requestStudyPalette({ context, returnFocus })
    }}
  >
    <StudyToolsIcon />
    <span className="study-tool-menu-trigger__label">{target ? '이 자료로 학습하기…' : '과목 학습 도구…'}</span>
  </button>
}
