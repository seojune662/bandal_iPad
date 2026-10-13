import { useMaterialContext } from './ContextChips'
import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type ReactNode
} from 'react'
import type { AgentProvider } from '../../../../shared/types/agent-events'
import type {
  ChatAttachment,
  ChatSurface as ChatSurfaceKind
} from '../../../../shared/types/chat'
import { Icon } from '../../app/icons'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'
import {
  formatQuoteBlock,
  useChatPromptStore,
  type ChatQuote
} from './chatPromptBus'
import { Composer, type ComposerHandle } from './Composer'
import { ModelMenu } from './ModelMenu'
import { updateComposerDraft, useComposerDraft } from './composerDraftStore'
import type { ChatContext } from '../../../../shared/types/chatCapabilities'
import { ConversationListMenu } from './ConversationListMenu'
import { MessageList } from './MessageList'
import { useChatSession } from './useChatSession'
import { isAgentConnectionReady } from './agentConnectionStore'
import {
  AgentApprovalRail,
  hasVisibleAgentToolActivity
} from './AgentApprovalRail'
import { AgentToolActivity } from './AgentToolCards'
import {
  useAgentToolActivity,
  type AgentToolActivityItem
} from './agentToolActivityStore'
import {
  AgentSetupCard,
  GateCard,
} from './AgentSetupCards'
import { PermissionDialog } from './blocks/PermissionDialog'
import type { MessageView, PermissionBlockView } from './chatModel'
import './chat.css'
import './chat-blocks.css'
import './agent-setup.css'
import './conversation-list.css'
import './chat-refresh.css'
import { BandalMark } from '../../components/BandalMark'

const SCROLL_PIN_THRESHOLD_PX = 48
const approvalTitleOwners = new Set<symbol>()

const STARTER_PROMPTS = [
  '이번 주 강의자료를 요약해줘',
  '내 필기에서 빠진 개념이 있는지 봐줘',
  '시험에 나올 만한 핵심 내용을 뽑아줘'
]

function pendingPermissionBlock(
  messages: readonly MessageView[],
  requestId: string | null
): PermissionBlockView | null {
  if (requestId === null) {
    return null
  }
  for (const message of messages) {
    const block = message.blocks.find(
      (candidate): candidate is PermissionBlockView =>
        candidate.kind === 'permission' &&
        candidate.id === requestId &&
        candidate.behavior === undefined
    )
    if (block !== undefined) {
      return block
    }
  }
  return null
}

export function syncApprovalDocumentTitle(
  owner: symbol,
  pending: boolean
): void {
  if (typeof document === 'undefined') {
    return
  }
  if (pending) {
    approvalTitleOwners.add(owner)
  } else {
    approvalTitleOwners.delete(owner)
  }
  if (approvalTitleOwners.size > 0) {
    if (!document.title.startsWith('● ')) {
      document.title = `● ${document.title}`
    }
    return
  }
  document.title = document.title.replace(/^● /, '')
}

function isPendingConfirmation(
  item: AgentToolActivityItem
): boolean {
  return item.kind === 'confirmation' && item.response === null
}

export interface ChatSurfaceProps {
  courseId: string
  /** Conversation identity shared by the sidebar and expanded tab. */
  conversationId?: string
  variant?: 'tab' | 'sidebar'
  sourcePanelId?: string | undefined
  active?: boolean
  surface?: ChatSurfaceKind
  onOpenConversation?: (conversationId: string) => void
  headerExtra?: ReactNode
  hideHeader?: boolean

}

function EmptyState({
  courseId,
  sourcePanelId,
  onPick,
  variant
}: {
  onPick: (prompt: string) => void
  variant: 'tab' | 'sidebar'
  sourcePanelId?: string | undefined
  courseId: string
}): JSX.Element {
  const { snapshot } = useMaterialContext(courseId, sourcePanelId)
  return (
    <div className="chat-empty">
      <BandalMark size={56} className="chat-empty__moon" motion="periodic" />
      <h2 className="chat-empty__title">
        {variant === 'sidebar' ? '이 자료, 함께 살펴볼까요?' : snapshot?.courseName ? `${snapshot.courseName}, 함께 공부해요` : '무엇이 궁금한가요?'}
      </h2>
      <p className="chat-empty__desc">{snapshot?.material ? `${snapshot.material.title}${snapshot.material.page ? ` ${snapshot.material.page}쪽` : ''}을 함께 보고 있어요.` : '강의자료를 읽고 필기도 도와줘요.'}</p>
      <div className="chat-empty__chips">
        {(variant === 'sidebar' ? ['핵심 내용 요약해줘', '어려운 개념 쉽게 설명해줘', '이 자료로 연습문제 만들어줘'] : STARTER_PROMPTS).map((prompt) => (
          <button
            key={prompt}
            type="button"
            className="chat-empty__chip"
            onClick={() => onPick(prompt)}
          >
            {prompt}
          </button>
        ))}
      </div>
    </div>
  )
}

/** 담을 수 있는 인용 칩 수 — 초과 시 오래된 것부터 밀려난다. */
const MAX_PENDING_QUOTES = 5

/**
 * 전송 본문 합성: 인용 블록들 + 빈 줄 + 사용자가 친 텍스트.
 * 칩은 UI 표현일 뿐이고 세션에는 지금까지와 같은 마크다운이 간다.
 */
export function composeOutgoingText(
  draft: string,
  quotes: readonly ChatQuote[]
): string {
  const trimmed = draft.trim()
  if (quotes.length === 0) return trimmed
  const blocks = quotes.map(formatQuoteBlock).join('\n\n')
  return trimmed === '' ? blocks : `${blocks}\n\n${trimmed}`
}

export function ChatSurface({
  courseId,
  conversationId,
  variant = 'tab',
  surface = 'app',
  onOpenConversation,
  headerExtra,
  hideHeader = false,
  sourcePanelId,
  active = true
}: ChatSurfaceProps): JSX.Element {
  const nativeSurface = typeof window !== 'undefined' && !!window.bandal && window.bandal.platform !== 'web'
  const conversationKey = conversationId ?? courseId
  const session = useChatSession(courseId, conversationKey, surface)
  const agentToolActivity = useAgentToolActivity(conversationKey)
  const openTab = useWorkspaceStore((store) => store.openTab)
  const composerDraft = useComposerDraft(conversationKey)
  const draft = composerDraft.text
  const setDraft = useCallback((value: string | ((current: string) => string)) => {
    updateComposerDraft(conversationKey, (current) => ({ text: typeof value === 'function' ? value(current.text) : value }))
  }, [conversationKey])
  const pendingQuotes = composerDraft.quotes ?? []
  const setPendingQuotes = useCallback((update: ChatQuote[] | ((quotes: ChatQuote[]) => ChatQuote[])) => {
    updateComposerDraft(conversationKey, current => ({ quotes: typeof update === 'function' ? update(current.quotes ?? []) : update }))
  }, [conversationKey])
  const composerRef = useRef<ComposerHandle>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const isPinnedRef = useRef(true)
  const [showScrollToLatest, setShowScrollToLatest] = useState(false)
  const approvalTitleOwnerRef = useRef(Symbol('chat-approval'))

  const { state, phase, provider, availability, models } = session
  const pendingPrompt = useChatPromptStore((store) => store.pending)
  const consumePrompt = useChatPromptStore((store) => store.consume)
  const pendingPermission = pendingPermissionBlock(
    state.messages,
    state.pendingPermissionId
  )
  const pendingAgentConfirmations = agentToolActivity.items.filter(
    isPendingConfirmation
  )
  const historicalAgentToolItems = agentToolActivity.items.filter(
    (item) => item.kind === 'changes'
  )
  const hasPendingApprovals =
    pendingPermission !== null || pendingAgentConfirmations.length > 0


  useEffect(() => {
    const owner = approvalTitleOwnerRef.current
    syncApprovalDocumentTitle(owner, hasPendingApprovals)
    return () => syncApprovalDocumentTitle(owner, false)
  }, [hasPendingApprovals])

  useEffect(() => {
    if (
      pendingPrompt === null ||
      pendingPrompt.conversationId !== conversationKey
    ) {
      return
    }
    const payload = consumePrompt(conversationKey)
    if (payload === null) return
    if (payload.text !== undefined) setDraft(payload.text)
    if (payload.quote !== undefined) {
      const quote = payload.quote
      setPendingQuotes((current) =>
        [...current, quote].slice(-MAX_PENDING_QUOTES)
      )
    }
    composerRef.current?.focus()
  }, [pendingPrompt, consumePrompt, conversationKey, setDraft])

  useEffect(() => {
    const scroller = scrollRef.current
    if (scroller !== null && isPinnedRef.current) {
      scroller.scrollTop = scroller.scrollHeight
    }
  }, [state.messages, agentToolActivity.items])

  const handleScroll = useCallback(() => {
    const scroller = scrollRef.current
    if (scroller === null) {
      return
    }
    const distance =
      scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight
    isPinnedRef.current = distance < SCROLL_PIN_THRESHOLD_PX
    setShowScrollToLatest(!isPinnedRef.current)
  }, [])

  const handleSend = useCallback(
    async (attachments: ChatAttachment[], context?: ChatContext) => {
      const text = composeOutgoingText(draft, pendingQuotes)
      if (text === '' && attachments.length === 0 && !context) {
        return
      }
      isPinnedRef.current = true
      setShowScrollToLatest(false)
      await session.send(text, attachments, { ...context, ...(sourcePanelId ? { sourcePanelId } : {}) })
    },
    [draft, pendingQuotes, session.send, setDraft, sourcePanelId]
  )

  const removeQuote = useCallback((index: number) => {
    setPendingQuotes((current) =>
      current.filter((_, position) => position !== index)
    )
  }, [])

  const handlePickStarter = useCallback((prompt: string) => {
    setDraft(prompt)
    composerRef.current?.focus()
  }, [setDraft])

  const handleOpenConversation = useCallback(
    (nextConversationId: string) => {
      if (onOpenConversation !== undefined) {
        onOpenConversation(nextConversationId)
        return
      }
      openTab(
        descriptorFor('chat', {
          courseId,
          conversationId: nextConversationId,
          ...(sourcePanelId ? { sourcePanelId } : {})
        })
      )
    },
    [courseId, onOpenConversation, openTab, sourcePanelId]
  )

  const handleNewConversation = useCallback(() => {
    handleOpenConversation(crypto.randomUUID())
  }, [handleOpenConversation])

  const handleProviderChange = useCallback(
    (nextProvider: AgentProvider) => {
      if (nextProvider !== provider) updateComposerDraft(conversationKey, { skills: [], creation: null })
      session.setProvider(nextProvider)
    },
    [session.setProvider, provider, conversationKey]
  )

  const root = (children: ReactNode): JSX.Element => (
    <div
      className="chat-tab"
      data-variant={variant}
      data-tour="assistant-panel"
    >
      {children}
    </div>
  )

  if (phase === 'loading') {
    return root(
      <div className="chat-loading" role="status" aria-label="불러오는 중">
        <BandalMark size={56} className="chat-loading__moon" />
      </div>
    )
  }

  if (phase === 'error') {
    return root(
      <GateCard
        eyebrow="ERROR"
        title="채팅을 열지 못했어요"
        onRefresh={session.refresh}
      >
        <p className="chat-gate__desc">{session.openError}</p>
      </GateCard>
    )
  }

  if (availability !== null && !isAgentConnectionReady(availability) && !state.streaming && !hasPendingApprovals) {
    if (availability.installed && availability.loggedIn && availability.code !== 'version-too-old') {
      return root(<GateCard eyebrow="ERROR" title="AI 연결을 확인하지 못했어요" onRefresh={session.refresh}><p className="chat-gate__desc">{availability.reason ?? '연결 상태를 다시 확인해 주세요.'}</p></GateCard>)
    }
    return root(
      <AgentSetupCard
        provider={provider}
        availability={availability}
        onProviderChange={handleProviderChange}
        onRefresh={session.refresh}
      />
    )
  }

  const hasAgentToolCards = hasVisibleAgentToolActivity(
    historicalAgentToolItems
  )
  const isEmpty = state.messages.length === 0 && !hasAgentToolCards
  const selectorControls = (
    <>
      <ConversationListMenu
        courseId={courseId}
        currentConversationId={conversationKey}
        surface={surface}
        onNewConversation={handleNewConversation}
        onOpenConversation={handleOpenConversation}
      />
    </>
  )

  return root(
    <>
        {!hideHeader && <header className="chat-header">
          {headerExtra}
          {selectorControls}
        </header>}
      {state.notice !== null && (
        <div
          className="chat-banner chat-banner--error"
          role={state.notice.fatal ? 'alert' : 'status'}
        >
          <span>{state.notice.message}</span>
          {['not-installed', 'not-logged-in', 'version-too-old', 'spawn-failed'].includes(state.notice.code) && <button type="button" className="chat-gate__refresh" onClick={session.refresh}>연결 다시 확인</button>}
          <button
            type="button"
            className="chat-banner__dismiss"
            aria-label="알림 닫기"
            onClick={session.dismissNotice}
          >
            <Icon name="x" />
          </button>
        </div>
      )}
      <div className="chat-reading-area">
      <div
        ref={scrollRef}
        className="chat-scroll"
        data-has-approval-rail={hasAgentToolCards || undefined}
        onScroll={handleScroll}
      >
        {isEmpty ? (
          <EmptyState variant={variant} sourcePanelId={sourcePanelId} courseId={courseId} onPick={handlePickStarter} />
        ) : (
          <>
            <MessageList
              renderActivity={(turnSeq, isLast) => {
                const items = historicalAgentToolItems.filter((item) => {
                  const turnId = item.turnId
                  return turnId && turnSeq !== undefined ? turnId === `${conversationKey}:${turnSeq}` : isLast
                })
                return hasVisibleAgentToolActivity(items) ? <details className="chat-approval-history"><summary>작업 기록</summary><AgentApprovalRail items={items} onRespondConfirm={agentToolActivity.respondConfirm} onUndoTurn={agentToolActivity.undoTurn} /></details> : null
              }}
              streaming={state.streaming}
              messages={state.messages}
              pendingPermissionId={state.pendingPermissionId}
              dockedPermissionId={pendingPermission?.id ?? null}
              onRespondPermission={session.respondPermission}
            />
          </>
        )}
      </div>
      {showScrollToLatest && <button type="button" className="chat-scroll-to-latest" aria-label="최신 답변으로 이동" onClick={() => {
        isPinnedRef.current = true
        setShowScrollToLatest(false)
        const scroller = scrollRef.current
        if (scroller) scroller.scrollTop = scroller.scrollHeight
      }}><svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true"><path d="M10 3v13m-5-5 5 5 5-5" /></svg></button>}
      </div>
      {(active && hasPendingApprovals) && (
        <div
          className="chat-approval-dock"
          role="region"
          aria-live="polite"
          aria-label="승인 요청"
        >
          <div className="chat-approval-dock__content">
            {pendingAgentConfirmations.length + (pendingPermission ? 1 : 0) > 1 && <p className="chat-menu-note">확인할 항목 {pendingAgentConfirmations.length + (pendingPermission ? 1 : 0)}개</p>}
            {pendingPermission !== null && (
              <PermissionDialog
                block={pendingPermission}
                isActive
                autoFocusReject={false}
                responseState={session.permissionResponses?.[pendingPermission.id]}
                shouldAutoFocusReject={() => false}
                onRespond={session.respondPermission}
              />
            )}
            {pendingAgentConfirmations.length > 0 && (
              <AgentToolActivity
                items={pendingPermission ? [] : pendingAgentConfirmations.slice(0, 1)}
                onRespondConfirm={agentToolActivity.respondConfirm}
                onUndoTurn={agentToolActivity.undoTurn}
                shouldAutoFocusReject={() => false}
              />
            )}
          </div>
        </div>
      )}
      <Composer
        ref={composerRef}
        sourcePanelId={sourcePanelId}
        courseId={courseId}
        conversationId={conversationKey}
        provider={provider}
        screenAvailable={nativeSurface}
        modelControl={<ModelMenu provider={provider} models={models} model={state.model} effort={session.effort ?? null} disabled={state.streaming || hasPendingApprovals} saving={session.configuring ?? false} error={session.configurationError ?? null} onProvider={handleProviderChange} onChange={session.setConfiguration} />}
        value={draft}
        quotes={pendingQuotes}
        onRemoveQuote={removeQuote}
        onChange={setDraft}
        onSend={handleSend}
        onCancel={session.cancel}
        isStreaming={state.streaming}
        isWaitingPermission={hasPendingApprovals}
        limit={state.limit}
        disabled={false}
      />
    </>
  )
}
