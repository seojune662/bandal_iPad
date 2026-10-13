import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { launchNewLearning } from './learningActions'

export function LearningStartActions({ onChoose }: { onChoose?: () => void }): JSX.Element {
  const options = [
    { kind: 'english', title: '영어 글 읽기', detail: '관심 주제로 글을 찾고, 읽으며 표현을 모아요.', symbol: 'Aa' },
    { kind: 'quiz', title: '퀴즈 만들기', detail: '내 자료로 문제를 만들고 직접 풀어봐요.', symbol: '?' },
    { kind: 'flashcards', title: '카드 만들기', detail: '내 자료의 내용을 카드로 만들어 복습해요.', symbol: '▤' }
  ] as const
  return <div className="learning-start-actions">{options.map(option => <button className="learning-start-action" type="button" key={option.kind} onClick={() => { onChoose?.(); launchNewLearning(option.kind) }}><span aria-hidden="true" className="learning-start-symbol">{option.symbol}</span><span><strong>{option.title}</strong><small>{option.detail}</small></span><Icon name="chevronRight" /></button>)}</div>
}

export function NewLearningDialog({ onClose }: { onClose: () => void }): JSX.Element {
  const root = useRef<HTMLElement>(null)
  useFocusTrap(root, { active: true, onEscape: onClose })
  useEffect(() => acquirePointerPassthrough(), [])
  return createPortal(<div className="dialog-backdrop" onMouseDown={event => { if (event.target === event.currentTarget) onClose() }}><section ref={root} className="course-dialog learning-start-dialog" role="dialog" aria-modal="true" aria-label="새 학습"><header className="course-dialog__header"><h2>어떤 학습을 시작할까요?</h2><button type="button" className="bare-icon-button" aria-label="닫기" onClick={onClose}><Icon name="x" /></button></header><LearningStartActions onChoose={onClose} /></section></div>, document.body)
}
