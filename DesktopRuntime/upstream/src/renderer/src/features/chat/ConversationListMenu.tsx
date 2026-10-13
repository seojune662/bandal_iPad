import { useCallback, useEffect, useId, useRef, useState } from 'react'
import type { AgentProvider } from '../../../../shared/types/agent-events'
import type {
  ChatConversationSummary,
  ChatSurface
} from '../../../../shared/types/chat'
import { Icon } from '../../app/icons'
import { invoke } from '../../lib/ipc'

const PROVIDER_BADGES: Record<AgentProvider, string> = {
  'claude-code': 'Claude',
  codex: 'Codex',
  gemini: 'Gemini'
}

type LoadState = 'idle' | 'loading' | 'ready' | 'error'

export interface ConversationListMenuProps {
  courseId: string
  currentConversationId: string
  surface?: ChatSurface
  onNewConversation: () => void
  onOpenConversation: (conversationId: string) => void
}

function conversationTitle(conversation: ChatConversationSummary): string {
  return conversation.title?.trim() || '새 대화'
}

function HistoryIcon(): JSX.Element {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24">
      <g
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="1.75"
      >
        <path d="M3 12a9 9 0 1 0 3-6.7L3 8" />
        <path d="M3 3v5h5M12 7v5l3 2" />
      </g>
    </svg>
  )
}

function relativeTime(value: string | null): string {
  if (value === null) return ''
  const timestamp = new Date(value).getTime()
  if (!Number.isFinite(timestamp)) return ''

  const deltaMs = timestamp - Date.now()
  const absoluteMs = Math.abs(deltaMs)
  const minute = 60_000
  const hour = 60 * minute
  const day = 24 * hour
  const month = 30 * day
  const year = 365 * day

  if (absoluteMs < minute) return '방금 전'

  const formatter = new Intl.RelativeTimeFormat('ko', { numeric: 'always' })
  if (absoluteMs < hour) {
    return formatter.format(Math.round(deltaMs / minute), 'minute')
  }
  if (absoluteMs < day) {
    return formatter.format(Math.round(deltaMs / hour), 'hour')
  }
  if (absoluteMs < month) {
    return formatter.format(Math.round(deltaMs / day), 'day')
  }
  if (absoluteMs < year) {
    return formatter.format(Math.round(deltaMs / month), 'month')
  }
  return formatter.format(Math.round(deltaMs / year), 'year')
}

export function ConversationListMenu({
  courseId,
  currentConversationId,
  surface = 'app',
  onNewConversation,
  onOpenConversation
}: ConversationListMenuProps): JSX.Element {
  const [isOpen, setOpen] = useState(false)
  const [loadState, setLoadState] = useState<LoadState>('idle')
  const [conversations, setConversations] = useState<
    ChatConversationSummary[]
  >([])
  const [confirmingId, setConfirmingId] = useState<string | null>(null)
  const [deletingId, setDeletingId] = useState<string | null>(null)
  const [deleteError, setDeleteError] = useState<string | null>(null)
  const popoverId = useId()
  const rootRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const newConversationRef = useRef<HTMLButtonElement>(null)
  const confirmCancelRef = useRef<HTMLButtonElement>(null)
  const requestSerialRef = useRef(0)
  const mountedRef = useRef(true)

  const loadConversations = useCallback(async (): Promise<void> => {
    const requestSerial = ++requestSerialRef.current
    setLoadState('loading')
    try {
      const result = await invoke('chat:conversations', { courseId, surface })
      if (!mountedRef.current || requestSerial !== requestSerialRef.current) {
        return
      }
      setConversations(result.conversations)
      setLoadState('ready')
    } catch (error) {
      if (!mountedRef.current || requestSerial !== requestSerialRef.current) {
        return
      }
      console.error('[Bandal] 대화 목록을 불러오지 못했습니다.', error)
      setLoadState('error')
    }
  }, [courseId, surface])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      requestSerialRef.current += 1
    }
  }, [])

  useEffect(() => {
    if (!isOpen) {
      requestSerialRef.current += 1
      setConfirmingId(null)
      setDeleteError(null)
      return
    }
    void loadConversations()
  }, [isOpen, loadConversations])

  useEffect(() => {
    if (!isOpen) return

    const handlePointerDown = (event: MouseEvent): void => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false)
      }
    }
    const handleKeyDown = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      setOpen(false)
      triggerRef.current?.focus()
    }

    document.addEventListener('mousedown', handlePointerDown)
    document.addEventListener('keydown', handleKeyDown)
    return () => {
      document.removeEventListener('mousedown', handlePointerDown)
      document.removeEventListener('keydown', handleKeyDown)
    }
  }, [isOpen])

  useEffect(() => {
    if (isOpen) newConversationRef.current?.focus()
  }, [isOpen])

  useEffect(() => {
    if (confirmingId !== null) confirmCancelRef.current?.focus()
  }, [confirmingId])

  const handleNewConversation = (): void => {
    setOpen(false)
    onNewConversation()
  }

  const handleOpenConversation = (conversationId: string): void => {
    setOpen(false)
    onOpenConversation(conversationId)
  }

  const handleDelete = async (conversationId: string): Promise<void> => {
    setDeletingId(conversationId)
    setDeleteError(null)
    try {
      await invoke('chat:deleteConversation', {
        courseId,
        sessionId: conversationId
      })
      if (!mountedRef.current) return
      setConfirmingId(null)
      if (conversationId === currentConversationId) {
        setOpen(false)
        onNewConversation()
        return
      }
      await loadConversations()
    } catch (error) {
      if (!mountedRef.current) return
      console.error('[Bandal] 대화를 삭제하지 못했습니다.', error)
      setDeleteError('대화를 삭제하지 못했어요')
    } finally {
      if (mountedRef.current) setDeletingId(null)
    }
  }

  return (
    <div ref={rootRef} className="conversation-list">
      <button
        ref={triggerRef}
        type="button"
        className="conversation-list__trigger"
        aria-label="대화 목록"
        aria-expanded={isOpen}
        aria-haspopup="dialog"
        aria-controls={isOpen ? popoverId : undefined}
        onClick={() => setOpen((open) => !open)}
      >
        <HistoryIcon />
      </button>

      {isOpen && (
        <div
          id={popoverId}
          className="conversation-list__popover"
          role="dialog"
          aria-label="대화 목록"
        >
          <button
            ref={newConversationRef}
            type="button"
            className="conversation-list__new"
            onClick={handleNewConversation}
          >
            <Icon name="plus" />
            <span>새 대화</span>
          </button>
          <div className="conversation-list__separator" />

          {loadState === 'loading' && (
            <p className="conversation-list__status" role="status">
              대화를 불러오는 중…
            </p>
          )}
          {loadState === 'error' && (
            <div className="conversation-list__status" role="alert">
              <span>대화 목록을 불러오지 못했어요</span>
              <button type="button" onClick={() => void loadConversations()}>
                다시 시도
              </button>
            </div>
          )}
          {loadState === 'ready' && conversations.length === 0 && (
            <p className="conversation-list__status">아직 대화가 없어요</p>
          )}
          {loadState === 'ready' && conversations.length > 0 && (
            <ul className="conversation-list__items">
              {conversations.map((conversation) => {
                const title = conversationTitle(conversation)
                const timeLabel = relativeTime(conversation.lastUsedAt)
                const isCurrent = conversation.id === currentConversationId
                const isConfirming = confirmingId === conversation.id
                const isDeleting = deletingId === conversation.id

                return (
                  <li
                    key={conversation.id}
                    className="conversation-list__item"
                    data-current={isCurrent}
                    data-confirming={isConfirming}
                  >
                    {isConfirming ? (
                      <div
                        className="conversation-list__confirm"
                        role="group"
                        aria-label={`${title} 대화 삭제 확인`}
                      >
                        <span className="conversation-list__confirm-copy">
                          <strong title={title}>{title}</strong>
                          <span>삭제할까요?</span>
                        </span>
                        <span className="conversation-list__confirm-actions">
                          <button
                            ref={confirmCancelRef}
                            type="button"
                            disabled={isDeleting}
                            onClick={() => {
                              setConfirmingId(null)
                              setDeleteError(null)
                            }}
                          >
                            취소
                          </button>
                          <button
                            type="button"
                            className="conversation-list__confirm-delete"
                            disabled={isDeleting}
                            onClick={() => void handleDelete(conversation.id)}
                          >
                            {isDeleting ? '삭제 중…' : '삭제'}
                          </button>
                        </span>
                      </div>
                    ) : (
                      <>
                        <button
                          type="button"
                          className="conversation-list__conversation"
                          aria-current={isCurrent ? 'page' : undefined}
                          onClick={() =>
                            handleOpenConversation(conversation.id)
                          }
                        >
                          <span
                            className="conversation-list__title"
                            title={title}
                          >
                            {title}
                          </span>
                          <span className="conversation-list__meta">
                            <span className="conversation-list__provider">
                              {PROVIDER_BADGES[conversation.provider]}
                            </span>
                            {timeLabel !== '' && (
                              <time
                                dateTime={conversation.lastUsedAt ?? undefined}
                              >
                                {timeLabel}
                              </time>
                            )}
                          </span>
                        </button>
                        <button
                          type="button"
                          className="conversation-list__delete"
                          aria-label={`${title} 대화 삭제`}
                          onClick={() => {
                            setConfirmingId(conversation.id)
                            setDeleteError(null)
                          }}
                        >
                          <Icon name="trash" />
                        </button>
                      </>
                    )}
                  </li>
                )
              })}
            </ul>
          )}
          {deleteError !== null && (
            <p className="conversation-list__error" role="alert">
              {deleteError}
            </p>
          )}
        </div>
      )}
    </div>
  )
}
