import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { MaterialNode } from '../../../../shared/types/materials'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'

export function LearningMaterialImportDialog({ files, relPath, pending, onSelect, onClose, onPreview }: {
  files: MaterialNode[]; relPath: string; pending: boolean
  onSelect: (relPath: string) => void; onClose: () => void; onPreview: () => void
}): JSX.Element {
  const root = useRef<HTMLElement>(null)
  const select = useRef<HTMLSelectElement>(null)
  useFocusTrap(root, { active: true, initialFocus: select, onEscape: pending ? undefined : onClose })
  useEffect(() => acquirePointerPassthrough(), [])
  return createPortal(<div className="dialog-backdrop" onMouseDown={event => { if (event.target === event.currentTarget && !pending) onClose() }}><section ref={root} className="course-dialog learning-create" role="dialog" aria-modal="true" aria-label="기존 학습 자료 가져오기">
    <header className="course-dialog__header"><h2>기존 Markdown 자료 가져오기</h2><button className="bare-icon-button" type="button" aria-label="닫기" disabled={pending} onClick={onClose}><Icon name="x" /></button></header>
    <p className="learning-muted">단어장과 예문, 퀴즈와 카드 표를 학습 자료로 바꿉니다. 저장 전 미리보기를 확인할 수 있어요.</p>
    <label className="learning-field"><span>변환할 자료</span><select ref={select} value={relPath} disabled={pending} onChange={event => onSelect(event.target.value)}><option value="">자료 선택</option>{files.map(file => <option value={file.relPath} key={file.relPath}>{file.relPath}</option>)}</select></label>
    {files.length === 0 && <p className="learning-muted" role="status">이 과목의 Markdown 자료가 없어요.</p>}
    <footer className="dialog-actions"><button type="button" className="button button--secondary" disabled={pending} onClick={onClose}>취소</button><button type="button" className="button button--primary" disabled={pending || !relPath} onClick={onPreview}>{pending ? '미리보기 준비 중…' : '변환 미리보기 만들기'}</button></footer>
  </section></div>, document.body)
}
