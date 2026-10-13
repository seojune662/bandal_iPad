import { useEffect, useId, useRef, useState } from 'react'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'

type CourseGroupNameMode = 'create' | 'rename'

interface CourseGroupNameDialogProps {
  open: boolean
  mode: CourseGroupNameMode
  initialName?: string
  onClose: () => void
  onSubmit: (name: string) => Promise<void>
}

function messageFrom(error: unknown): string {
  return error instanceof Error ? error.message : '저장하지 못했습니다.'
}

export function CourseGroupNameDialog({
  open,
  mode,
  initialName = '',
  onClose,
  onSubmit
}: CourseGroupNameDialogProps): JSX.Element | null {
  const [name, setName] = useState(initialName)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const dialogRef = useRef<HTMLElement>(null)
  const titleId = useId()
  const inputId = useId()
  const errorId = useId()

  useFocusTrap(dialogRef, {
    active: open,
    initialFocus: inputRef,
    onEscape: pending ? undefined : onClose
  })

  useEffect(() => {
    if (!open) return
    setName(initialName)
    setPending(false)
    setError(null)
  }, [initialName, mode, open])

  if (!open) return null

  const submit = async (event: React.FormEvent): Promise<void> => {
    event.preventDefault()
    const normalizedName = name.trim()
    if (normalizedName.length === 0) {
      setError('그룹 이름을 입력해주세요.')
      inputRef.current?.focus()
      return
    }

    setPending(true)
    setError(null)
    try {
      await onSubmit(normalizedName)
      onClose()
    } catch (submitError) {
      setError(messageFrom(submitError))
      setPending(false)
    }
  }

  const title = mode === 'create' ? '새 그룹 만들기' : '그룹 이름 변경'
  const submitLabel = mode === 'create' ? '그룹 만들기' : '변경하기'

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
            <p className="eyebrow">COURSE GROUP</p>
            <h2 id={titleId}>{title}</h2>
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
          <label className="field-label" htmlFor={inputId}>
            이름
          </label>
          <input
            ref={inputRef}
            id={inputId}
            className="text-field"
            value={name}
            placeholder="그룹 이름"
            autoComplete="off"
            aria-describedby={error === null ? undefined : errorId}
            aria-invalid={error !== null}
            disabled={pending}
            onChange={(event) => setName(event.target.value)}
          />

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
              {pending ? '저장 중…' : submitLabel}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}

interface DeleteCourseGroupDialogProps {
  groupName: string | null
  onClose: () => void
  onConfirm: () => Promise<void>
}

export function DeleteCourseGroupDialog({
  groupName,
  onClose,
  onConfirm
}: DeleteCourseGroupDialogProps): JSX.Element | null {
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const dialogRef = useRef<HTMLElement>(null)
  const titleId = useId()

  useFocusTrap(dialogRef, {
    active: groupName !== null,
    onEscape: pending ? undefined : onClose
  })

  useEffect(() => {
    if (groupName === null) return
    setPending(false)
    setError(null)
  }, [groupName])

  if (groupName === null) return null

  const confirm = async (): Promise<void> => {
    setPending(true)
    setError(null)
    try {
      await onConfirm()
      onClose()
    } catch (confirmError) {
      setError(messageFrom(confirmError))
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
        className="course-dialog course-dialog--confirm"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <div className="confirm-dialog__icon" aria-hidden="true">
          <Icon name="trash" />
        </div>
        <h2 id={titleId}>그룹을 삭제할까요?</h2>
        <p>
          <strong>{groupName}</strong>
        </p>
        <p>그룹만 사라지고 과목은 삭제되지 않아요.</p>
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
            onClick={() => void confirm()}
          >
            {pending ? '삭제 중…' : '그룹 삭제'}
          </button>
        </footer>
      </section>
    </div>
  )
}
