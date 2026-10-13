import { useEffect, useId, useRef, useState } from 'react'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import {
  COURSE_COLORS,
  courseColorLabel,
  type CourseColor
} from './courseColors'

/**
 * - `create`: 새 과목 만들기 — Bandal creates a managed folder.
 * - `link`:   폴더에서 추가 — an existing folder on disk becomes the course.
 * - `rename`: 이름만 바꾼다 (색상·폴더는 그대로).
 */
type CourseFormMode = 'create' | 'link' | 'rename'

interface CourseFormDialogProps {
  open: boolean
  mode: CourseFormMode
  initialName?: string
  initialColor?: CourseColor
  /** Absolute folder path shown in `link` mode. */
  folderPath?: string | undefined
  onClose: () => void
  onSubmit: (name: string, color: CourseColor) => Promise<void>
}

const TITLES: Record<CourseFormMode, string> = {
  create: '새 과목',
  link: '폴더에서 추가',
  rename: '과목 이름 변경'
}

const SUBMIT_LABELS: Record<CourseFormMode, string> = {
  create: '과목 만들기',
  link: '과목으로 추가',
  rename: '변경하기'
}

function messageFrom(error: unknown): string {
  return error instanceof Error ? error.message : '저장하지 못했습니다.'
}

export function CourseFormDialog({
  open,
  mode,
  initialName = '',
  initialColor = 'gold',
  folderPath,
  onClose,
  onSubmit
}: CourseFormDialogProps): JSX.Element | null {
  const [name, setName] = useState(initialName)
  const [color, setColor] = useState<CourseColor>(initialColor)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const dialogRef = useRef<HTMLElement>(null)
  const titleId = useId()
  const errorId = useId()
  const inputId = useId()
  const showsColor = mode !== 'rename'

  useFocusTrap(dialogRef, {
    active: open,
    initialFocus: inputRef,
    onEscape: pending ? undefined : onClose
  })

  useEffect(() => {
    if (!open) return
    setName(initialName)
    setColor(initialColor)
    setError(null)
    setPending(false)
  }, [initialColor, initialName, open])

  if (!open) return null

  const submit = async (event: React.FormEvent): Promise<void> => {
    event.preventDefault()
    const normalizedName = name.trim()
    if (normalizedName.length === 0) {
      setError('과목 이름을 입력해주세요.')
      inputRef.current?.focus()
      return
    }

    setPending(true)
    setError(null)
    try {
      await onSubmit(normalizedName, color)
      onClose()
    } catch (submitError) {
      setError(messageFrom(submitError))
      setPending(false)
    }
  }

  return (
    <div
      className="dialog-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !pending) onClose()
      }}
    >
      <section
        ref={dialogRef}
        className="course-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <header className="course-dialog__header">
          <div>
            <p className="eyebrow">COURSE</p>
            <h2 id={titleId}>{TITLES[mode]}</h2>
          </div>
          <button
            type="button"
            className="bare-icon-button"
            aria-label="닫기"
            disabled={pending}
            onClick={onClose}
          >
            <Icon name="x" />
          </button>
        </header>

        <form onSubmit={(event) => void submit(event)}>
          {mode === 'link' && folderPath !== undefined && (
            <div className="folder-preview">
              <span className="field-label">폴더</span>
              <p className="folder-preview__path" title={folderPath}>
                <Icon name="folder" />
                <span>{folderPath}</span>
              </p>
              <p className="folder-preview__hint">
                이 폴더의 파일이 자료 사이드바에 그대로 나타나요. 폴더는 옮기거나
                복사하지 않아요.
              </p>
            </div>
          )}

          <label className="field-label" htmlFor={inputId}>
            이름
          </label>
          <input
            ref={inputRef}
            id={inputId}
            className="text-field"
            value={name}
            placeholder="과목 이름"
            autoComplete="off"
            aria-describedby={error === null ? undefined : errorId}
            aria-invalid={error !== null}
            disabled={pending}
            onChange={(event) => setName(event.target.value)}
          />

          {showsColor && (
            <fieldset className="color-fieldset">
              <legend className="field-label">색상</legend>
              <div className="color-palette">
                {COURSE_COLORS.map((option) => (
                  <button
                    key={option}
                    type="button"
                    className="color-swatch"
                    data-course-color={option}
                    data-selected={color === option}
                    aria-label={courseColorLabel(option)}
                    aria-pressed={color === option}
                    disabled={pending}
                    onClick={() => setColor(option)}
                  >
                    <span className="color-swatch__fill" />
                  </button>
                ))}
              </div>
            </fieldset>
          )}

          {error !== null && (
            <p id={errorId} className="form-error" role="alert">
              {error}
            </p>
          )}

          <footer className="dialog-actions">
            <button
              type="button"
              className="button button--secondary"
              disabled={pending}
              onClick={onClose}
            >
              취소
            </button>
            <button
              type="submit"
              className="button button--primary"
              disabled={pending}
            >
              {pending ? '저장 중…' : SUBMIT_LABELS[mode]}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}

interface ArchiveCourseDialogProps {
  courseName: string | null
  pending: boolean
  error: string | null
  onClose: () => void
  onConfirm: () => Promise<void>
}

export function ArchiveCourseDialog({
  courseName,
  pending,
  error,
  onClose,
  onConfirm
}: ArchiveCourseDialogProps): JSX.Element | null {
  const titleId = useId()
  const dialogRef = useRef<HTMLElement>(null)

  useFocusTrap(dialogRef, {
    active: courseName !== null,
    onEscape: pending ? undefined : onClose
  })

  if (courseName === null) return null

  return (
    <div
      className="dialog-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !pending) onClose()
      }}
    >
      <section
        ref={dialogRef}
        className="course-dialog course-dialog--confirm"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <div className="confirm-dialog__icon" aria-hidden="true">
          <Icon name="archive" />
        </div>
        <h2 id={titleId}>과목을 보관할까요?</h2>
        <p>
          <strong>{courseName}</strong> 과목이 목록에서 숨겨집니다. 자료와 기록은
          그대로 남고, 나중에 설정에서 복원할 수 있어요.
        </p>
        {error !== null && (
          <p className="confirm-dialog__error" role="alert">
            {error}
          </p>
        )}
        <footer className="dialog-actions">
          <button
            type="button"
            className="button button--secondary"
            disabled={pending}
            onClick={onClose}
          >
            취소
          </button>
          <button
            type="button"
            className="button button--primary"
            disabled={pending}
            onClick={() => void onConfirm()}
          >
            {pending ? '보관 중…' : '보관'}
          </button>
        </footer>
      </section>
    </div>
  )
}

interface DeleteCourseDialogProps {
  courseName: string | null
  pending: boolean
  error: string | null
  onClose: () => void
  onConfirm: () => Promise<void>
}

export function DeleteCourseDialog({
  courseName,
  pending,
  error,
  onClose,
  onConfirm
}: DeleteCourseDialogProps): JSX.Element | null {
  const titleId = useId()
  const dialogRef = useRef<HTMLElement>(null)

  useFocusTrap(dialogRef, {
    active: courseName !== null,
    onEscape: pending ? undefined : onClose
  })

  if (courseName === null) return null

  return (
    <div
      className="dialog-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !pending) onClose()
      }}
    >
      <section
        ref={dialogRef}
        className="course-dialog course-dialog--confirm"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <div className="confirm-dialog__icon" aria-hidden="true">
          <Icon name="trash" />
        </div>
        <h2 id={titleId}>과목을 삭제할까요?</h2>
        <p>
          <strong>{courseName}</strong> 과목이 목록에서 사라집니다. 자료 폴더는
          디스크에 그대로 남습니다.
        </p>
        {error !== null && (
          <p className="confirm-dialog__error" role="alert">
            {error}
          </p>
        )}
        <footer className="dialog-actions">
          <button
            type="button"
            className="button button--secondary"
            disabled={pending}
            onClick={onClose}
          >
            취소
          </button>
          <button
            type="button"
            className="button button--danger"
            disabled={pending}
            onClick={() => void onConfirm()}
          >
            {pending ? '삭제 중…' : '삭제'}
          </button>
        </footer>
      </section>
    </div>
  )
}
