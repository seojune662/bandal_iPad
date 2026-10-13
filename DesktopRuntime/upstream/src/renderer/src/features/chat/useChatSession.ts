import type { ChatContext } from '../../../../shared/types/chatCapabilities'
import { useCallback, useEffect } from 'react'
import type {
  AgentAvailability,
  AgentProvider,
  PermissionResponse
} from '../../../../shared/types/agent-events'
import type {
  AgentModelOption,
  ChatAttachment,
  ChatSurface
} from '../../../../shared/types/chat'
import type { ChatViewState } from './chatModel'
import {
  acquireChatSession,
  cancelChatTurn,
  dismissChatNotice,
  refreshChatSession,
  respondToChatPermission,
  selectChatSession,
  sendChatMessage,
  setChatProvider,
  setChatModel,
  setChatConfiguration,
  useChatSessionStore,
} from './chatSessionStore'

export interface ChatSessionApi {
  state: ChatViewState
  phase: 'loading' | 'ready' | 'error'
  provider: AgentProvider
  availability: AgentAvailability | null
  openError: string | null
  models: AgentModelOption[]
  effort?: string | null
  configurationError?: string | null
  configuring?: boolean
  permissionResponses?: Record<string, 'pending' | 'error'>
  setConfiguration: (model: string, effort: string | null) => Promise<void>
  /** Conversation title (first user message). Null until the first send. */
  title: string | null
  send: (content: string, attachments?: ChatAttachment[], context?: ChatContext) => Promise<void>
  cancel: () => void
  respondPermission: (
    requestId: string,
    response: PermissionResponse
  ) => void
  refresh: () => void
  dismissNotice: () => void
  setModel: (model: string) => void
  /**
   * Switches provider in place: the conversation keeps its id and history;
   * the new CLI gets the prior transcript on its next turn.
   */
  setProvider: (provider: AgentProvider) => void
}

export function useChatSession(
  courseId: string,
  conversationId: string,
  surface: ChatSurface = 'app'
): ChatSessionApi {
  const snapshot = useChatSessionStore(
    useCallback(
      (store) => store.sessions[conversationId] ?? selectChatSession(conversationId),
      [conversationId]
    )
  )

  useEffect(
    () => acquireChatSession(courseId, conversationId, surface),
    [courseId, conversationId, surface]
  )

  const send = useCallback(
    (content: string, attachments?: ChatAttachment[], context?: ChatContext) => {
      return sendChatMessage(courseId, conversationId, content, attachments, context)
    },
    [courseId, conversationId]
  )
  const cancel = useCallback(
    () => cancelChatTurn(courseId, conversationId),
    [courseId, conversationId]
  )
  const respondPermission = useCallback(
    (requestId: string, response: PermissionResponse) => {
      respondToChatPermission(courseId, conversationId, requestId, response)
    },
    [courseId, conversationId]
  )
  const refresh = useCallback(
    () => refreshChatSession(courseId, conversationId),
    [courseId, conversationId]
  )
  const dismissNotice = useCallback(
    () => dismissChatNotice(courseId, conversationId),
    [courseId, conversationId]
  )
  const setModel = useCallback(
    (model: string) => setChatModel(courseId, conversationId, model),
    [courseId, conversationId]
  )
  const setProvider = useCallback(
    (provider: AgentProvider) => {
      void setChatProvider(courseId, conversationId, provider)
    },
    [courseId, conversationId]
  )

  return {
    ...snapshot,
    send,
    cancel,
    respondPermission,
    refresh,
    dismissNotice,
    setModel,
    setConfiguration: (model, effort) => setChatConfiguration(courseId, conversationId, model, effort),
    setProvider
  }
}
