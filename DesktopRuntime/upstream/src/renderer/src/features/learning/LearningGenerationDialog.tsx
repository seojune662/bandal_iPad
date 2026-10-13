import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from '../../app/icons'
import { useUiStore } from '../../stores/uiStore'
import { useFocusTrap } from '../../components/useFocusTrap'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { LearningGenerationForm, type LearningGenerationRequest } from './LearningGenerationForm'

export type { LearningGenerationChoice, LearningGenerationRequest } from './LearningGenerationForm'

/** Standalone shell; the study palette uses the same validated form in place. */
export function LearningGenerationDialog({ request, onClose }: { request: LearningGenerationRequest; onClose: () => void }): JSX.Element {
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const [pending, setPending] = useState(false)
  const root = useRef<HTMLElement>(null)
  const id = useId()
  useFocusTrap(root, { active: !settingsOpen, onEscape: pending ? undefined : onClose })
  useEffect(() => { if (!settingsOpen) return acquirePointerPassthrough() }, [settingsOpen])
  return createPortal(<div className="dialog-backdrop" style={settingsOpen ? { display: 'none' } : undefined} onMouseDown={event => { if (event.target === event.currentTarget && !pending) onClose() }}>
    <section className="course-dialog learning-create learning-create--form" ref={root} role="dialog" aria-modal="true" aria-labelledby={id}>
      <header className="course-dialog__header"><h2 id={id}>{request.label} {request.entry.kind === 'plugin-command' ? '실행' : '만들기'}</h2><button className="bare-icon-button" type="button" aria-label="닫기" disabled={pending} onClick={onClose}><Icon name="x" /></button></header>
      <LearningGenerationForm request={request} onClose={onClose} onPendingChange={setPending} />
    </section>
  </div>, document.body)
}
