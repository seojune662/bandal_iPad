import { useEffect, useRef, useState, type FormEvent } from 'react'
import { TASK_COLORS } from '../../../../shared/types/board'
import type { TaskColor, TaskKind, TaskStatus } from '../../../../shared/types/board'
import { Icon } from '../../app/icons'
import './boardForms.css'

const STATUS_LABELS: Record<TaskStatus, string> = {
  todo: '할 일',
  'in-progress': '진행 중',
  done: '완료'
}

const KIND_LABELS: Record<TaskKind, string> = {
  task: '할 일',
  assignment: '과제',
  exam: '시험',
  class: '수업'
}

const COLOR_LABELS: Record<TaskColor, string> = {
  none: '색상 없음',
  red: '빨강',
  orange: '주황',
  yellow: '노랑',
  green: '초록',
  blue: '파랑',
  violet: '보라'
}

export interface BoardQuickAddDraft {
  title: string
  kind: TaskKind
  color: TaskColor
  dueDate: string
}

interface BoardQuickAddProps {
  status: TaskStatus
  active: boolean
  disabled: boolean
  onOpen: () => void
  onCancel: () => void
  onCreate: (draft: BoardQuickAddDraft) => Promise<void>
}

export function BoardQuickAdd({
  status,
  active,
  disabled,
  onOpen,
  onCancel,
  onCreate
}: BoardQuickAddProps): JSX.Element {
  const [title, setTitle] = useState('')
  const [kind, setKind] = useState<TaskKind>('task')
  const [color, setColor] = useState<TaskColor>('none')
  const [dueDate, setDueDate] = useState('')
  const [error, setError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (active) inputRef.current?.focus()
    if (!active) {
      setTitle('')
      setKind('task')
      setColor('none')
      setDueDate('')
      setError(null)
    }
  }, [active])

  if (!active) {
    return (
      <button
        type="button"
        className="board-column__add"
        aria-label={`${STATUS_LABELS[status]} 열에 추가`}
        disabled={disabled}
        onClick={onOpen}
      >
        <Icon name="plus" />
        추가
      </button>
    )
  }

  const submit = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault()
    if (title.trim().length === 0) {
      setError('제목을 입력해주세요.')
      return
    }
    setError(null)
    try {
      await onCreate({ title: title.trim(), kind, color, dueDate })
    } catch (submitError) {
      setError(
        submitError instanceof Error ? submitError.message : '항목을 추가하지 못했습니다.'
      )
    }
  }

  return (
    <form className="board-quick-add" onSubmit={(event) => void submit(event)}>
      <header className="board-quick-add__header">
        <strong>{STATUS_LABELS[status]}에 추가</strong>
        <button type="button" aria-label="추가 취소" onClick={onCancel}>
          <Icon name="x" />
        </button>
      </header>
      <label className="board-field">
        <span>제목</span>
        <input
          ref={inputRef}
          value={title}
          maxLength={200}
          required
          placeholder="무엇을 해야 하나요?"
          disabled={disabled}
          onChange={(event) => setTitle(event.target.value)}
        />
      </label>
      <fieldset className="board-kind-picker">
        <legend>종류</legend>
        <div>
          {Object.entries(KIND_LABELS).map(([value, label]) => (
            <label key={value}>
              <input
                type="radio"
                name={`board-kind-${status}`}
                value={value}
                checked={kind === value}
                disabled={disabled}
                onChange={() => setKind(value as TaskKind)}
              />
              <span>{label}</span>
            </label>
          ))}
        </div>
      </fieldset>
      <label className="board-field">
        <span>마감일 <small>선택 · 날짜만 고르면 하루 종일</small></span>
        <input
          type="date"
          value={dueDate}
          disabled={disabled}
          onChange={(event) => setDueDate(event.target.value)}
        />
      </label>
      <fieldset className="board-color-picker">
        <legend>색상</legend>
        <div>
          {TASK_COLORS.map((value) => (
            <label key={value} title={COLOR_LABELS[value]}>
              <input
                type="radio"
                name={`board-color-${status}`}
                value={value}
                checked={color === value}
                disabled={disabled}
                aria-label={COLOR_LABELS[value]}
                onChange={() => setColor(value)}
              />
              <span data-color={value} aria-hidden="true">
                {value === 'none' ? '×' : ''}
              </span>
            </label>
          ))}
        </div>
      </fieldset>
      {error !== null && <p className="board-quick-add__error" role="alert">{error}</p>}
      <footer className="board-quick-add__actions">
        <button type="button" className="board-button" disabled={disabled} onClick={onCancel}>
          취소
        </button>
        <button type="submit" className="board-button board-button--primary" disabled={disabled}>
          {disabled ? '추가 중…' : '추가'}
        </button>
      </footer>
    </form>
  )
}
