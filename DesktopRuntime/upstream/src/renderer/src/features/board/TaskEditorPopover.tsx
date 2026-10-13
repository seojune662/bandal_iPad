import { useFocusTrap } from '../../components/useFocusTrap'
import { createPortal } from 'react-dom'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { useEffect, useRef, useState, type CSSProperties, type FormEvent } from 'react'
import { TASK_COLORS } from '../../../../shared/types/board'
import type { BoardTask, TaskColor, TaskKind } from '../../../../shared/types/board'
import type { Course } from '../../../../shared/types/course'
import { Icon } from '../../app/icons'
import { normalizeCourseColor } from '../courses/courseColors'
import { TaskScheduleFields, useTaskSchedule } from '../calendar/TaskScheduleFields'
import './boardForms.css'

const KIND_LABELS: Record<TaskKind, string> = {
  task: '할 일',
  assignment: '과제',
  exam: '시험',
  class: '수업'
}

const COLOR_LABELS: Record<TaskColor, string> = {
  none: '없음',
  red: '빨강',
  orange: '주황',
  yellow: '노랑',
  green: '초록',
  blue: '파랑',
  violet: '보라'
}

export interface TaskEditorDraft {
  title: string
  notes: string
  kind: TaskKind
  color: TaskColor
  startAt: string | null
  dueAt: string | null
  allDay: boolean
  courseId: string | null
}

interface TaskEditorPopoverProps {
  task: BoardTask
  courses: Course[]
  anchorStyle: CSSProperties
  onClose: () => void
  onSave: (draft: TaskEditorDraft) => Promise<void>
  onDelete: () => Promise<void>
}

export function TaskEditorPopover({
  task,
  courses,
  anchorStyle,
  onClose,
  onSave,
  onDelete
}: TaskEditorPopoverProps): JSX.Element {
  const popoverRef = useRef<HTMLDivElement>(null)
  useViewportBounds(popoverRef)
  useFocusTrap(popoverRef, { active: true, onEscape: onClose })
  const [title, setTitle] = useState(task.title)
  const [notes, setNotes] = useState(task.notes)
  const [kind, setKind] = useState<TaskKind>(task.kind)
  const [color, setColor] = useState<TaskColor>(task.color)
  const schedule = useTaskSchedule(task)
  const [courseId, setCourseId] = useState(task.courseId ?? '')
  const [isSaving, setIsSaving] = useState(false)
  const [localError, setLocalError] = useState<string | null>(null)

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      popoverRef.current?.querySelector<HTMLInputElement>('#board-task-title')?.focus()
    })
    const closeOnPointerDown = (event: PointerEvent): void => {
      if (!popoverRef.current?.contains(event.target as Node)) onClose()
    }
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('pointerdown', closeOnPointerDown)
    window.addEventListener('keydown', closeOnEscape)
    return () => {
      window.cancelAnimationFrame(frame)
      window.removeEventListener('pointerdown', closeOnPointerDown)
      window.removeEventListener('keydown', closeOnEscape)
    }
  }, [onClose])

  const submit = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault()
    const normalizedTitle = title.trim()
    if (normalizedTitle.length === 0) {
      setLocalError('제목을 입력해주세요.')
      return
    }

    setIsSaving(true)
    setLocalError(null)
    try {
      await onSave({
        title: normalizedTitle,
        notes,
        kind,
        color,
        ...schedule.value(),
        courseId: courseId.length === 0 ? null : courseId
      })
      onClose()
    } catch (error) {
      setLocalError(
        error instanceof Error ? error.message : '태스크를 저장하지 못했습니다.'
      )
    } finally {
      setIsSaving(false)
    }
  }

  const remove = async (): Promise<void> => {
    setIsSaving(true)
    setLocalError(null)
    try {
      await onDelete()
    } catch (error) {
      setLocalError(
        error instanceof Error ? error.message : '태스크를 삭제하지 못했습니다.'
      )
    } finally {
      setIsSaving(false)
    }
  }

  const currentCourseMissing =
    task.courseId !== null && !courses.some((course) => course.id === task.courseId)

  return createPortal(
    <div
      ref={popoverRef}
      className="board-editor"
      role="dialog"
      aria-modal="false"
      aria-labelledby="board-editor-heading"
      style={anchorStyle}
    >
      <form onSubmit={(event) => void submit(event)}>
        <header className="board-editor__header">
          <div>
            <p className="board-eyebrow">TASK DETAILS</p>
            <h3 id="board-editor-heading">태스크 편집</h3>
          </div>
          <button
            type="button"
            className="board-icon-button"
            aria-label="편집 닫기"
            onClick={onClose}
          >
            <Icon name="x" />
          </button>
        </header>

        <label className="board-field" htmlFor="board-task-title">
          <span>제목</span>
          <input
            id="board-task-title"
            value={title}
            maxLength={200}
            required
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
                  name={`board-editor-kind-${task.id}`}
                  value={value}
                  checked={kind === value}
                  onChange={() => setKind(value as TaskKind)}
                />
                <span>{label}</span>
              </label>
            ))}
          </div>
        </fieldset>

        <fieldset className="board-color-picker">
          <legend>색상</legend>
          <div>
            {TASK_COLORS.map((value) => (
              <label key={value} title={COLOR_LABELS[value]}>
                <input
                  type="radio"
                  name={`board-editor-color-${task.id}`}
                  value={value}
                  checked={color === value}
                  onChange={() => setColor(value)}
                />
                <span data-color={value}>
                  {value === 'none' && <b aria-hidden="true">×</b>}
                  <span className="sr-only">{COLOR_LABELS[value]}</span>
                </span>
              </label>
            ))}
          </div>
        </fieldset>

        <label className="board-field" htmlFor="board-task-notes">
          <span>메모</span>
          <textarea
            id="board-task-notes"
            value={notes}
            rows={5}
            placeholder="준비할 내용이나 참고사항을 적어보세요"
            onChange={(event) => setNotes(event.target.value)}
          />
        </label>

        <TaskScheduleFields schedule={schedule} />

        <label className="board-field" htmlFor="board-task-course">
          <span>과목</span>
          <div className="board-course-select">
            {courseId.length > 0 && (
              <span
                className="board-course-dot"
                data-course-color={normalizeCourseColor(
                  courses.find((course) => course.id === courseId)?.color ?? courseId
                )}
                aria-hidden="true"
              />
            )}
            <select
              id="board-task-course"
              value={courseId}
              onChange={(event) => setCourseId(event.target.value)}
            >
              <option value="">전체 태스크</option>
              {currentCourseMissing && (
                <option value={task.courseId ?? ''}>목록에 없는 과목</option>
              )}
              {courses.map((course) => (
                <option key={course.id} value={course.id}>
                  {course.name}
                </option>
              ))}
            </select>
          </div>
        </label>

        {localError !== null && (
          <p className="board-editor__error" role="alert">
            {localError}
          </p>
        )}

        <footer className="board-editor__footer">
          <button
            type="button"
            className="board-button board-button--danger"
            disabled={isSaving}
            onClick={() => void remove()}
          >
            <Icon name="trash" />
            삭제
          </button>
          <div className="board-editor__actions">
            <button
              type="button"
              className="board-button"
              disabled={isSaving}
              onClick={onClose}
            >
              취소
            </button>
            <button
              type="submit"
              className="board-button board-button--primary"
              disabled={isSaving}
            >
              {isSaving ? '저장 중…' : '저장'}
            </button>
          </div>
        </footer>
      </form>
    </div>,
    document.body
  )
}
