import type { BrowserPageEvent } from '../types/browserNative'
import type { BrowserAuthStatus } from '../types/browserAuth'
/**
 * Push events: main → renderer, one-way, delivered via webContents.send and
 * subscribed through `window.bandal.on(channel, cb)`.
 */

import type { SettingsCategoryId } from '../settingsCategories'
import type { RecordingEvent, SpeechModelState } from '../recording'
import type { AgentEvent, AgentLoginProgress, AgentProvider } from '../types/agent-events'
import type { AgentConfirmRequest } from '../types/agentTools'
import type { Settings } from '../types/settings'
import type { AuthState } from '../types/auth'
import type { UpdateStatus } from '../types/update'
import type { PipState } from '../types/pip'
import type { PluginSummary } from '../types/plugin'
import type { WorkflowPackSummary } from '../types/workflowPack'
import type {
  ScreenPermissionState
} from '../types/screenCapture'

/** Ordered batch of streaming agent events for ONE conversation. */
export interface ChatEventBatch {
  /** Course identity, alongside the independent conversation identity. */
  courseId: string
  /** Conversation id (agent_sessions.id) this batch belongs to. */
  sessionId: string
  /** Monotonic per-conversation sequence number for ordering / gap detection. */
  seq: number
  events: AgentEvent[]
}

/**
 * Progress lines from a provider CLI installer (`agent:install`). `done`
 * marks the terminal frame; `ok` is only meaningful once done is true.
 */
export interface AgentInstallProgress {
  provider: string
  line: string
  done: boolean
  ok: boolean
}


/** Fired when the course folder changed on disk (watcher). */
export interface MaterialsChanged {
  courseId: string
}

/**
 * [M3-F] A browser guest asked for a new window (window.open / target=_blank).
 * Main denies the native window and forwards the URL here; the renderer opens
 * it as a new Bandal browser tab.
 */
export interface BrowserOpenUrl {
  /** In-memory ownership of a managed AI sign-in tab. Never saved to layout. */
  loginRequestId?: string
  loginProvider?: AgentProvider
  /** Existing Chromium page to adopt without replaying its navigation. */
  tabId?: string
  openerTabId?: string
  courseId?: string | null
  url: string
  /** Popups and links inherit the opener tab's browsing session. */
  isPrivate?: boolean
  profileId?: string
  /** Originating guest, when the event must be routed back to its tab. */
  webContentsId?: number
  /**
   * Set when the AGENT asked for this tab.
   *
   * Main used to match the new tab to the request by URL prefix, which cannot
   * survive a host change — 서울대's `my.snu.ac.kr` redirects to
   * `shine.snu.ac.kr`, so neither string is a prefix of the other, the wait
   * timed out, and `browser_open` reported "탭을 여는 데 실패했어요" about a
   * tab that had opened and was working. The agent only found it by chance,
   * later, through `browser_tabs`.
   */
  requestId?: string
  /**
   * ⌘-click / middle-click. Chrome opens these behind the current tab;
   * yanking focus five times while a student queues up five 공지 links is
   * exactly what the modifier exists to avoid.
   */
  background?: boolean
}

/** Authentication observations belong to one native page and one document. */
export interface BrowserAuthEvent extends BrowserAuthStatus {
  tabId?: string
  webContentsId: number
  sourceWebContentsId: number
}

/** Fired after settings change from any window. */
export interface SettingsChanged {
  settings: Settings
}

/**
 * [M6-A] A browser guest swallowed a workspace shortcut (⌘T / ⌘W). Main
 * intercepts it via `before-input-event` and forwards it here so the
 * shortcuts hook can run the same action as a host-window keydown.
 */
/**
 * The glass box: what the agent is doing in a tab, right now.
 *
 * Pushed on every step so the student can watch a real page move, and stop it.
 */
export interface BrowserAgentRunState {
  runId: string
  courseId: string
  tabId: string
  status: 'running' | 'waiting' | 'stopped' | 'done'
  /** One short line, in the student's language. */
  action: string
  url: string
}

/** One browser download's lifecycle, throttled while progressing. */
export interface BrowserDownloadUpdate {
  id: string
  webContentsId: number | null
  fileName: string
  receivedBytes: number
  /** 0 when the server sends no Content-Length. */
  totalBytes: number
  state: 'progressing' | 'completed' | 'cancelled' | 'interrupted'
  /** Chromium keeps state=progressing while a resumable transfer is paused. */
  paused?: boolean
  /** Course-relative path, once the file is in the course folder. */
  relPath: string | null
  courseId: string | null
  /** Complete bytes were kept and can be saved elsewhere or filed again. */
  recoverable?: boolean
  /** The transfer worked but filing it did not. */
  failureReason: string | null
}

export interface ShortcutPassthrough {
  action:
    | 'new-tab'
    | 'new-markdown'
    | 'new-browser-tab'
    | 'new-ai-tab'
    | 'new-recording-tab'
    | 'new-whiteboard'
    | 'open-study-board'
    | 'toggle-left-rail'
    | 'close-tab'
    | 'activate-last-tab'
    | 'activate-tab-1'
    | 'activate-tab-2'
    | 'activate-tab-3'
    | 'activate-tab-4'
    | 'activate-tab-5'
    | 'activate-tab-6'
    | 'activate-tab-7'
    | 'activate-tab-8'
    | 'browser-back'
    | 'browser-forward'
    | 'reload'
    | 'reload-hard'
    | 'focus-address'
    | 'find'
    | 'bookmark'
    | 'reopen-tab'
    | 'prev-tab'
    | 'next-tab'
    | 'zoom-in'
    | 'zoom-out'
    | 'zoom-reset'
  /**
   * The guest that swallowed the chord, so the renderer can act on ITS tab.
   * Guests live in a fixed layer outside the dockview panel DOM and focusing
   * one does not make its panel active, so without this ⌘W in a split closes
   * whichever tab dockview happens to consider active — not the one the
   * student is typing into.
   */
  webContentsId: number
}

export interface PushEvents {
  'learning:changed': { binding: import('../types/learning').LearningBinding }

  'recordings:event': RecordingEvent
  'recordings:modelsChanged': SpeechModelState[]
  'chat:event-batch': ChatEventBatch
  'chat:message': { sessionId: string; message: import('../types/chat').ChatMessage }
  'chat:configurationChanged': { sessionId: string; model: string; effort: string | null }
  /** A course was created, renamed, archived or removed. */
  'courses:changed': { }
  /** Board tasks changed outside the board panel. */
  'appleCalendar:changed': Record<string, never>
  'board:changed': { courseId: string | null }
  /** A personal whiteboard or its shapes changed. */
  'canvas:changed': { courseId: string }
  /** A destructive assistant tool is waiting for the student. */
  'agentTools:confirm': AgentConfirmRequest
  'agentTools:confirmationChanged': import('../types/agentTools').AgentConfirmationState
  /** One request finished changing things; show the change list. */
  /**
   * `conversationId` so the change list lands in the chat that caused it —
   * course-level routing put it in every conversation of that course.
   */
  'agentTools:changed': {
    courseId: string
    conversationId: string
    turnId: string
  }
  /**
   * The in-app MCP server failed to start for a conversation.
   *
   * Surfaced rather than logged because the symptom — an assistant that
   * quietly cannot touch the app or the browser — is indistinguishable from a
   * missing feature unless we say so.
   */
  'agentTools:unavailable': { courseId: string; sessionId: string }
  'search:changed': { courseId: string }
  'materials:changed': MaterialsChanged
  // -- picture-in-picture ---------------------------------------------------
  'pip:state': PipState
  'pip:error': { message: string }
  'pip:seek': {
    positionSec: number
    playbackRate: number
    play: boolean
  }
  'ui:openMaterial': {
    courseId: string
    relPath: string
    positionSec: number
    playbackRate: number
  }
  'ui:openUrl': {
    url: string
    positionSec: number
    playbackRate: number
  }
  'browser:page-event': BrowserPageEvent
  'browser:open-url': BrowserOpenUrl
  /**
   * Something the browser refused, so it can be seen instead of guessed at.
   *
   * Every deny path used to be a silent `preventDefault()`. A page that
   * stopped working looked identical to a page that had nothing to do.
   */
  'browser:blocked': {
    kind: 'navigation' | 'popup' | 'scheme'
    url: string
    reason: string
  }
  /** A popup was refused by policy or the anti-spam limiter. */
  'browser:popup-blocked': {
    profileId?: string
    isPrivate?: boolean
    url: string
    origin: string
    reason: 'burst' | 'limit' | 'policy'
  }
  /** A custom-scheme handoff finished (or found no program to hand to). */
  'browser:external-scheme': {
    url: string
    origin: string
    outcome: 'opened' | 'cancelled' | 'blocked' | 'no-handler'
  }
  /**
   * Bring an existing browser tab forward so its guest mounts again.
   *
   * The agent needs this because a tab the student can see may have had its
   * guest evicted by the LRU — there is nothing to read until it is back.
   */
  'browser:activate-tab': { tabId: string }
  /** Closes a browser tab the agent is done with. The workspace owns the strip. */
  'browser:close-tab': { tabId: string }
  /** 파일 ▸ 인쇄… (or ⌘P over a printable tab) was chosen. */
  'ui:print': { }
  /** An in-app authentication page explicitly reported an embedded refusal. */
  'browser:external-auth': BrowserAuthEvent
  'settings:changed': SettingsChanged
  'window:stateChanged': { fullscreen: boolean }
  /** Open the in-app settings overlay (app menu ⌘, or legacy callers). */
  'ui:openSettings': { category?: SettingsCategoryId }
  'browser:download': BrowserDownloadUpdate
  'browserAgent:run-state': BrowserAgentRunState
  'shortcut:passthrough': ShortcutPassthrough
  // -- groups (P2-C) --------------------------------------------------------
  'auth:changed': AuthState
  // -- auto update ----------------------------------------------------------
  /**
   * Every auto-update state transition, including ones the renderer never
   * asked for (the periodic background check). Broadcast to all windows so the
   * workspace toast and the Settings panel cannot disagree.
   */
  'update:changed': UpdateStatus
  // -- agent setup ----------------------------------------------------------
  'agent:install-progress': AgentInstallProgress
  'agent:login-progress': AgentLoginProgress
  // -- group whiteboard -----------------------------------------------------
  // -- desktop overlay ------------------------------------------------------
  'assistant:contextChanged': { courseId: string }
  'assistant:contextRefresh': { requestId: string }
  'ui:openChat': { courseId: string; conversationId: string }
  'desktopAgent:run-state': {
    conversationId: string
    status: 'idle' | 'capturing' | 'reading'
    action: string | null
  }
  'desktopAgent:permission': {
    state: ScreenPermissionState
    message: string | null
  }
  // -- user MCP registry ----------------------------------------------------
  'mcp:changed': Record<string, never>
  // -- extensions -----------------------------------------------------------
  'plugins:changed': { plugins: PluginSummary[] }
  'packs:changed': { packs: WorkflowPackSummary[] }
  'plugins:settingsChanged': { pluginId: string; values: Record<string, unknown> }
  'plugins:editorRequest': import('../types/pluginEditor').PluginEditorRequest
  /** `bandal.notices.show` from a plugin; renderer prefixes the plugin name. */
  'plugins:notice': {
    pluginId: string
    pluginName: string
    message: string
    tone: 'info' | 'danger'
  }
  /** `bandal.panel.open` — renderer opens the `plugin-panel` tab. */
  'plugins:openPanel': { pluginId: string; panelId: string }
  'plugins:closePanel': { pluginId: string; panelId: string }
}

export type PushChannel = keyof PushEvents
export type PushPayload<K extends PushChannel> = PushEvents[K]
