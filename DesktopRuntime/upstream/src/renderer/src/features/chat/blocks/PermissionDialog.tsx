/** Compact fallback for an explicitly restricted access setting. */

import { useEffect, useRef } from 'react'
import type { PermissionResponse } from '../../../../../shared/types/agent-events'
import type { PermissionBlockView } from '../chatModel'
import { confirmationCopy } from '../confirmationCopy'

export interface PermissionDialogProps {
  block: PermissionBlockView
  /** True when this request is the one currently blocking the turn. */
  isActive: boolean
  autoFocusReject?: boolean
  shouldAutoFocusReject?: () => boolean
  responseState?: 'pending' | 'error' | undefined
  onRespond: (requestId: string, response: PermissionResponse) => void
}

export function PermissionDialog({
  block,
  isActive,
  autoFocusReject = false,
  shouldAutoFocusReject,
  onRespond,
  responseState
}: PermissionDialogProps): JSX.Element | null {
  const rejectButtonRef = useRef<HTMLButtonElement>(null)
  const isPending = block.behavior === undefined && isActive
  const { title, description } = confirmationCopy(block.toolName)

  useEffect(() => {
    if (
      !isPending ||
      !autoFocusReject ||
      shouldAutoFocusReject?.() === false
    ) {
      return
    }
    rejectButtonRef.current?.focus()
  }, [block.id, isPending, autoFocusReject, shouldAutoFocusReject])

  if (!isPending) return null

  return (
    <div className="chat-permission" role="group" aria-label="도구 실행 허용 요청">
      <div className="chat-permission__head"><strong>{title}</strong></div>
      <p className="chat-permission__description">{description}</p>
      {responseState === 'error' && <p role="alert">응답을 보내지 못했어요. 다시 선택해 주세요.</p>}
      {responseState === 'pending' && <p role="status">응답을 보내는 중…</p>}
      <fieldset className="chat-permission__actions" disabled={responseState === 'pending'}>
        <button
          ref={rejectButtonRef}
          type="button"
          className="chat-permission__btn chat-permission__btn--deny"
          data-approval-safe-action="true"
          onClick={() => onRespond(block.id, { behavior: 'deny' })}
        >
          취소
        </button>
        <button
          type="button"
          className="chat-permission__btn chat-permission__btn--allow"
          onClick={() => onRespond(block.id, { behavior: 'allow' })}
        >
          계속
        </button>

      </fieldset>
    </div>
  )
}
