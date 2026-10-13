/**
 * What the assistant did to the app, and how the student takes it back.
 *
 * The agent reads third-party lecture PDFs, so giving it app-mutating tools
 * widens the blast radius of prompt injection. Three things keep that in
 * check and all three are visible here: destructive tools ask first, every
 * successful call is journalled, and creations can be undone in one gesture.
 */

/** What a tool touched. Used to pick the right undo. */
export type AgentActionTarget =
  | 'course'
  | 'material'
  | 'link'
  | 'note'
  | 'task'
  | 'board'
  | 'shape'
  /**
   * 기존 문서의 제자리 편집(edit_sheet / edit_docx_text). targetId 는
   * `relPath\u0000backupAbs` — 되돌리기는 백업을 원래 경로로 복사한다.
   */
  | 'material-edit'

export interface AgentAction {
  id: string
  courseId: string
  /** Groups everything one request changed, so undo is one gesture. */
  turnId: string
  tool: string
  targetKind: AgentActionTarget
  targetId: string
  /** Human-readable, e.g. "과목 «고체역학»". Shown in the change list. */
  label: string
  /** False for deletes and overwrites — there is nothing to restore. */
  undoable: boolean
  undoneAt: string | null
  createdAt: string
}

export interface AgentTurnChanges {
  turnId: string
  actions: AgentAction[]
}

/**
 * A destructive tool waiting on the student.
 *
 * CLI and Bandal tool requests share the main-process confirmation queue.
 */
/**
 * What the student is looking at in Bandal right now.
 *
 * The agent could see the web — `browser_tabs` — and nothing at all of the
 * app it lives in. So an instruction about the app ("학기를 바꿔줘", meaning
 * the sidebar's 2026년 1학기 group) had exactly one referent the agent could
 * resolve: a `<select>` on the portal. It was not a reasoning failure; it was
 * the only reading its world model permitted.
 *
 * Published by the renderer, cached by main — the same self-healing shape as
 * `browserAgent:syncTabs`, which this channel absorbs.
 */
export interface AgentAppState {
  /** The course the student has selected in the sidebar. */
  selectedCourseId: string | null
  /** 학기 그룹 — the named sidebar sections. */
  groups: { id: string; name: string }[]
  courses: {
    id: string
    name: string
    groupId: string | null
    groupName: string | null
  }[]
  /** Non-browser tabs: pdf, note, board, whiteboard, chat, group-chat. */
  workspaceTabs: { kind: string; title: string; active: boolean }[]
  browserTabs: {
    tabId: string
    title: string
    url: string
    active: boolean
    asleep: boolean
  }[]
}

/**
 * How widely an approval applies. Only site-access asks this.
 *
 *  - `once`   this call only
 *  - `site`   this origin, for this course, 30 days
 *  - `course` every site in this course, 30 days — except the hard-denied
 *              ones (수강신청·결제), which are not askable at any scope
 */
export type AgentConfirmScope =
  | 'once'
  | 'site'
  | 'course'
  | 'conversation'
  | 'always'

export interface AgentConfirmRequest {
  turnId?: string
  operationKey?: string
  providerRequestId?: string
  requestId: string
  courseId: string
  /**
   * Which conversation asked.
   *
   * Its absence is why approval cards showed up in EVERY past conversation:
   * the renderer store had nothing but `courseId` to key on, so one card
   * rendered in every ChatSurface mounted for that course.
   */
  conversationId: string
  tool: string
  /** One line describing exactly what will happen, in the student's language. */
  summary: string
  /** Extra detail — the paths or names involved. */
  details: string[]
  /** Present only when the answer can be remembered at more than one scope. */
  scopes?: AgentConfirmScope[]
}

export interface AgentConfirmResponse {
  requestId: string
  approved: boolean
  /** Which scope the student picked; ignored unless the request offered them. */
  scope?: AgentConfirmScope
}

export interface AgentConfirmationState {
  request: AgentConfirmRequest
  status: 'pending' | 'approved' | 'denied' | 'expired' | 'cancelled'
  revision: number
  scope?: AgentConfirmScope
}
