/**
 * [C3] Agent event contract.
 *
 * Streaming events emitted by an AI-agent CLI session (Claude Code, Codex)
 * and forwarded to the renderer via the `chat:event-batch` push event.
 * This union is FROZEN for M1+ workstreams — extend, don't mutate.
 */

import type { ChatAttachment } from './chat'

export const AGENT_PROVIDERS = ['claude-code', 'codex', 'gemini'] as const
export type AgentProvider = (typeof AGENT_PROVIDERS)[number]

/** Ephemeral setup state. OAuth URLs and codes must never be persisted. */
export interface AgentLoginProgress {
  provider: AgentProvider
  requestId: string
  stage: 'starting' | 'waiting-browser' | 'verifying' | 'done' | 'error' | 'cancelled'
  message: string
  url?: string
  requiresCode?: boolean
}

export function isAgentProvider(value: unknown): value is AgentProvider {
  return AGENT_PROVIDERS.some((provider) => provider === value)
}

export type AgentErrorCode =
  | 'not-installed'
  | 'version-too-old'
  | 'not-logged-in'
  | 'spawn-failed'
  | 'process-crashed'
  | 'malformed-output'
  | 'usage-limit'
  | 'interrupted'
  | 'unknown'

export interface Usage {
  inputTokens: number
  outputTokens: number
  cacheReadTokens?: number
  cacheCreationTokens?: number
}

/** Compact summary of a tool result, safe to render in the chat timeline. */
export interface ToolResultSummary {
  /** Short human-readable one-liner (e.g. "Read 120 lines"). */
  summary: string
  /** Truncated raw output for expansion in the UI, if available. */
  preview?: string
  /** True when the full result was truncated into `preview`. */
  truncated?: boolean
}

/** A suggested response option for a permission request. */
export interface PermissionSuggestion {
  id: string
  label: string
  behavior: 'allow' | 'deny'
  /** When true, applies to future identical requests in this session. */
  remember?: boolean
}

export interface PermissionResponse {
  behavior: 'allow' | 'deny'
  /** Id of the chosen suggestion, when one was picked. */
  suggestionId?: string
  /** Persist as a permission grant for this course. */
  remember?: boolean
}

// ---------------------------------------------------------------------------
// AgentEvent union
// ---------------------------------------------------------------------------

export interface AgentSessionStartedEvent {
  type: 'session-started'
  sessionId: string
  model: string | null
  provider: AgentProvider
}

export interface AgentTextDeltaEvent {
  type: 'text-delta'
  blockId: string
  text: string
}

export interface AgentTextFinalEvent {
  type: 'text-final'
  blockId: string
  text: string
}

export interface AgentThinkingDeltaEvent {
  type: 'thinking-delta'
  blockId: string
  text: string
}

export interface AgentToolStartEvent {
  type: 'tool-start'
  toolCallId: string
  toolName: string
  /** Human-readable label (e.g. "Reading lecture-3.pdf"). */
  label: string
  input?: unknown
}

export interface AgentToolInputDeltaEvent {
  type: 'tool-input-delta'
  toolCallId: string
  partialInput: string
}

export interface AgentToolEndEvent {
  type: 'tool-end'
  toolCallId: string
  ok: boolean
  result?: ToolResultSummary
}

export interface AgentPermissionRequestEvent {
  type: 'permission-request'
  requestId: string
  toolName: string
  input: unknown
  suggestions?: PermissionSuggestion[]
}

export type TurnStopReason =
  | 'success'
  | 'max-turns'
  | 'budget'
  | 'interrupted'
  | 'error'

export interface AgentTurnCompleteEvent {
  type: 'turn-complete'
  stopReason: TurnStopReason
  usage?: Usage
  costUsd?: number
  durationMs?: number
}

export interface AgentUsageEvent {
  type: 'usage'
  usage: Usage
}

export interface AgentLimitEvent {
  type: 'limit'
  limitKind: 'rate' | 'usage'
  /** ISO datetime at which the limit resets, when known. */
  resetsAt?: string
  message: string
}

export interface AgentErrorEvent {
  type: 'error'
  code: AgentErrorCode
  message: string
  /** Fatal errors end the session; non-fatal ones end at most the turn. */
  fatal: boolean
}

export type AgentTurnFailure = Pick<AgentErrorEvent, 'code' | 'message'>

export type AgentEvent =
  | { type: 'turn-started'; turnSeq: number }
  | { type: 'permission-resolved'; requestId: string; behavior: 'allow' | 'deny' }
  | AgentSessionStartedEvent
  | AgentTextDeltaEvent
  | AgentTextFinalEvent
  | AgentThinkingDeltaEvent
  | AgentToolStartEvent
  | AgentToolInputDeltaEvent
  | AgentToolEndEvent
  | AgentPermissionRequestEvent
  | AgentTurnCompleteEvent
  | AgentUsageEvent
  | AgentLimitEvent
  | AgentErrorEvent

// ---------------------------------------------------------------------------
// Adapter interfaces (types only — implemented in main/features/agent later)
// ---------------------------------------------------------------------------

export interface AgentAvailability {
  installed: boolean
  version?: string
  loggedIn: boolean
  subscriptionType?: string
  /**
   * [v0.39] Signed-in account, when the CLI exposes one (gemini:
   * ~/.gemini/google_accounts.json). Absent for CLIs that don't say.
   */
  accountEmail?: string
  /**
   * Why the CLI is unavailable, when it is. `version-too-old` comes with
   * `installed: true` + the found `version`, so the setup UI can say
   * "update" instead of "install".
   */
  code?: AgentErrorCode
  /** Human-readable detail matching `code`, for the setup UI. */
  reason?: string
}

export interface AgentCapabilities {
  imageInput?: boolean
  resume?: boolean
  /** Can surface interactive permission prompts (vs. pre-approved only). */
  interactivePermissions: boolean
  /** Can accept additional user input while a turn is streaming. */
  streamingInput: boolean
  /** Emits partial text deltas (vs. only final blocks). */
  partialText: boolean
  /** Supports cancelling an in-flight turn. */
  cancel: boolean
}

export interface AgentStartSessionOptions {
  accessPolicy?: import('./aiAccess').AiAccessPolicy
  effort?: string
  selectedSkills?: string[]
  courseId: string
  /** Working directory for the CLI process (the course folder). */
  cwd: string
  model?: string
  /** Public provider search explicitly enabled for an isolated learning session. */
  webSearch?: 'live'
  /** Resume a previous CLI session when supported. */
  resumeCliSessionId?: string
  systemPromptAppend?: string
  /** Bandal's in-app MCP server config, so the agent can act on the app. */
  mcpConfigPath?: string
  /** Allow rules for those tools, e.g. `mcp__bandal__create_course`. */
  extraAllowedTools?: readonly string[]
  /**
   * The same in-app MCP server in raw form, for CLIs that take MCP config as
   * flags (codex `-c mcp_servers.*`) instead of a JSON config file.
   */
  mcpHttp?: { url: string; token: string }
  /** 사용자 MCP 서버용. 데스크톱 대화에서만 사용한다. */
  mcpExtraArgs?: string[]
  /** 사용자 MCP 서버용. 데스크톱 대화에서만 사용한다. */
  mcpExtraEnv?: Record<string, string>
}

export type Unsubscribe = () => void

export interface AgentSession {
  /** A terminal connection is replaced before the next send. */
  readonly closed?: boolean
  /** Resolves once the CLI reports its session id. */
  readonly sessionId: Promise<string>
  sendMessage(content: string, attachments?: readonly ChatAttachment[]): void
  /** Event stream: consume as an async iterable or subscribe with on(). */
  events: AsyncIterable<AgentEvent>
  on(cb: (event: AgentEvent) => void): Unsubscribe
  respondPermission(requestId: string, res: PermissionResponse): void
  /** Cancel the in-flight turn; the session stays usable. */
  cancel(): void
  /** Tear down the process and release resources. */
  dispose(): void
}

export interface AgentAdapter {
  readonly provider: AgentProvider
  readonly capabilities: AgentCapabilities
  checkAvailability(): Promise<AgentAvailability>
  startSession(opts: AgentStartSessionOptions): Promise<AgentSession>
}
