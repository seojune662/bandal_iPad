import { useId, useRef } from 'react'
import type { MaterialNode } from '../../../../shared/types/materials'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'

interface MaterialDeleteDialogProps {
  target: MaterialNode | null
  pending: boolean
  error: string | null
  onClose: () => void
  onConfirm: () => Promise<void>
}

export function MaterialDeleteDialog({
  target,
  pending,
  error,
  onClose,
  onConfirm
}: MaterialDeleteDialogProps): JSX.Element | null {
  const titleId = useId()
  const descriptionId = useId()
  const dialogRef = useRef<HTMLElement>(null)

  useFocusTrap(dialogRef, {
    active: target !== null,
    onEscape: pending ? undefined : onClose
  })

  if (target === null) return null

  return (
    <div
      className="dialog-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !pending) onClose()
      }}
    >
      <section
        ref={dialogRef}
        className="course-dialog course-dialog--confirm material-delete-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={descriptionId}
      >
        <div className="confirm-dialog__icon" aria-hidden="true">
          <Icon name="trash" />
        </div>
        <h2 id={titleId}>삭제할까요?</h2>
        <p id={descriptionId}>
          <strong>{target.name}</strong>을(를) 휴지통으로 이동합니다.
          컴퓨터의 휴지통에서 다시 복구할 수 있습니다.
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
            {pending ? '이동 중…' : '휴지통으로 이동'}
          </button>
        </footer>
      </section>
    </div>
  )
}
