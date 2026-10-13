/**
 * Chat domain types: persisted message history and session metadata for a
 * course's AI-agent chat.
 */

import type { AgentAvailability, AgentProvider } from './agent-events'

export type MessageRole = 'user' | 'assistant'

export type ChatSurface = 'app' | 'desktop' | 'study'

export type MessageBlockKind =
  | 'text'
  | 'thinking'
  | 'tool'
  | 'permission'
  | 'notice'
  | 'artifact'

/** One ordered block within a message (text, thinking, tool call, ...). */
export interface MessageBlock {
  id: string
  messageId: string
  ord: number
  kind: MessageBlockKind
  /** Kind-specific payload, persisted as JSON. */
  payload: unknown
}

/** How much of the prior transcript was handed to a freshly switched provider. */
export interface CarryoverStats {
  messages: number
  chars: number
  truncated: boolean
}

/**
 * Payload of a `notice` block: a system line persisted in the thread when the
 * provider changed mid-conversation (the new CLI got the prior transcript
 * prepended to its first prompt).
 */
export interface ProviderSwitchNotice {
  kind: 'provider-switch'
  from: AgentProvider
  to: AgentProvider
  carried: CarryoverStats
}

export interface ChatMessage {
  id: string
  courseId: string
  sessionId: string
  role: MessageRole
  turnSeq: number
  blocks: MessageBlock[]
  createdAt: string
}

export type AgentSessionStatus = 'idle' | 'running' | 'error' | 'closed'

export interface ChatSessionInfo {
  accessPolicy?: import('./aiAccess').AiAccessPolicy
  id: string
  courseId: string
  surface: ChatSurface
  provider: AgentProvider
  /** Session id assigned by the CLI, for resuming. */
  cliSessionId: string | null
  model: string | null
  effort?: string | null
  status: AgentSessionStatus
  lastUsedAt: string | null
  /** First user message, collapsed to one line (≤60 chars). Null until sent. */
  title: string | null
}

/**
 * One conversation in a course's conversation list. A conversation IS an
 * `agent_sessions` row; rows with zero messages are never listed (a tab that
 * was opened but never used leaves no visible trace).
 */
export interface ChatConversationSummary {
  id: string
  courseId: string
  surface: ChatSurface
  provider: AgentProvider
  title: string | null
  model: string | null
  lastUsedAt: string | null
  createdAt: string
  messageCount: number
}

export interface ChatOpenResult {
  eventSeq?: number
  pendingPermissions?: import('./agent-events').AgentPermissionRequestEvent[]
  history: ChatMessage[]
  sessionInfo: ChatSessionInfo | null
  availability: AgentAvailability
}

/**
 * An image pasted or dropped into the composer. Sent inline to the CLI as a
 * base64 content block and persisted inside the user text block's payload
 * (`images: ChatAttachment[]`) — no new message_blocks kind, no migration.
 */
export interface ChatAttachment {
  /** e.g. 'image/png'. Only image/* is accepted. */
  mediaType: string
  /** Raw base64, WITHOUT the `data:...;base64,` prefix. */
  dataBase64: string
}

export interface ChatSendInput {
  context?: import('./chatCapabilities').ChatContext
  courseId: string
  /** Conversation id (renderer-minted uuid; becomes agent_sessions.id). */
  sessionId: string
  content: string
  attachments?: ChatAttachment[]
}

/** One model offered by the CLI's `list_models` probe. */
export interface AgentModelOption {
  id: string
  displayName: string
  /** True for the CLI's own default when no --model is passed. */
  isDefault: boolean
  resolvedModel?: string
  supportedEfforts?: string[]
  defaultEffort?: string
}

/** Discovery is a list of candidates; account access is checked by the provider at execution. */
export interface AgentModelCatalog {
  models: AgentModelOption[]
  source: 'live' | 'cache' | 'fallback'
  status: 'ready' | 'unverified' | 'unavailable'
  fetchedAt?: string
  /** Catalog writer's CLI version, when supplied by cache metadata. */
  cliVersion?: string
  error?: string
  blockedModelIds?: string[]
}
