/**
 * [C2] Workspace tab model.
 *
 * A tab is what lives inside a dockview panel. Payloads must stay
 * JSON-serializable — they are persisted as part of the dockview layout
 * (`layout:save`). For extension:
 * add a new kind + payload and extend TabPayloadMap; never repurpose an
 * existing kind.
 */

export type TabKind =
  | 'recording'
  | 'pdf'
  | 'note'
  | 'browser'
  | 'chat'
  | 'board'
  | 'whiteboard'
  | 'image'
  | 'file'
  | 'plugin-panel'
  | 'learning'

export interface PdfTabPayload {
  courseId: string
  /** Path of the PDF relative to the course folder. */
  relPath: string
}

export interface ImageTabPayload {
  courseId: string
  /** Path of the image relative to the course folder. */
  relPath: string
}

export interface NoteTabPayload {
  courseId: string
  /** Path of the markdown note relative to the course folder. */
  relPath: string
}

/**
 * What a fresh browser tab carries. It is not navigated to — the app shows its
 * own start page instead — but it stays a real URL so older saved layouts and
 * favorites keep resolving.
 */
export const NEW_TAB_URL = 'https://www.google.com'

export interface BrowserTabPayload {
  /** Stable id linking this tab to its main-process WebContentsView. */
  tabId: string
  initialUrl: string
  /** Non-persistent browsing session for this tab. */
  isPrivate?: boolean
  profileId?: string
}

export interface ChatTabPayload {
  sourcePanelId?: string
  courseId: string
  /**
   * Conversation id (renderer-minted uuid, becomes agent_sessions.id on the
   * first send). OPTIONAL for legacy persisted layouts/favorites: a payload
   * without one is normalized by ChatTab to the course's newest conversation
   * (or a fresh uuid) on mount.
   */
  conversationId?: string
}

/** The board is a per-window singleton; it carries no payload. */
export type BoardTabPayload = Record<string, never>
export interface WhiteboardTabPayload {
  courseId: string
  boardId: string
}

export interface TabPayloadMap {
  recording: { courseId: string; sessionId?: string; title?: string; newRecording?: boolean }
  pdf: PdfTabPayload
  note: NoteTabPayload
  browser: BrowserTabPayload
  chat: ChatTabPayload
  board: BoardTabPayload
  whiteboard: WhiteboardTabPayload
  image: ImageTabPayload
  file: FileTabPayload
  'plugin-panel': PluginPanelTabPayload
  learning: LearningTabPayload
}

export type LearningView = 'home' | 'reader' | 'vocabulary' | 'articles' | 'review'

/** Folder binding distinguishes copied projects even when their manifest ids match. */
export interface LearningTabPayload {
  courseId: string
  rootRelPath?: string
  /** Recovery hint only; copied projects are still identified by their folder binding. */
  projectId?: string
  view?: LearningView
  itemId?: string
}

/**
 * Generic in-app viewer for formats without a dedicated tab (docx, xlsx, csv,
 * plain text, …). The FileTab component routes by extension; unsupported
 * extensions never get a descriptor — openMaterial falls back to Finder.
 */
export interface FileTabPayload {
  courseId: string
  relPath: string
}

/**
 * A panel contributed by an installed extension, rendered in a sandboxed
 * `<webview>` on `bandal-plugin://<pluginId>/ui/…`. Survives layout restore
 * even when the plugin is gone — the tab then shows a placeholder.
 */
export interface PluginPanelTabPayload {
  pluginId: string
  panelId: string
}

/** Discriminated tab descriptor: { kind, payload } pairs, serializable. */
export type TabDescriptor = {
  [K in TabKind]: { kind: K; payload: TabPayloadMap[K] }
}[TabKind]

// -- structural validation -----------------------------------------------
//
// Lives here rather than in the renderer because BOTH processes validate
// descriptors: the renderer when rehydrating a dockview layout, and main
// when storing a favorite. Keeping it renderer-side forced main to import
// across the project boundary (TS6307), which is exactly the kind of
// main→renderer dependency the tsconfig split exists to prevent.

/**
 * Runtime witness for `TabKind`. It has to be exhaustive, and a hand-kept copy
 * is not: `image` was added to the union and forgotten here, so `isTabKind`
 * rejected every image descriptor and the tab silently refused to open. The
 * same drift already cost us IPC channels and drawing kinds — the assignment
 * below stops compiling when a kind is missing.
 */
export const TAB_KINDS = [
  'recording',
  'pdf',
  'note',
  'browser',
  'chat',
  'board',
  'whiteboard',
  'image',
  'file',
  'plugin-panel',
  'learning'
] as const satisfies readonly TabKind[]

type MissingTabKind = Exclude<TabKind, (typeof TAB_KINDS)[number]>
const _allTabKindsListed: MissingTabKind extends never ? true : never = true
void _allTabKindsListed

export function isTabKind(value: unknown): value is TabKind {
  return typeof value === 'string' && (TAB_KINDS as readonly string[]).includes(value)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0
}

/** Hard structural validation of a persisted tab descriptor. */
export function isTabDescriptor(value: unknown): value is TabDescriptor {
  if (!isRecord(value) || !isTabKind(value['kind'])) return false
  const payload = value['payload']
  if (!isRecord(payload)) return false

  switch (value['kind']) {
    case 'recording':
      return isNonEmptyString(payload['courseId']) &&
        (payload['sessionId'] === undefined || isNonEmptyString(payload['sessionId'])) &&
        (payload['title'] === undefined || typeof payload['title'] === 'string') &&
        (payload['newRecording'] === undefined || typeof payload['newRecording'] === 'boolean')
    case 'pdf':
    case 'note':
      return (
        isNonEmptyString(payload['courseId']) &&
        isNonEmptyString(payload['relPath'])
      )
    case 'browser':
      return (
        isNonEmptyString(payload['tabId']) &&
        typeof payload['initialUrl'] === 'string' &&
        (payload['isPrivate'] === undefined || typeof payload['isPrivate'] === 'boolean') &&
        (payload['profileId'] === undefined || typeof payload['profileId'] === 'string')
      )
    case 'chat':
      return (
        isNonEmptyString(payload['courseId']) &&
        (payload['sourcePanelId'] === undefined || isNonEmptyString(payload['sourcePanelId'])) &&
        (payload['conversationId'] === undefined ||
          isNonEmptyString(payload['conversationId']))
      )
    case 'board':
      return true
    case 'whiteboard':
      return (
        isNonEmptyString(payload['courseId']) &&
        isNonEmptyString(payload['boardId'])
      )
    case 'image':
    case 'file':
      return (
        isNonEmptyString(payload['courseId']) &&
        isNonEmptyString(payload['relPath'])
      )
    case 'plugin-panel':
      return (
        isNonEmptyString(payload['pluginId']) &&
        isNonEmptyString(payload['panelId'])
      )
    case 'learning':
      return isNonEmptyString(payload['courseId']) &&
        (payload['rootRelPath'] === undefined || typeof payload['rootRelPath'] === 'string') &&
        (payload['projectId'] === undefined || isNonEmptyString(payload['projectId'])) &&
        (payload['view'] === undefined || (typeof payload['view'] === 'string' && ['home', 'reader', 'vocabulary', 'articles', 'review'].includes(payload['view']))) &&
        (payload['itemId'] === undefined || isNonEmptyString(payload['itemId']))

  }
}
