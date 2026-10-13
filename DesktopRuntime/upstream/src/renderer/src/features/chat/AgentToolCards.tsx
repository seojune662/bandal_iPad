import { useEffect, useRef, useState } from 'react'
import type {
  AgentAction,
  AgentConfirmScope,
  AgentConfirmRequest,
  AgentTurnChanges
} from '../../../../shared/types/agentTools'
import { Icon } from '../../app/icons'
import { confirmationCopy, isInternalExecution } from './confirmationCopy'
import { BrowserIcon } from '../browser/browserIcons'
import type {
  AgentToolActivityItem,
  AgentUndoState
} from './agentToolActivityStore'

export function agentConfirmResponseLabel(approved: boolean): string {
  return approved ? '승인함' : '거부함'
}

export function agentConfirmScopeLabel(scope: AgentConfirmScope): string {
  switch (scope) {
    case 'once':
      return '이번만'
    case 'site':
      return '이 사이트'
    case 'course':
      return '이 과목 전체'
    case 'conversation':
      return '이 대화에서는 계속'
    case 'always':
      return '30일 동안 묻지 않기'
  }
}

export function agentActionUndoLabel(action: AgentAction): string | null {
  if (!action.undoable) {
    return '되돌릴 수 없음'
  }
  return action.undoneAt === null ? null : '되돌림'
}

export function agentTurnUndoButtonLabel(
  actions: readonly AgentAction[],
  undoState: AgentUndoState
): string {
  if (undoState === 'pending') {
    return '되돌리는 중…'
  }
  if (undoState === 'error') {
    return '되돌리기 다시 시도'
  }
  if (actions.some((action) => action.undoable && action.undoneAt === null)) {
    return '되돌리기'
  }
  return actions.some((action) => action.undoable)
    ? '되돌림'
    : '되돌릴 항목 없음'
}

export interface AgentConfirmCardProps {
  resolution?: 'pending' | 'approved' | 'denied' | 'expired' | 'cancelled' | undefined
  request: AgentConfirmRequest
  response: boolean | null
  isResponding?: boolean
  hasResponseError?: boolean
  autoFocusReject?: boolean
  shouldAutoFocusReject?: () => boolean
  onRespond: (
    requestId: string,
    approved: boolean,
    scope?: AgentConfirmScope
  ) => void
}

function confirmationSubject(request: AgentConfirmRequest): string {
  if (!request.tool.startsWith('browser_')) {
    return request.summary
  }

  const origin = request.summary.match(
    /^https?:\/\/([^/\s]+?)(?=\s*(?:에서|에)\s)/
  )?.[1]
  return origin ?? request.summary
}

function ConfirmationIcon({ tool }: { tool: string }): JSX.Element {
  if (tool.startsWith('browser_')) {
    return <BrowserIcon name="lock" />
  }
  return <Icon name={tool.startsWith('delete_') ? 'trash' : 'pencil'} />
}

export function AgentConfirmCard({
  request,
  response,
  isResponding = false,
  hasResponseError = false,
  autoFocusReject = false,
  shouldAutoFocusReject,
  onRespond,
  resolution
}: AgentConfirmCardProps): JSX.Element {
  const [selection, setSelection] = useState<{ requestId: string; scope: AgentConfirmScope }>({ requestId: request.requestId, scope: 'once' })
  const scope = selection.requestId === request.requestId ? selection.scope : 'once'
  const isPending = response === null
  const internalExecution = isInternalExecution(request.tool)
  const copy = confirmationCopy(request.tool)
  const summary = internalExecution ? copy.title : request.summary
  const details = internalExecution ? [copy.description] : request.details
  const kindLabel = confirmKindLabel(request.tool)
  const severity = request.tool === 'browser_access' ? 'quiet' : 'danger'
  const rejectButtonRef = useRef<HTMLButtonElement>(null)

  useEffect(() => {
    if (
      !isPending ||
      !autoFocusReject ||
      shouldAutoFocusReject?.() === false
    ) {
      return
    }
    rejectButtonRef.current?.focus()
  }, [
    request.requestId,
    isPending,
    autoFocusReject,
    shouldAutoFocusReject
  ])

  if (!isPending) {
    const subject = internalExecution ? copy.title : confirmationSubject(request)
    const responseLabel =
      resolution === 'expired' ? '시간 초과' : resolution === 'cancelled' ? '취소됨' : response && request.tool === 'browser_access'
        ? '허용함'
        : agentConfirmResponseLabel(response)

    return (
      <article
        className="chat-agent-confirm"
        aria-label={`${kindLabel}: ${subject} · ${responseLabel}`}
        data-resolved="true"
        data-severity={severity}
      >
        <span className="chat-agent-confirm__icon">
          <ConfirmationIcon tool={request.tool} />
        </span>
        <span
          className="chat-agent-confirm__subject"
          title={subject}
        >
          {subject}
        </span>
        <span className="chat-agent-confirm__separator" aria-hidden="true">
          ·
        </span>
        <span
          className="chat-agent-confirm__badge"
          data-approved={response}
        >
          {responseLabel}
        </span>
      </article>
    )
  }

  return (
    <article
      className="chat-agent-confirm"
      aria-label={kindLabel}
      data-severity={severity}
    >
      <header className="chat-agent-confirm__header">
        <span className="chat-agent-confirm__icon">
          <ConfirmationIcon tool={request.tool} />
        </span>
        <div className="chat-agent-confirm__heading">
          <span className="chat-agent-confirm__eyebrow">
            {kindLabel}
          </span>
          <h3 className="chat-agent-confirm__summary" title={summary}>
            {summary}
          </h3>
        </div>
      </header>

      {details.length > 0 && <ul className="chat-confirm-details">{details.map((detail, index) => <li key={index}>{detail}</li>)}</ul>}

      {isResponding && (
        <p className="chat-agent-confirm__notice" role="status">
          응답을 보내는 중…
        </p>
      )}
      {hasResponseError && (
        <p className="chat-agent-confirm__error" role="alert">
          응답을 보내지 못했어요. 다시 선택해 주세요.
        </p>
      )}
      <div className="chat-agent-confirm__actions">
        <button
          ref={rejectButtonRef}
          type="button"
          className="chat-agent-confirm__button chat-agent-confirm__button--reject"
          data-approval-safe-action="true"
          disabled={isResponding}
          onClick={() => onRespond(request.requestId, false)}
        >
          거절
        </button>
        {request.scopes && request.scopes.length > 1 && <select aria-label="허용 범위" value={request.scopes.includes(scope) ? scope : request.scopes[0]} disabled={isResponding} onChange={(event) => setSelection({ requestId: request.requestId, scope: event.target.value as AgentConfirmScope })}>
          {request.scopes.map((option) => <option value={option} key={option}>{agentConfirmScopeLabel(option)}</option>)}
        </select>}
        <button type="button" className="chat-agent-confirm__button chat-agent-confirm__button--approve" disabled={isResponding} onClick={() => onRespond(request.requestId, true, request.scopes ? request.scopes.includes(scope) ? scope : request.scopes[0] : undefined)}>
          {scope === 'once' ? '계속' : '허용'}
        </button>
      </div>
    </article>
  )
}

/**
 * Asking for access to a school site is not a destructive change, and calling
 * it one trains the student to click through the label rather than read it.
 */
function confirmKindLabel(tool: string): string {
  switch (tool) {
    case 'browser_access':
      return '사이트 접근 허용'
    case 'browser_submit':
      return '제출 확인'
    case 'browser_use_saved_login':
      return '저장된 로그인 사용'
    default:
      return tool.startsWith('desktop_') ? '화면 접근 확인' : tool.startsWith('delete_') ? '삭제 확인' : '작업 실행 확인'
  }
}

export interface AgentTurnChangesCardProps {
  changes: AgentTurnChanges
  undoState?: AgentUndoState
  onUndo: (turnId: string) => void
}

export function AgentTurnChangesCard({
  changes,
  undoState = 'idle',
  onUndo
}: AgentTurnChangesCardProps): JSX.Element | null {
  if (changes.actions.length === 0) {
    return null
  }

  const canUndo = changes.actions.some(
    (action) => action.undoable && action.undoneAt === null
  )
  const hasUndoneAction = changes.actions.some(
    (action) => action.undoable && action.undoneAt !== null
  )

  return (
    <article className="chat-turn-changes" aria-label="이번에 바꾼 것">
      <header className="chat-turn-changes__header">
        <h3>이번에 바꾼 것</h3>
        <span>{changes.actions.length}개</span>
      </header>

      <ul className="chat-turn-changes__list">
        {changes.actions.map((action) => {
          const undoLabel = agentActionUndoLabel(action)
          return (
            <li key={action.id} className="chat-turn-changes__item">
              <span className="chat-turn-changes__label">{action.label}</span>
              {undoLabel !== null && (
                <span
                  className="chat-turn-changes__status"
                  data-undoable={action.undoable}
                >
                  {undoLabel}
                </span>
              )}
            </li>
          )
        })}
      </ul>

      {(undoState === 'complete' || (!canUndo && hasUndoneAction)) && (
        <p className="chat-turn-changes__notice" role="status">
          되돌릴 수 있는 변경을 되돌렸어요.
        </p>
      )}
      {undoState === 'error' && (
        <p className="chat-turn-changes__error" role="alert">
          변경을 되돌리지 못했어요.
        </p>
      )}

      <div className="chat-turn-changes__actions">
        <button
          type="button"
          className="chat-turn-changes__undo"
          disabled={undoState === 'pending' || !canUndo}
          onClick={() => onUndo(changes.turnId)}
        >
          {agentTurnUndoButtonLabel(changes.actions, undoState)}
        </button>
      </div>
    </article>
  )
}

export interface AgentToolActivityProps {
  items: readonly AgentToolActivityItem[]
  onRespondConfirm: (
    requestId: string,
    approved: boolean,
    scope?: AgentConfirmScope
  ) => void
  onUndoTurn: (turnId: string) => void
  shouldAutoFocusReject?: () => boolean
}

function activeConfirmationId(
  items: readonly AgentToolActivityItem[]
): string | null {
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index]
    if (item?.kind === 'confirmation' && item.response === null) {
      return item.request.requestId
    }
  }
  return null
}

export function AgentToolActivity({
  items,
  onRespondConfirm,
  onUndoTurn,
  shouldAutoFocusReject
}: AgentToolActivityProps): JSX.Element {
  const activeRequestId = activeConfirmationId(items)

  return (
    <>
      {items.map((item) =>
        item.kind === 'confirmation' ? (
          <AgentConfirmCard
            key={`confirmation:${item.request.requestId}`}
            request={item.request}
            response={item.response}
            resolution={item.resolution}
            isResponding={item.isResponding}
            hasResponseError={item.hasResponseError}
            autoFocusReject={item.request.requestId === activeRequestId}
            {...(shouldAutoFocusReject === undefined
              ? {}
              : { shouldAutoFocusReject })}
            onRespond={onRespondConfirm}
          />
        ) : (
          <AgentTurnChangesCard
            key={`changes:${item.turnId}`}
            changes={{ turnId: item.turnId, actions: item.actions }}
            undoState={item.undoState}
            onUndo={onUndoTurn}
          />
        )
      )}
    </>
  )
}
