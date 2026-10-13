import { useCallback, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { LearningProjectSummary } from '../../../../shared/types/learning'
import { Icon } from '../../app/icons'
import { showToast, showToastWithAction } from '../../app/toast'
import { useDismissableMenu } from '../../components/useDismissableMenu'
import { useFocusTrap } from '../../components/useFocusTrap'
import { invoke } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { flushCourseNotes } from '../notes/noteSessionRegistry'
import { learningError, notifyLearningChanged, openLearningHome } from './learningNavigation'
import { learningDisplayName } from './learningPresentation'

export async function restoreLearningSpace(project: LearningProjectSummary): Promise<void> {
  await invoke('learning:restore', { binding: project.binding })
  await useCoursesStore.getState().loadCourses()
  notifyLearningChanged()
}

export function LearningSpaceMenu({ project, contextRequest = 0 }: { project: LearningProjectSummary; contextRequest?: number }): JSX.Element {
  const [menu, setMenu] = useState(false)
  const [mode, setMode] = useState<'rename' | 'delete' | null>(null)
  const [position, setPosition] = useState({ left: 0, top: 0 })
  const trigger = useRef<HTMLButtonElement>(null)
  const root = useRef<HTMLDivElement>(null)
  const courses = useCoursesStore(state => state.courses)
  const name = learningDisplayName(project, courses)
  const close = useCallback(() => setMenu(false), [])
  useDismissableMenu(menu, root, close)
  const open = (): void => {
    const rect = trigger.current?.getBoundingClientRect()
    if (rect) setPosition({ left: Math.max(8, Math.min(rect.right - 184, window.innerWidth - 192)), top: Math.min(rect.bottom + 4, window.innerHeight - 148) })
    setMenu(true)
  }
  useEffect(() => { if (contextRequest) open() }, [contextRequest])
  useEffect(() => { if (menu) return acquirePointerPassthrough() }, [menu])
  return <>
    <button ref={trigger} type="button" className="bare-icon-button learning-space-menu-button" aria-label={`${name} 더보기`} aria-haspopup="menu" aria-expanded={menu} onClick={() => menu ? close() : open()}><span aria-hidden="true">···</span></button>
    {menu && createPortal(<div ref={root} role="menu" aria-label={`${name} 관리`} className="learning-space-menu" style={position} onKeyDown={event => {
      if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
      event.preventDefault()
      const items = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('button')]
      const index = items.indexOf(document.activeElement as HTMLButtonElement)
      items[event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length]?.focus()
    }}>
      <button type="button" role="menuitem" onClick={() => { close(); setMode('rename') }}><Icon name="pencil" /> 이름 변경</button>
      <button type="button" role="menuitem" onClick={() => { close(); void invoke('materials:reveal', { courseId: project.binding.courseId, relPath: project.binding.rootRelPath || '.' }).catch(error => showToast(learningError(error), 'danger')) }}><Icon name="folder" /> 폴더 열기</button>
      <button type="button" role="menuitem" onClick={() => { close(); setMode('delete') }}><Icon name="trash" /> 목록에서 삭제</button>
    </div>, document.body)}
    {mode && <LearningManageDialog project={project} mode={mode} name={name} onClose={() => setMode(null)} />}
  </>
}

function LearningManageDialog({ project, mode, name, onClose }: { project: LearningProjectSummary; mode: 'rename' | 'delete'; name: string; onClose: () => void }): JSX.Element {
  const [value, setValue] = useState(name)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const root = useRef<HTMLElement>(null)
  useFocusTrap(root, { active: true, onEscape: pending ? undefined : onClose })
  useEffect(() => acquirePointerPassthrough(), [])
  const submit = async (): Promise<void> => {
    setPending(true); setError(null)
    try {
      if (mode === 'rename') {
        await invoke('learning:rename', { binding: project.binding, name: value.trim() })
        await useCoursesStore.getState().loadCourses()
        notifyLearningChanged()
      } else {
        if (!await flushCourseNotes(project.binding.courseId)) throw new Error('저장하지 못한 필기가 있어요. 필기 저장을 마친 뒤 다시 삭제해 주세요.')
        const owner = useCoursesStore.getState().courses.find(course => course.id === project.binding.courseId)
        const standalone = owner?.workspaceKind === 'study-space' && project.binding.rootRelPath === ''
        if (!await useWorkspaceStore.getState().prepareCloseLearningSpace(project.binding, standalone)) throw new Error('열린 자료를 닫지 못했어요. 진행 중인 편집을 마친 뒤 다시 삭제해 주세요.')
        await invoke('learning:delete', { binding: project.binding })
        await useWorkspaceStore.getState().closeLearningSpace(project.binding, standalone)
        openLearningHome()
        await useCoursesStore.getState().loadCourses()
        openLearningHome()
        notifyLearningChanged()
        showToastWithAction(`${name}을(를) 목록에서 삭제했어요. 파일은 그대로 남아 있어요.`, { label: '삭제 취소', run: () => { void restoreLearningSpace(project).catch(caught => showToast(learningError(caught), 'danger')) } })
      }
      onClose()
    } catch (caught) { setError(learningError(caught)); setPending(false) }
  }
  return createPortal(<div className="dialog-backdrop" onMouseDown={event => { if (event.target === event.currentTarget && !pending) onClose() }}><section ref={root} className="course-dialog learning-manage-dialog" role={mode === 'delete' ? 'alertdialog' : 'dialog'} aria-modal="true" aria-label={mode === 'delete' ? '학습 공간을 목록에서 삭제' : '학습 공간 이름 변경'}>
    <h2>{mode === 'delete' ? '목록에서 삭제할까요?' : '학습 공간 이름 변경'}</h2>
    <form onSubmit={event => { event.preventDefault(); void submit() }}>
      {mode === 'rename' ? <label className="learning-field"><span>이름</span><input aria-label="이름" className="text-field" value={value} onChange={event => setValue(event.target.value)} autoFocus maxLength={120} required disabled={pending} /><small>폴더 이름과 저장된 기록은 바뀌지 않아요.</small></label> : <p><strong>{name}</strong>이(가) 학습 목록에서 사라집니다. 파일·원본 과목·학습 기록은 보존되며, ‘삭제한 학습’에서 복원할 수 있어요. 진행 중인 AI 작업은 취소됩니다.</p>}
      {error && <p className="learning-error" role="alert">{error}</p>}
      <footer className="dialog-actions"><button className="button button--secondary" type="button" disabled={pending} onClick={onClose}>취소</button><button className={`button button--${mode === 'delete' ? 'danger' : 'primary'}`} type="submit" disabled={pending || !value.trim()}>{pending ? '저장 중…' : mode === 'delete' ? '목록에서 삭제' : '이름 저장'}</button></footer>
    </form>
  </section></div>, document.body)
}
