import { STUDY_MARKET_CHANNELS, type StudyMarketIpcContract } from './studyMarketContract'
import { LEARNING_CHANNELS, type LearningIpcContract } from './learningContract'
import type { MaterialHoverPreview } from '../types/materialHoverPreview'
import type { BrowserPageState, BrowserPageAction } from '../types/browserNative'
import type { BrowserImportSource, BrowserImportFileKind, BrowserImportRequest, BrowserImportJob } from '../types/browserImport'
import type { AppleCalendarState, AppleCalendarEvent, AppleCalendarPreferences } from '../types/appleCalendar'
/**
 * [C1] The single source of truth for request/response IPC.
 *
 * Every invokable channel is declared here as `channel → { req; res }`.
 * Main registers a handler per channel (src/main/ipc/registerHandlers.ts),
 * the preload bridge and renderer client (src/renderer/src/lib/ipc.ts) are
 * typed against this interface. FROZEN for M1+ workstreams — extend, don't
 * mutate existing shapes.
 */

import type {
  DiagnosticsBundle,
  SystemPermissionId,
  SystemPermissionStatus,
  SystemPermissionsReport
} from '../types/permissions'
import type { MailIpcContract } from '../types/mail'
import { RECORDING_CHANNELS, type RecordingIpcContract } from '../recording'
import type { PresentationIpcContract } from '../types/presentation'
import type { CatalogInstallResult, PluginCatalog } from '../types/pluginCatalog'
import type { UsageSummary, UsageWindowDays } from '../types/usage'
import type {
  AddCourseFromFolderInput,
  Course,
  CourseFolderResult,
  CourseGroup,
  CreateCourseInput,
  PickedFolder,
  RelinkCourseInput,
  RenameCourseInput,
  SetCourseColorInput
} from '../types/course'
import type {
  ImportResult,
  MaterialFileContent,
  MaterialNode,
  MaterialSearchHit
} from '../types/materials'
import type {
  CreateNoteInput,
  NoteContent,
  NoteRef,
  WriteNoteInput
} from '../types/note'
import type {
  Annotation,
  CreateAnnotationInput,
  UpdateAnnotationInput
} from '../types/annotation'
import type {
  BoardTask,
  CalendarRangeInput,
  CreateTaskInput,
  ListTasksInput,
  UpcomingDeadline,
  UpdateTaskInput
} from '../types/board'
import type {
  CourseLink,
  CreateCourseLinkInput,
  UpdateCourseLinkInput
} from '../types/courseLink'
import type {
  AgentModelCatalog,
  CarryoverStats,
  ChatConversationSummary,
  ChatOpenResult,
  ChatSendInput,
  ChatSessionInfo,
  ChatSurface
} from '../types/chat'
import type {
  CreateDrawingInput,
  Drawing,
  DrawingShape,
  ExportAnnotatedPdfInput,
  ExportAnnotatedPdfResult,
  UpdateDrawingInput
} from '../types/drawing'
import type {
  CreateFavoriteInput,
  Favorite,
  RenameFavoriteInput,
  ReorderFavoritesInput
} from '../types/favorite'
import type {
  ActivityEvent,
  RecordActivityInput,
  RunStudyToolInput,
  RunStudyToolResult,
  StudyToolDefinition
} from '../types/study'
import type {
  WorkflowPack,
  WorkflowPackSummary
} from '../types/workflowPack'
import type { MediaProgress } from '../types/mediaProgress'
import type { PdfViewState } from '../types/pdfViewState'
import type { PipOpenRequest, PipState } from '../types/pip'
import type { SearchHit } from '../types/search'
import type { BrowserExtensionSummary } from '../types/browserExtension'
import type {
  MaterialBacklinkGroup,
  MaterialBacklinks,
  MaterialLinkRecord,
  SendHighlightToNoteInput,
  SendWebClipToNoteInput,
  SendHighlightToNoteResult
} from '../types/link'
import type { TabDescriptor } from '../tabs'
import type {
  AgentConfirmResponse,
  AgentTurnChanges
} from '../types/agentTools'
import type {
  CredentialsAvailability,
  CredentialsImportResult,
  FillLoginResult,
  SaveLoginInput,
  SavedLoginSummary
} from '../types/credentials'
import type {
  CreatePersonalBoardInput,
  OpenPersonalBoardResult,
  PersonalBoard,
  PutPersonalShapeInput,
  RemovePersonalShapesInput,
  RenamePersonalBoardInput,
  SetBoardBackgroundInput,
  SetBoardPageCountInput,
} from '../types/whiteboard'
import type {
  AgentAvailability,
  AgentProvider,
  PermissionResponse
} from '../types/agent-events'
import type { Settings, SettingsPatch } from '../types/settings'
import type { ScreenPermissionState } from '../types/screenCapture'
import type {
  McpAvailability,
  McpServerInput,
  McpServerSummary,
  McpTestResult
} from '../types/mcp'
import type { UpdateStatus } from '../types/update'
import type { PluginLogEntry, PluginSummary } from '../types/plugin'
import type {
  AuthProvider,
  AuthSignInResult,
  AuthState,
  MyProfile
} from '../types/auth'

/** Pack metadata projected into the existing study-tool menu. */
export interface WorkflowPackToolDefinition
  extends Omit<StudyToolDefinition, 'id'> {
  /** Built-ins keep their stable ids; installed packs use `custom:*` ids. */
  id: string
  source: WorkflowPackSummary['source']
  enabled: boolean
  usesWeb: boolean
  experience?: import('../types/workflowPack').NativeStudyExperience
  outputs: WorkflowPack['outputs']
  followUp?: NonNullable<WorkflowPack['followUp']>
}

/** The legacy study channel is also the execution entry point for user packs. */
export type RunWorkflowPackStudyInput = Omit<RunStudyToolInput, 'tool'> & {
  tool: string
  followUpOf?: string
}

export interface IpcContract extends StudyMarketIpcContract, MailIpcContract, PresentationIpcContract, RecordingIpcContract, LearningIpcContract {
  // -- courses --------------------------------------------------------------
  'courses:list': {
    req: { includeArchived?: boolean }
    res: Course[]
  }
  /**
   * Creates the course row AND a managed folder under <dataRoot>/<slug>.
   * For an existing folder on disk use `courses:addFromFolder`.
   */
  'courses:create': {
    req: CreateCourseInput
    res: Course
  }
  /**
   * Opens the native folder picker (main process). Resolves to `null` when
   * the user cancels.
   */
  'courses:pickFolder': {
    req: Record<string, never>
    res: PickedFolder | null
  }
  /**
   * Registers an existing folder on disk as a course (source: 'linked').
   * Nothing on disk is created or moved.
   */
  'courses:addFromFolder': {
    req: AddCourseFromFolderInput
    res: CourseFolderResult
  }
  /** Points an existing course at another folder (연결 끊김 복구). */
  'courses:relink': {
    req: RelinkCourseInput
    res: CourseFolderResult
  }
  'courses:rename': {
    req: RenameCourseInput
    res: Course
  }
  'courses:setColor': {
    req: SetCourseColorInput
    res: Course
  }
  'courses:archive': {
    req: { courseId: string; archived: boolean }
    res: Course
  }
  /** Soft-deletes the course; the folder on disk is left untouched. */
  'courses:delete': {
    req: { courseId: string }
    res: { ok: true }
  }
  /**
   * Hard-deletes an already SOFT-DELETED managed course row and moves its
   * folder to the OS trash. Triple-guarded (soft-deleted + managed + folder
   * inside dataRoot) — exists for tutorial temp-course cleanup only.
   */
  'courses:purge': {
    req: { courseId: string }
    res: { ok: true }
  }
  /**
   * One drag = one atomic call. Moves a course into `groupId` (null =
   * ungrouped) AND positions it before `beforeCourseId` (null = append to the
   * end of the target group's block) in a single transaction, then returns
   * the refreshed full list so the renderer never has to interleave two
   * mutations. `beforeCourseId` must already belong to the target group.
   */
  'courses:organize': {
    req: {
      courseId: string
      groupId: string | null
      beforeCourseId: string | null
    }
    res: Course[]
  }

  // -- course groups (과목 그룹/학기) ----------------------------------------
  // Course groups are local sidebar sections.
  'courseGroups:list': {
    req: Record<string, never>
    res: CourseGroup[]
  }
  'courseGroups:create': {
    req: { name: string }
    res: CourseGroup
  }
  'courseGroups:rename': {
    req: { groupId: string; name: string }
    res: CourseGroup
  }
  /**
   * Soft-deletes the group and sets every member course's groupId to null.
   * Courses themselves are NEVER deleted by a group operation.
   */
  'courseGroups:delete': {
    req: { groupId: string }
    res: { ok: true }
  }

  // -- course links (M8: per-course LMS shortcuts) --------------------------
  /** Shortcuts pinned under one course, in sidebar order. */
  'courseLinks:list': {
    req: { courseId: string }
    res: CourseLink[]
  }
  /**
   * Stores a pasted URL as a shortcut. The renderer classifies it against the
   * school's CourseLinkSpec first; main re-validates that `url` is http(s).
   */
  'courseLinks:create': {
    req: CreateCourseLinkInput
    res: CourseLink
  }
  'courseLinks:update': {
    req: UpdateCourseLinkInput
    res: CourseLink
  }
  'courseLinks:delete': {
    req: { id: string }
    res: { ok: true }
  }

  // -- shell ----------------------------------------------------------------
  /**
   * [M8] Opens an http(s) URL in the system browser. Used for the services
   * that structurally cannot work inside the embedded browser — Google /
   * Microsoft federated login, UA-sniffing 학사 포털, native security plugins
   * (docs/university-sites.md §5.2). Any other scheme is rejected.
   */
  'shell:openExternal': {
    req: { url: string }
    res: { ok: true }
  }

  // -- materials ------------------------------------------------------------
  'materials:snapshot': { req: { courseId: string }; res: { tree: MaterialNode[] | null } }
  'materials:tree': {
    req: { courseId: string }
    res: MaterialNode[]
  }
  'materials:search': {
    req: { courseId: string; query: string }
    res: MaterialSearchHit[]
  }
  /**
   * Copies absolute paths into the course folder. `dirRelPath` targets a
   * course-relative folder; '' or omitted means the course root.
   */
  'materials:import': {
    req: { courseId: string; paths: string[]; dirRelPath?: string }
    res: ImportResult
  }
  /**
   * Moves a file or folder to another course-relative directory
   * (`toDirRelPath: ''` = course root). Collisions auto-rename with the
   * import convention (`name (2).ext`); moving a folder into itself or a
   * descendant is rejected. The folder watcher pushes `materials:changed`.
   */
  'materials:move': {
    req: { courseId: string; fromRelPath: string; toDirRelPath: string }
    res: { relPath: string }
  }
  /** Reveals the file in Finder / file manager. */
  'materials:reveal': {
    req: { courseId: string; relPath: string }
    res: { ok: true }
  }
  /**
   * macOS Quick Look(그 외 OS 는 기본 앱)으로 파일 미리보기 — 앱이
   * 렌더링하지 못하는 형식(.ppt 등)용.
   */
  'materials:preview': {
    req: { courseId: string; relPath: string }
    res: { ok: true }
  }
  /** Reads a material file; binary files come back base64-encoded. */
  'materials:readFile': {
    req: { courseId: string; relPath: string }
    res: MaterialFileContent
  }
  /** Bounded, read-only sidebar content; never opens a viewer or starts conversion. */
  'materials:hoverPreview': {
    req: { courseId: string; relPath: string }
    res: MaterialHoverPreview
  }
  /**
   * [M5] Starts watching the course folder on disk. Changes are debounced and
   * pushed as `materials:changed { courseId }`. Idempotent per course.
   */
  'materials:watch': {
    req: { courseId: string }
    res: { ok: true }
  }
  /**
   * File operations behind the materials tree's context menu. All of them
   * take a course-relative path and resolve it under the course folder
   * (db/validate.ts `resolveInside`) — an absolute path or a `..` escape is
   * rejected, never clamped.
   */
  'materials:rename': {
    /** `newName` is a bare basename, not a path. */
    req: { courseId: string; relPath: string; newName: string }
    res: { relPath: string }
  }
  /** Moves to the OS trash (recoverable) rather than unlinking. */
  'materials:delete': {
    req: { courseId: string; relPath: string }
    res: { ok: true }
  }
  'materials:duplicate': {
    req: { courseId: string; relPath: string }
    res: { relPath: string }
  }
  /**
   * Writes raw bytes into the course folder — the clipboard-paste path
   * (⌘V of an image or text onto the materials rail). `fileName` is a
   * basename; collisions get a `-2` suffix rather than overwriting.
   */
  'materials:writeFile': {
    req: {
      courseId: string
      dirRelPath: string
      /** Creates dirRelPath when absent; intended for app-managed buckets. */
      createDirIfMissing?: boolean
      fileName: string
      encoding: 'utf8' | 'base64'
      data: string
    }
    res: { relPath: string }
  }
  /**
   * Downloads a dragged browser link straight into a course folder. Fetched
   * with the `persist:browsing` session so portal logins carry over; name and
   * path safety are enforced by the same guards as materials:writeFile.
   */
  'materials:downloadFromUrl': {
    req: { courseId: string; dirRelPath: string; url: string; tabId?: string }
    res: { relPath: string }
  }
  'materials:createFolder': {
    req: { courseId: string; dirRelPath: string; name: string }
    res: { relPath: string }
  }
  'materials:unwatch': {
    req: { courseId: string }
    res: { ok: true }
  }
  /** [M18] 영상 이어보기 — last watch position + playback rate per file. */
  'media:getProgress': {
    req: { courseId: string; relPath: string }
    res: MediaProgress | null
  }
  'media:setProgress': {
    req: {
      courseId: string
      relPath: string
      positionSec: number
      durationSec: number | null
      playbackRate: number
    }
    res: MediaProgress
  }
  /** 마지막 열람 페이지/줌 — 로컬 SQLite. 재시작 후 그 자리에서 다시 연다. */
  'pdf:getViewState': {
    req: { courseId: string; relPath: string }
    res: PdfViewState | null
  }
  'pdf:setViewState': {
    req: { courseId: string; relPath: string; page: number; zoom: number }
    res: PdfViewState
  }

  // -- renderer handoff -----------------------------------------------------
  /**
   * 새 메인 창이 React 구독을 설치하기 전에 요청된 열기 동작을 한 번 가져간다.
   * 읽은 값은 main에서 즉시 제거된다.
   */
  'ui:consumePendingOpen': {
    req: Record<string, never>
    res: {
      material?: {
        courseId: string
        relPath: string
        positionSec: number
        playbackRate: number
      }
      url?: {
        url: string
        positionSec: number
        playbackRate: number
      }
    } | null
  }

  // -- picture-in-picture ---------------------------------------------------
  'pip:open': {
    req: PipOpenRequest
    res: { ok: true }
  }
  'pip:close': {
    req: Record<string, never>
    res: { ok: true }
  }
  /** 미니 플레이어에서 원래 앱 자리로 돌아간다. */
  'pip:restore': {
    req: Record<string, never>
    res: { ok: true }
  }
  'pip:getState': {
    req: Record<string, never>
    res: PipState
  }
  /** PiP 렌더러가 현재 재생 상태를 주기적으로 보고한다. */
  'pip:report': {
    req: {
      positionSec: number
      playbackRate: number
      paused: boolean
      aspect?: number
    }
    res: { ok: true }
  }
  /** 웹 PiP 툴바의 드래그 거리만큼 미니 플레이어를 이동한다. */
  'pip:moveBy': {
    req: { dx: number; dy: number }
    res: { ok: true }
  }

  // -- notes ----------------------------------------------------------------
  'notes:read': {
    req: NoteRef
    res: NoteContent
  }
  'notes:write': {
    req: WriteNoteInput
    res: { mtime: number }
  }
  'notes:create': {
    req: CreateNoteInput
    res: NoteRef
  }
  /**
   * Renames a note from its title in ONE transaction: sanitizes the stem,
   * resolves collisions with a -2/-3 suffix, rewrites the first H1 to the
   * final name, then renames the file. Editor-title edits and sidebar renames
   * both flow through this so title and filename can never diverge.
   */
  'notes:rename': {
    req: { courseId: string; relPath: string; newName: string }
    res: { relPath: string; mtime: number; title: string; markdown: string }
  }

  // -- annotations ----------------------------------------------------------
  'annotations:listForFile': {
    req: { courseId: string; relPath: string }
    res: Annotation[]
  }
  'annotations:create': {
    req: CreateAnnotationInput
    res: Annotation
  }
  'annotations:update': {
    req: UpdateAnnotationInput
    res: Annotation
  }
  'annotations:delete': {
    req: { id: string }
    res: { ok: true }
  }

  // -- board ----------------------------------------------------------------
  'board:listTasks': {
    req: ListTasksInput
    res: BoardTask[]
  }
  'board:createTask': {
    req: CreateTaskInput
    res: BoardTask
  }
  /** Handles content edits plus status / sort_order moves. */
  'board:updateTask': {
    req: UpdateTaskInput
    res: BoardTask
  }
  'board:reorderTasks': {
    req: {
      courseId: string
      updates: Array<{
        id: string
        status?: BoardTask['status']
        sortOrder: number
      }>
    }
    res: BoardTask[]
  }
  'board:deleteTask': {
    req: { id: string }
    res: { ok: true }
  }

  // -- chat -----------------------------------------------------------------
  /** Opens (or resumes) one conversation of a course. */
  'chat:context': { req: { courseId: string; sourcePanelId?: string }; res: import('../types/chatContext').MessageContextSnapshot }
  'assistant:capture': { req: { region: boolean }; res: import('../types/chat').ChatAttachment | null }
  'assistant:selection': { req: { action: 'get' | 'cancel' | 'select'; rect?: { x: number; y: number; width: number; height: number } }; res: { image?: string } }
  'chat:accessPolicy': {
    req: { courseId: string; sessionId: string; policy?: import('../types/aiAccess').AiAccessPolicy }
    res: import('../types/aiAccess').AiAccessPolicy
  }
  'chat:open': {
    req: { courseId: string; sessionId: string; surface?: ChatSurface }
    res: ChatOpenResult
  }
  /** Sends a user message; streaming arrives via `chat:event-batch`. */
  'chat:send': {
    req: ChatSendInput
    res: { turnSeq: number }
  }
  'chat:cancel': {
    req: { courseId: string; sessionId: string }
    res: { ok: true }
  }
  'chat:respondPermission': {
    req: {
      courseId: string
      sessionId: string
      requestId: string
      response: PermissionResponse
    }
    res: { ok: true }
  }
  'chat:close': {
    req: { courseId: string; sessionId: string }
    res: { ok: true }
  }
  /**
   * Pins the model for a conversation. Drops the warm CLI process so the next
   * send respawns with `--model`; history and the resumable CLI session id
   * survive.
   */
  'agentTools:confirmations': {
    req: { conversationId: string }
    res: import('../types/agentTools').AgentConfirmationState[]
  }
  'chat:setConfiguration': {
    req: { courseId: string; sessionId: string; model: string; effort: string | null }
    res: { model: string; effort: string | null }
  }
  'chat:setModel': {
    req: { courseId: string; sessionId: string; model: string }
    res: { ok: true }
  }
  /**
   * Switches a conversation's provider IN PLACE (same id, same tab). Both
   * managers drop their warm process; the row's CLI resume record is cleared
   * so the next send replays the prior transcript into the new CLI's first
   * prompt, and a `notice` block is persisted. `carried` is null when the
   * provider did not change. Refused while a turn is running.
   */
  'chat:setProvider': {
    req: { courseId: string; sessionId: string; provider: AgentProvider; surface?: ChatSurface }
    res: { sessionInfo: ChatSessionInfo | null; carried: CarryoverStats | null }
  }
  /** Conversation list for a course (zero-message conversations excluded). Defaults to app. */
  'chat:conversations': {
    req: { courseId: string; surface?: ChatSurface }
    res: { conversations: ChatConversationSummary[] }
  }
  /** Soft-deletes a conversation and closes its warm CLI process, if any. */
  'chat:deleteConversation': {
    req: { courseId: string; sessionId: string }
    res: { ok: true }
  }
  'chat:grants': {
    req: { courseId: string }
    res: {
      grants: Array<{ id: string; rule: string; createdAt: string }>
    }
  }
  'chat:revokeGrant': {
    req: { id: string }
    res: { ok: true }
  }
  'desktopAgent:permissionStatus': {
    req: Record<string, never>
    res: { state: ScreenPermissionState; platform: NodeJS.Platform }
  }
  'desktopAgent:openPermissionSettings': {
    req: Record<string, never>
    res: { ok: true }
  }

  // -- extensions (real plugins, `src/main/features/plugins`) ---------------
  /** Installed extensions with their state; renderer mirrors via `plugins:changed`. */
  'plugins:list': { req: Record<string, never>; res: { plugins: PluginSummary[] } }
  'plugins:devFolders': { req: Record<string, never>; res: { folders: Array<{ id: string; path: string }> } }
  'plugins:watchFolder': { req: { path: string }; res: { ok: true } }
  'plugins:unwatchFolder': { req: { id: string }; res: { ok: true } }
  'marketplace:dashboard': { req: Record<string, never>; res: import('../types/marketplace').MarketplaceDashboard }
  'marketplace:release': { req: { id: string }; res: import('../types/marketplace').MarketplaceRelease }
  'marketplace:resolveReport': { req: { id: string; reason: string }; res: { ok: true } }
  'marketplace:register': { req: { id: string; displayName: string }; res: { ok: true } }
  'marketplace:submit': { req: { changelog: string }; res: { canceled: boolean } }
  'marketplace:review': { req: { id: string; decision: 'approved' | 'rejected' | 'withdrawn'; reason: string }; res: { ok: true } }
  'marketplace:reviewBundle': { req: { id: string }; res: { canceled: boolean } }
  'marketplace:report': { req: { releaseId: string; reason: string }; res: { ok: true } }
  'plugins:getSettings': { req: { id: string }; res: { values: Record<string, unknown> } }
  'plugins:editorReply': { req: { requestId: string; value: unknown; error?: string }; res: { ok: true } }
  'plugins:setSetting': { req: { id: string; key: string; value: unknown }; res: { values: Record<string, unknown> } }
  'plugins:resetSettings': { req: { id: string }; res: { values: Record<string, unknown> } }
  /** Native folder picker for `plugins:installFromFolder`. */
  'plugins:pickFolder': { req: Record<string, never>; res: { path: string | null } }
  /** Validates and copies a plugin folder into userData; installed disabled + needs approval. */
  'plugins:installFromFolder': {
    req: { path: string }
    res: { plugin: PluginSummary; warnings: string[] }
  }
  'plugins:uninstall': { req: { id: string }; res: { ok: true } }
  /** Enabling an unapproved plugin returns it in `needs-approval` instead. */
  'plugins:setEnabled': {
    req: { id: string; enabled: boolean }
    res: { plugin: PluginSummary }
  }
  /** Records the manifest's current permissions (and hash) as approved. */
  'plugins:approve': { req: { id: string }; res: { plugin: PluginSummary } }
  'plugins:reload': { req: { id: string }; res: { plugin: PluginSummary } }
  'plugins:runCommand': {
    req: { pluginId: string; commandId: string; context?: { courseId: string; relPath: string } }
    res: { ok: true }
  }
  /** Ring buffer of recent plugin log lines (denials included); null = all plugins. */
  'plugins:logs': {
    req: { id: string | null }
    res: { entries: PluginLogEntry[] }
  }

  // -- user MCP registry ---------------------------------------------------
  'mcp:list': {
    req: Record<string, never>
    res: { servers: McpServerSummary[]; availability: McpAvailability }
  }
  'mcp:save': {
    req: McpServerInput
    res: { server: McpServerSummary }
  }
  'mcp:delete': {
    req: { id: string }
    res: { ok: true }
  }
  'mcp:test': {
    req: { id: string }
    res: McpTestResult
  }

  // -- agent ----------------------------------------------------------------
  'agent:availability': {
    req: { provider: AgentProvider; refresh?: boolean }
    res: AgentAvailability
  }
  /** Models the installed CLI reports. Cached in main for the process lifetime. */
  'agent:skills': {
    req: { provider: AgentProvider; courseId: string }
    res: import('../types/chatCapabilities').ChatSkill[]
  }
  'chat:importAttachments': {
    req: { courseId: string; paths: string[] }
    res: { name: string; relPath: string }[]
  }
  'chat:openArtifact': {
    req: { courseId: string; relPath: string }
    res: { ok: true }
  }
  'chat:pickAttachments': {
    req: Record<string, never>
    res: { paths: string[] }
  }
  'agent:models': {
    req: { provider: AgentProvider; refresh?: boolean }
    res: AgentModelCatalog
  }

  // -- pdf drawings (free-form markup: pen, shapes, text boxes) --------------
  'drawings:listForFile': {
    req: { courseId: string; relPath: string }
    res: Drawing[]
  }
  'drawings:create': {
    req: CreateDrawingInput
    res: Drawing
  }
  'drawings:update': {
    req: UpdateDrawingInput
    res: Drawing
  }
  'drawings:delete': {
    req: { ids: string[] }
    res: { ok: true }
  }
  /** Burns highlights + drawings into a NEW pdf; the original is never touched. */
  'pdf:exportAnnotated': {
    req: ExportAnnotatedPdfInput
    res: ExportAnnotatedPdfResult
  }

  // -- favorites (left-rail pins; any TabDescriptor) ------------------------
  'favorites:list': {
    req: { courseId: string | null }
    res: Favorite[]
  }
  'favorites:add': {
    req: CreateFavoriteInput
    res: Favorite
  }
  'favorites:rename': {
    req: RenameFavoriteInput
    res: Favorite
  }
  'favorites:remove': {
    req: { id: string }
    res: { ok: true }
  }
  'favorites:reorder': {
    req: ReorderFavoritesInput
    res: { ok: true }
  }

  // -- agent setup ----------------------------------------------------------
  /** The exact shell command `agent:install` would run, for display first. */
  'agent:installCommand': {
    req: { provider: AgentProvider }
    res: { command: string; supported: boolean }
  }
  /**
   * Runs the provider's official installer after an explicit Connect click.
   * Installation details are available through `agent:installCommand`.
   * Progress streams via the `agent:install-progress` push event.
   */
  'agent:install': {
    req: { provider: AgentProvider }
    res: { ok: boolean; message: string }
  }
  /** Managed login. Progress opens the Bandal browser; resolves after auth verification. */
  'agent:login': {
    req: { provider: AgentProvider; requestId?: string }
    res: { ok: boolean; message: string; requiresUpdate?: boolean }
  }
  'agent:cancelLogin': {
    req: { provider: AgentProvider; requestId?: string }
    res: { ok: boolean }
  }
  'agent:reopenLogin': {
    req: { provider: AgentProvider; requestId?: string; external?: boolean }
    res: { ok: boolean; message: string }
  }
  'agent:submitLoginCode': {
    req: { provider: AgentProvider; requestId?: string; code: string }
    res: { ok: boolean; message: string }
  }

  // -- browser session ------------------------------------------------------
  /** Signed-in sites in the browsing partition, for the settings list. */
  'browser:sessionSites': {
    req: { profileId?: string }
    res: { sites: { origin: string; cookieCount: number }[] }
  }
  /** Forgets one origin's cookies, or all of them when origin is null. */
  'browser:clearSession': {
    req: { profileId?: string; origin: string | null }
    res: { ok: true }
  }
  /**
   * Register a tab's course before its first navigation. Child windows
   * inherit this context; switching the sidebar never changes ownership.
   */
  'browser:setDownloadTarget': {
    req: { courseId: string | null; webContentsId: number; tabId: string }
    res: { ok: true }
  }
  'browser:setCourse': {
    req: { tabId: string; courseId: string | null; expectedWebContentsId: number; revision: number }
    res: { ok: boolean }
  }
  'browser:prepareProfileSwitch': { req: { tabId: string }; res: { allowed: boolean } }
  'browser:profiles': { req: {}; res: import('../types/browserProfile').BrowserProfile[] }
  'browser:saveProfile': { req: { id?: string; name: string; color: string; icon: string }; res: import('../types/browserProfile').BrowserProfile }
  'browser:deleteProfile': { req: { id: string }; res: { ok: true } }
  'browser:createPage': {
    req: { tabId: string; isPrivate: boolean; courseId: string | null; profileId?: string }
    res: { state: BrowserPageState; adopted: boolean }
  }
  'browser:pageBounds': {
    req: { tabId: string; bounds: { x: number; y: number; width: number; height: number } | null; preview?: boolean }
    res: { snapshot: string | null }
  }
  /** Blocks every native page owned by this window, including pages created later. */
  'browser:setHostOccluded': { req: { occluded: boolean }; res: { ok: true } }
  'browser:pageAction': {
    req: { tabId: string; action: BrowserPageAction; args: unknown[] }
    res: unknown
  }
  'browser:destroyPage': { req: { tabId: string; expectedWebContentsId?: number }; res: { ok: true } }
  'clipboard:beginCopy': { req: {}; res: { token: number } }
  'clipboard:writeImage': {
    req: { token: number; png: string | null; html: string; text: string }
    res: { written: boolean }
  }
  'browser:downloadFile': {
    req: { id: string; action: 'open' | 'reveal' | 'saveAs' | 'retry' }
    res: { ok: true }
  }

  // -- browser history ------------------------------------------------------
  /** Upsert on visit. A revisit bumps the count, it does not append a row. */
  'browser:recordVisit': {
    req: { profileId?: string; url: string; title: string; courseId: string | null }
    res: { ok: true }
  }
  /** Ranked omnibox candidates. Empty query returns recent visits. */
  'browser:searchHistory': {
    req: { profileId?: string; query: string; limit?: number }
    res: {
      entries: {
        url: string
        title: string
        host: string
        visitCount: number
        lastVisitedAt: string
      }[]
    }
  }
  /** `null` clears everything; a course id clears just that course's rows. */
  'browser:clearHistory': {
    req: { profileId?: string; courseId: string | null }
    res: { ok: true }
  }
  /**
   * Which course an LMS page belongs to, by its saved course links. null when
   * nothing matches or the answer is ambiguous — never a guess.
   */
  'browser:courseForUrl': {
    req: { url: string }
    res: { courseId: string | null }
  }
  /**
   * A page's favicon as a `data:` URL. Fetched in main because the renderer
   * CSP blocks remote images — see main/features/browser/favicon.ts for why
   * relaxing it is the wrong trade.
   */
  'browser:favicon': {
    req: { isPrivate?: boolean; profileId?: string; url: string }
    res: { dataUrl: string | null }
  }

  // -- agent browser access ---------------------------------------------------
  /**
   * Live and past access grants. Revoked ones stay listed so a student can see
   * that a permission existed — backlog §5.8's complaint about the tool grant
   * is precisely that it was invisible.
   */
  'browserAgent:grants': {
    req: Record<string, never>
    res: {
      grants: {
        id: string
        courseId: string
        origin: string
        capability: 'read' | 'interact' | 'download'
        createdAt: string
        expiresAt: string
        revokedAt: string | null
        lastUsedAt: string | null
      }[]
    }
  }
  'browserAgent:revokeGrant': {
    req: { id: string }
    res: { ok: true }
  }
  /** What the agent actually did, newest first. */
  /**
   * Renderer tells main which guest belongs to which browser tab.
   *
   * Agent actions address a stable tabId while page events carry a WebContents
   * id. Pushed on every `dom-ready`, so recovery can refresh the association.
   */
  'browserAgent:registerTab': {
    req: {
      tabId: string
      webContentsId: number
      /** Echoed from `browser:open-url` when the agent asked for this tab. */
      openRequestId?: string
    }
    res: { ok: true }
  }
  /**
   * Renderer publishes the browser tabs the student can actually see.
   *
   * Restored tabs are listed before their pages are lazily created, so the
   * native page registry alone cannot describe the complete workspace.
   * Pushed whenever the set changes; self-healing like `registerTab`.
   */
  'browserAgent:syncTabs': {
    req: {
      courseId: string
      tabs: {
        tabId: string
        title: string
        url: string
        /** The page has not been created yet; reading it must wake it first. */
        asleep: boolean
      }[]
      activeTabId: string | null
    }
    res: { ok: true }
  }
  /**
   * Renderer publishes what the student is looking at in the APP.
   *
   * Sibling of `browserAgent:syncTabs`, and the half that was missing: the
   * agent could see the web and nothing of Bandal, so "학기를 바꿔줘" — meaning
   * the sidebar's 2026년 1학기 group — had only one resolvable referent, a
   * `<select>` on the portal.
   */
  'agent:syncWorkspace': {
    req: {
      activeKind?: string
      selectedCourseId: string | null
      tabs: { kind: string; title: string; active: boolean; courseId?: string; relPath?: string; documentId?: string }[]
      documents?: import('../types/chatContext').MaterialContext[]
      selection?: string
      refreshId?: string
    }
    res: { ok: true }
  }
  /** Stops a run immediately; the next action throws rather than proceeding. */
  'browserAgent:stopRun': {
    req: { runId: string }
    res: { ok: true }
  }
  /** The student took the wheel and pressed 계속. */
  'browserAgent:resumeRun': {
    req: { runId: string }
    res: { ok: true }
  }
  'browserAgent:auditTail': {
    req: { courseId: string | null; limit?: number }
    res: {
      entries: {
        id: string
        courseId: string
        action: string
        url: string
        detail: string
        createdAt: string
      }[]
    }
  }

  // -- course activity + AI study tools -------------------------------------
  /**
   * Appends one activity event. Most events are recorded in the main process
   * where the actions already funnel through IPC; this channel exists for the
   * few that only the renderer knows about (which tab the student opened).
   */
  'activity:record': {
    req: RecordActivityInput
    res: { ok: true }
  }
  'activity:recent': {
    req: { courseId: string; limit?: number }
    res: ActivityEvent[]
  }
  /** Rebuilds the `.bandal/` dossier the agent reads. Idempotent. */
  'context:rebuild': {
    req: { courseId: string }
    res: { relPath: string }
  }
  'study:tools': {
    req: Record<string, never>
    res: { tools: WorkflowPackToolDefinition[] }
  }
  /**
   * Runs a study recipe through the course's agent session. The answer is
   * written into the course folder as markdown rather than returned inline, so
   * it is editable, survives the session and feeds later questions.
   */
  'study:run': {
    req: RunWorkflowPackStudyInput
    res: RunStudyToolResult
  }
  'packs:list': {
    req: {}
    res: { packs: WorkflowPackSummary[] }
  }
  'packs:importText': {
    req: { json: string }
    res: { pack: WorkflowPack; warnings: string[] }
  }
  'packs:remove': {
    req: { id: string }
    res: { ok: true }
  }
  'packs:setEnabled': {
    req: { id: string; enabled: boolean }
    res: { ok: true }
  }

  // -- personal whiteboards (local only) -------------------------------------
  //
  // Prefixed `canvas:` rather than `board:` because `board:` already means the
  // study TASK board (board:listTasks / createTask). Two unrelated features
  // under one prefix is how a handler ends up wired to the wrong repo.
  'canvas:list': {
    req: { courseId: string }
    res: PersonalBoard[]
  }
  'canvas:create': {
    req: CreatePersonalBoardInput
    res: PersonalBoard
  }
  'canvas:rename': {
    req: RenamePersonalBoardInput
    res: PersonalBoard
  }
  'canvas:remove': {
    req: { id: string }
    res: { ok: true }
  }
  'canvas:open': {
    req: { boardId: string }
    res: OpenPersonalBoardResult
  }
  'canvas:hoverPreview': {
    req: { boardId: string }
    res: OpenPersonalBoardResult
  }
  'canvas:putShape': {
    req: PutPersonalShapeInput
    res: DrawingShape
  }
  /** Paper style for a personal board — ruling and light/dark. */
  /** Adds or removes trailing pages. Never drops a page that has shapes. */
  'canvas:setPageCount': {
    req: SetBoardPageCountInput
    res: PersonalBoard
  }
  'canvas:setBackground': {
    req: SetBoardBackgroundInput
    res: PersonalBoard
  }
  /** Renders the board to a PDF in the course folder. */
  'canvas:exportPdf': {
    req: { boardId: string }
    res: { relPath: string }
  }
  'canvas:removeShapes': {
    req: RemovePersonalShapesInput
    res: { ok: true }
  }

  // -- calendar + deadlines ---------------------------------------------------
  /** Entries whose due date falls in [from, to) — one query per month view. */
  'appleCalendar:state': { req: Record<string, never>; res: AppleCalendarState }
  'appleCalendar:connect': { req: Record<string, never>; res: AppleCalendarState }
  'appleCalendar:disconnect': { req: Record<string, never>; res: AppleCalendarState }
  'appleCalendar:configure': { req: Pick<AppleCalendarPreferences, 'selectedCalendarIds' | 'destinationCalendarId'>; res: AppleCalendarState }
  'appleCalendar:events': { req: { from: string; to: string }; res: AppleCalendarEvent[] }
  'appleCalendar:export': { req: { taskId: string }; res: { eventId: string; updated: boolean } }
  'appleCalendar:permissions': { req: Record<string, never>; res: { ok: true } }
  'calendar:range': {
    req: CalendarRangeInput
    res: BoardTask[]
  }
  /** Deadlines from now forward, already resolved to days-left. */
  'calendar:upcoming': {
    req: { courseId?: string | null; withinDays?: number; limit?: number }
    res: UpcomingDeadline[]
  }

  // -- full-text search across course material --------------------------------
  /**
   * Searches inside notes and PDF text, not just filenames.
   * PDF pages are indexed lazily — the renderer already extracts page text for
   * highlighting, so it hands that over rather than parsing twice in main.
   */
  'search:query': {
    req: { courseId: string; query: string; limit?: number }
    res: { hits: SearchHit[] }
  }
  'search:indexPdfPages': {
    req: {
      courseId: string
      relPath: string
      pages: { page: number; text: string }[]
    }
    res: { ok: true }
  }

  // -- download controls ------------------------------------------------------
  /**
   * Cancel / pause / resume a live transfer.
   *
   * The only control that existed was 닫기, which removed the row while the
   * transfer kept running invisibly — quitting the app was the only way to
   * stop a 2GB video on tethering.
   */
  'browser:controlDownload': {
    req: { id: string; action: 'cancel' | 'pause' | 'resume' }
    res: { ok: true }
  }
  /** Clears cache and site storage, not just cookies. */
  'browser:clearStorage': {
    req: { profileId?: string; origin: string | null; cache: boolean }
    res: { ok: true }
  }

  // -- site permissions -------------------------------------------------------
  /** Every camera/location/notification answer the student has given. */
  'browser:sitePermissions': {
    req: { profileId?: string; }
    res: {
      permissions: {
        id: string
        origin: string
        permission: string
        decision: 'granted' | 'denied'
        decidedAt: string
      }[]
    }
  }
  /** `id: null` forgets every remembered answer. */
  'browser:forgetPermission': {
    req: { profileId?: string; id: string | null }
    res: { ok: true }
  }
  /** Updates the site-specific popup allowlist used by strict mode. */
  'browser:setPopupPermission': {
    req: { profileId?: string; origin: string; decision: 'granted' | 'denied' }
    res: { ok: true }
  }
  'browser:extensions': {
    req: { profileId?: string }
    res: { extensions: BrowserExtensionSummary[] }
  }
  'browser:installExtension': {
    req: { profileId?: string }
    res: { extension: BrowserExtensionSummary | null }
  }
  'browser:setExtensionEnabled': {
    req: { profileId?: string; path: string; enabled: boolean }
    res: { extensions: BrowserExtensionSummary[] }
  }
  'browser:removeExtension': {
    req: { profileId?: string; path: string }
    res: { extensions: BrowserExtensionSummary[] }
  }

  // -- printing ---------------------------------------------------------------
  /**
   * Prints PDF bytes the renderer already previewed.
   *
   * Deliberately not "print the tab": `printToPDF` and the platform print job
   * are different pipelines that disagree on pagination, so printing the live
   * page would not match what the student just looked at. See
   * features/print/printWindow.ts.
   */
  'print:pdf': {
    req: { base64: string; jobName: string }
    res: { ok: true; printed: boolean }
  }
  'print:savePdfAs': {
    req: { base64: string; suggestedName: string }
    res: { ok: true; canceled: boolean; savedPath: string | null }
  }
  /**
   * The bytes of a PDF the guest is already displaying.
   *
   * `printToPDF` does not rasterize plugin content, so a tab whose top-level
   * document IS a PDF would preview blank. Fetched on the browsing session so
   * the portal's own cookies carry.
   */
  'print:pdfFromUrl': {
    req: { url: string; tabId?: string }
    res: { base64: string }
  }
  /**
   * Enables or disables 파일 ▸ 인쇄….
   *
   * The menu item owns ⌘P, and a DISABLED menu item does not perform its key
   * equivalent — the event falls through to the renderer, where ⌘P is still
   * 빠른 파일 검색. That is the whole mechanism for making ⌘P mean two things.
   */
  'window:setPrintEnabled': {
    req: { enabled: boolean }
    res: { ok: true }
  }
  'window:getState': { req: {}; res: { fullscreen: boolean } }

  // -- note ↔ material links --------------------------------------------------
  'links:create': {
    req: {
      courseId: string
      source: TabDescriptor
      target: TabDescriptor
      kind?: import('../types/link').MaterialLinkKind
      label?: string
      metadata?: import('../types/link').PdfPageNoteLinkMetadata | null
    }
    res: MaterialLinkRecord
  }
  'links:updatePageNote': {
    req: {
      courseId: string
      id: string
      metadata: import('../types/link').PdfPageNoteLinkMetadata
    }
    res: MaterialLinkRecord
  }
  'links:remove': {
    req: { courseId: string; id: string }
    res: { ok: true }
  }
  'links:listFor': {
    req: { courseId: string; relPath: string }
    res: {
      outgoing: MaterialLinkRecord[]
      incoming: MaterialLinkRecord[]
    }
  }
  /**
   * Like `links:listFor`, but addressed by TabDescriptor so pathless tabs
   * (browser) can find their own links too. Path-backed kinds fall back to
   * the relPath comparison; browser tabs match by canonical descriptor JSON.
   */
  'links:listForDescriptor': {
    req: { courseId: string; descriptor: TabDescriptor }
    res: {
      outgoing: MaterialLinkRecord[]
      incoming: MaterialLinkRecord[]
    }
  }
  /**
   * Appends a highlight to a note as a quote plus a `bandal://` link back to
   * the exact page. The note stays plain markdown.
   */
  /**
   * Everything that cites this material — notes that quote it, whiteboards
   * that pin a clip of it. Derived on demand from note text and clip payloads;
   * see `main/features/links`.
   */
  'links:forMaterial': {
    req: { courseId: string; relPath: string }
    res: MaterialBacklinks
  }
  /**
   * Everything the link graph needs in one round trip: all manual links plus
   * all citations, grouped by cited material. The backlink half rescans the
   * whole course — call on demand (open/refresh), never on materials:changed.
   */
  'links:graph': {
    req: { courseId: string }
    res: {
      links: MaterialLinkRecord[]
      backlinks: MaterialBacklinkGroup[]
    }
  }
  'link:sendHighlightToNote': {
    req: SendHighlightToNoteInput
    res: SendHighlightToNoteResult
  }
  /** Same destination as a PDF highlight, but the source is a web page. */
  'link:sendWebClipToNote': {
    req: SendWebClipToNoteInput
    res: SendHighlightToNoteResult
  }

  // -- saved site logins ------------------------------------------------------
  'credentials:availability': {
    req: { profileId?: string }
    res: CredentialsAvailability
  }
  /** Summaries only — a stored password is never returned to the renderer. */
  'credentials:list': {
    req: { profileId?: string }
    res: SavedLoginSummary[]
  }
  /** Metadata edits from the settings window. Send `password: ''` to keep it. */
  'credentials:save': {
    req: SaveLoginInput & { profileId?: string }
    res: SavedLoginSummary
  }
  /**
   * Saves what the student just typed into the login form in this guest. Main
   * reads the field and stores it, so the password never enters this window.
   * `null` means nothing was typed, so there is nothing to offer saving.
   */
  'credentials:capture': {
    req: { origin: string; guestWebContentsId: number; autoSubmit?: boolean; mode?: 'save' | 'stage' | 'commit' | 'discard' }
    res: SavedLoginSummary | null
  }
  'credentials:forget': {
    req: { profileId?: string; origin: string; credentialId?: string }
    res: { ok: true }
  }
  /** Imports Chrome/Edge/Arc/Firefox CSV via a native picker; bytes stay in main. */
  'credentials:importCsv': {
    req: { profileId?: string }
    res: CredentialsImportResult
  }
  /** Imports Netscape bookmark HTML into app-wide browser favorites. */
  'browser:importBookmarks': {
    req: Record<string, never>
    res: { imported: number; skipped: number; cancelled: boolean }
  }
  'browser:importSources': { req: Record<string, never>; res: BrowserImportSource[] }
  'browser:importFile': { req: { kind: BrowserImportFileKind }; res: BrowserImportSource | null }
  'browser:importStart': { req: BrowserImportRequest; res: BrowserImportJob }
  'browser:importJob': { req: { jobId: string }; res: BrowserImportJob | null }
  'browser:importCancel': { req: { jobId: string }; res: { cancelled: boolean } }
  'browser:prepareClose': { req: { tabId: string }; res: { allowed: boolean } }
  /**
   * Fills the login form in the browser guest showing `origin`. Main resolves
   * the secret and injects it; the renderer only ever names the origin.
   */
  'credentials:fill': {
    req: { origin: string; guestWebContentsId: number; credentialId?: string }
    res: FillLoginResult
  }

  // -- assistant actions on the app -----------------------------------------
  /** Everything the assistant changed in one request, for the change list. */
  'agentTools:changes': {
    req: { turnId: string }
    res: AgentTurnChanges
  }
  /** Takes back the creations from one request. Deletes are not undoable. */
  'agentTools:undo': {
    req: { turnId: string }
    res: {
      undone: number
      results: Array<{ actionId: string; ok: boolean; error?: string }>
    }
  }
  /** Answer to a destructive tool waiting for the student. */
  'agentTools:respondConfirm': {
    req: AgentConfirmResponse
    res: { ok: true; state?: import('../types/agentTools').AgentConfirmationState | null }
  }

  // -- settings -------------------------------------------------------------
  'settings:get': {
    req: Record<string, never>
    res: Settings
  }
  'settings:set': {
    req: SettingsPatch
    res: Settings
  }
  /**
   * [R3] Opens the native directory picker for a new dataRoot. Validates the
   * chosen folder is writable, persists it (settings:changed broadcasts the
   * update), and returns the new value. `null` = the user cancelled.
   * Existing courses keep their absolute folder paths and are untouched.
   */
  'settings:pickDataRoot': {
    req: Record<string, never>
    res: { dataRoot: string } | null
  }

  /**
   * [v0.37] 설정 초기화. dataRoot·locale·onboarding·tutorial·university·
   * milestones·lastActiveCourseId 는 보존하고 나머지를 기본값으로 되돌린다.
   * 저장 + settings:changed 브로드캐스트까지 포함한다.
   */
  'settings:reset': {
    req: Record<string, never>
    res: Settings
  }

  // -- notifications (v0.37) -----------------------------------------------
  /** 설정 패널의 "테스트 알림 보내기". 알림이 꺼져 있어도 보낸다. */
  'notifications:test': {
    req: Record<string, never>
    res: { ok: boolean; reason: 'unsupported' | null }
  }

  // -- app maintenance (v0.37 고급 패널) --------------------------------------
  /** 로그 폴더를 OS 파일 관리자로 연다. */
  'app:openLogs': {
    req: Record<string, never>
    res: { ok: true }
  }
  /** 브라우징 세션의 HTTP 캐시와 반달 썸네일 캐시를 비운다. */
  'app:clearCache': {
    req: Record<string, never>
    res: { ok: true }
  }

  // -- usage ledger (v0.39) -------------------------------------------------
  /** Aggregated AI usage for settings > 사용 통계. */
  'usage:summary': {
    req: { windowDays: UsageWindowDays }
    res: UsageSummary
  }

  // -- plugin catalog (v0.40) -----------------------------------------------
  /** Official + user sources merged. `refresh: false` serves the disk cache. */
  'plugins:catalog': {
    req: { refresh: boolean }
    res: PluginCatalog
  }
  /** Download → sha256 verify → existing install path (folder / pack json). */
  'plugins:installFromCatalog': {
    req: { sourceUrl: string; id: string }
    res: CatalogInstallResult
  }

  // -- system permissions & diagnostics (v0.41) -----------------------------
  'permissions:status': {
    req: Record<string, never>
    res: SystemPermissionsReport
  }
  /** Triggers the OS prompt when `canRequest`; returns the fresh status. */
  'permissions:request': {
    req: { id: SystemPermissionId }
    res: SystemPermissionStatus
  }
  /** Opens the OS privacy page for this permission (mac deep link, win ms-settings). */
  'permissions:openSettings': {
    req: { id: SystemPermissionId }
    res: { ok: true }
  }
  /**
   * Writes a redacted diagnostics text bundle to a temp folder and reveals it.
   * Nothing is uploaded; the user attaches it to feedback by hand.
   */
  'app:diagnostics': {
    req: Record<string, never>
    res: DiagnosticsBundle
  }

  // -- gemini api key (v0.41.1) --------------------------------------------
  /** Whether an API key is stored (safeStorage); `hint` = last 4 chars. */
  'agent:geminiApiKey': {
    req: Record<string, never>
    res: { configured: boolean; hint: string | null; storageAvailable: boolean }
  }
  /** null removes the key. Rejects when safeStorage is unavailable. */
  'agent:setGeminiApiKey': {
    req: { key: string | null }
    res: { configured: boolean; hint: string | null }
  }

  // -- layout (dockview persistence per course) -----------------------------
  'layout:get': {
    req: { courseId: string }
    res: { layout: unknown | null }
  }
  'layout:save': {
    req: { courseId: string; layout: unknown }
    res: { ok: true }
  }
  'layout:saveMany': {
    req: { layouts: Array<{ courseId: string; layout: unknown }> }
    res: { ok: true }
  }

  // -- auth -----------------------------------------------------------------
  /** Projected auth state. Never contains a token or an e-mail address. */
  'auth:getState': {
    req: Record<string, never>
    res: AuthState
  }
  /**
   * Opens the system browser and returns immediately (§1.1). `{ ok: true }`
   * means the browser opened, NOT that the user is signed in — the session
   * arrives later over `auth:changed`, once `bandal://auth/callback` comes
   * back. Refusals are typed values, never thrown errors.
   */
  'auth:signIn': {
    req: { provider: AuthProvider }
    res: AuthSignInResult
  }
  'auth:signOut': {
    req: Record<string, never>
    res: { ok: true }
  }
  /** Globally unique, 2–16 chars of `[가-힣a-zA-Z0-9_]` (§2.1). */
  'auth:setNickname': {
    req: { nickname: string }
    res: MyProfile
  }

  // -- auto update ----------------------------------------------------------
  /** Current state, for a freshly mounted UI. Never triggers a network call. */
  'update:status': {
    req: Record<string, never>
    res: UpdateStatus
  }
  /**
   * Explicit "check for updates" from Settings → About. Resolves once the
   * check settles; progress also arrives on the `update:changed` push channel.
   */
  'update:check': {
    req: Record<string, never>
    res: UpdateStatus
  }
  /** Starts the download. No-op unless the phase is `available` or `error`. */
  'update:download': {
    req: Record<string, never>
    res: UpdateStatus
  }
  /**
   * Quits and installs a staged update. Returns only if the install could not
   * start — on success the process is already gone.
   */
  'update:install': {
    req: Record<string, never>
    res: { ok: boolean }
  }
  'feedback:send': {
    req: {
      kind: 'bug' | 'friction' | 'feature'
      body: string
      includeAppInfo: boolean
    }
    res:
      | { ok: true }
      | { ok: false; reason: 'rate-limited' | 'unavailable' }
  }
}

export type IpcChannel = keyof IpcContract
export type IpcRequest<K extends IpcChannel> = IpcContract[K]['req']
export type IpcResponse<K extends IpcChannel> = IpcContract[K]['res']

/**
 * Every channel in `IpcContract`, as a VALUE.
 *
 * A type alone cannot be enumerated at runtime, so nothing stopped a channel
 * from being declared in the contract, called type-safely from the renderer,
 * and having no main-process handler — `tsc` and `vitest` both stayed green
 * and the app failed at runtime with "No handler registered for ...". That is
 * exactly how `favorites:*` shipped half-wired.
 *
 * The two `satisfies`/`Exclude` checks below make the list and the contract
 * prove each other: adding a channel to `IpcContract` without adding it here
 * fails to compile, and `registerHandlers` asserts at boot that every entry
 * here actually got a handler.
 */
export const IPC_CHANNELS = [
  ...STUDY_MARKET_CHANNELS,
  ...LEARNING_CHANNELS,
  ...RECORDING_CHANNELS,
  'presentation:runtime', 'presentation:installRuntime', 'presentation:cancelRuntime',
  'presentation:prepare', 'presentation:cancelPrepare', 'presentation:pdfStart',
  'presentation:pdfPage', 'presentation:pdfFinish', 'presentation:pdfCancel',
  'mail:state', 'mail:connect', 'mail:cancelConnect', 'mail:disconnect',
  'mail:list', 'mail:read', 'mail:modify', 'mail:reply',
  'courses:list',
  'courses:create',
  'courses:pickFolder',
  'courses:addFromFolder',
  'courses:relink',
  'courses:rename',
  'courses:setColor',
  'courses:archive',
  'courses:delete',
  'courses:purge',
  'courses:organize',
  'courseGroups:list',
  'courseGroups:create',
  'courseGroups:rename',
  'courseGroups:delete',
  'courseLinks:list',
  'courseLinks:create',
  'courseLinks:update',
  'courseLinks:delete',
  'shell:openExternal',
  'materials:snapshot',
  'materials:tree',
  'materials:search',
  'materials:import',
  'materials:move',
  'materials:reveal',
  'materials:preview',
  'materials:readFile',
  'materials:hoverPreview',
  'materials:watch',
  'materials:rename',
  'materials:delete',
  'materials:duplicate',
  'materials:writeFile',
  'materials:createFolder',
  'materials:downloadFromUrl',
  'materials:unwatch',
  'media:getProgress',
  'media:setProgress',
  'pdf:getViewState',
  'pdf:setViewState',
  'ui:consumePendingOpen',
  'pip:open',
  'pip:close',
  'pip:restore',
  'pip:getState',
  'pip:report',
  'pip:moveBy',
  'notes:read',
  'notes:write',
  'notes:create',
  'notes:rename',
  'annotations:listForFile',
  'annotations:create',
  'annotations:update',
  'annotations:delete',
  'board:listTasks',
  'board:createTask',
  'board:updateTask',
  'board:reorderTasks',
  'board:deleteTask',
  'chat:context',
  'assistant:capture',
  'assistant:selection',
  'chat:accessPolicy',
  'chat:open',
  'chat:send',
  'chat:cancel',
  'chat:respondPermission',
  'chat:close',
  'chat:setModel',
  'chat:setConfiguration',
  'agentTools:confirmations',
  'chat:setProvider',
  'chat:conversations',
  'chat:deleteConversation',
  'chat:grants',
  'chat:revokeGrant','desktopAgent:permissionStatus',
  'desktopAgent:openPermissionSettings',
  'plugins:list',
  'plugins:devFolders',
  'plugins:watchFolder',
  'plugins:unwatchFolder',
  'marketplace:dashboard',
  'marketplace:release',
  'marketplace:resolveReport',
  'marketplace:register',
  'marketplace:submit',
  'marketplace:review',
  'marketplace:reviewBundle',
  'marketplace:report',
  'plugins:getSettings',
  'plugins:editorReply',
  'plugins:setSetting',
  'plugins:resetSettings',
  'plugins:pickFolder',
  'plugins:installFromFolder',
  'plugins:uninstall',
  'plugins:setEnabled',
  'plugins:approve',
  'plugins:reload',
  'plugins:runCommand',
  'plugins:logs',
  'mcp:list',
  'mcp:save',
  'mcp:delete',
  'mcp:test',
  'agent:availability',
  'agent:models',
  'agent:skills',
  'chat:pickAttachments',
  'chat:openArtifact',
  'chat:importAttachments',
  'drawings:listForFile',
  'drawings:create',
  'drawings:update',
  'drawings:delete',
  'pdf:exportAnnotated',
  'favorites:list',
  'favorites:add',
  'favorites:rename',
  'favorites:remove',
  'favorites:reorder',
  'agent:installCommand',
  'agent:install',
  'agent:login',
  'agent:cancelLogin',
  'agent:reopenLogin',
  'agent:submitLoginCode',
  'browser:sessionSites',
  'browser:clearSession',
  'browser:setDownloadTarget',
  'browser:setCourse',
  'browser:recordVisit',
  'browser:searchHistory',
  'browser:clearHistory',
  'browser:courseForUrl',
  'browser:favicon',
  'browserAgent:grants',
  'browserAgent:revokeGrant',
  'browserAgent:auditTail',
  'browser:controlDownload',
  'browser:downloadFile',
  'browser:prepareProfileSwitch','browser:profiles',
  'browser:saveProfile',
  'browser:deleteProfile',
  'browser:createPage',
  'browser:pageBounds',
  'browser:setHostOccluded',
  'browser:pageAction',
  'browser:destroyPage',
  'clipboard:beginCopy',
  'clipboard:writeImage',
  'browser:clearStorage',
  'browser:sitePermissions',
  'browser:forgetPermission',
  'browser:setPopupPermission',
  'browser:extensions',
  'browser:installExtension',
  'browser:setExtensionEnabled',
  'browser:removeExtension',
  'print:pdf',
  'print:savePdfAs',
  'print:pdfFromUrl',
  'window:setPrintEnabled',
  'window:getState',
  'browserAgent:registerTab',
  'browserAgent:syncTabs',
  'agent:syncWorkspace',
  'browserAgent:stopRun',
  'browserAgent:resumeRun',
  'agentTools:changes',
  'agentTools:undo',
  'agentTools:respondConfirm',
  'settings:get',
  'settings:set',
  'settings:pickDataRoot',
  'settings:reset',
  'notifications:test',
  'app:openLogs',
  'app:clearCache',
  'usage:summary',
  'plugins:catalog',
  'plugins:installFromCatalog',
  'permissions:status',
  'permissions:request',
  'permissions:openSettings',
  'app:diagnostics',
  'agent:geminiApiKey',
  'agent:setGeminiApiKey',
  'layout:get',
  'layout:save',
  'layout:saveMany',
  'auth:getState',
  'auth:signIn',
  'auth:signOut',
  'auth:setNickname',
  'update:status',
  'update:check',
  'update:download',
  'update:install',
  'feedback:send',
  'activity:record',
  'activity:recent',
  'context:rebuild',
  'study:tools',
  'study:run',
  'packs:list',
  'packs:importText',
  'packs:remove',
  'packs:setEnabled','canvas:list',
  'canvas:create',
  'canvas:rename',
  'canvas:remove',
  'canvas:open',
  'canvas:hoverPreview',
  'canvas:putShape',
  'canvas:setPageCount',
  'canvas:setBackground',
  'canvas:exportPdf',
  'canvas:removeShapes',
  'appleCalendar:state',
  'appleCalendar:connect',
  'appleCalendar:disconnect',
  'appleCalendar:configure',
  'appleCalendar:events',
  'appleCalendar:export',
  'appleCalendar:permissions',
  'calendar:range',
  'calendar:upcoming',
  'search:query',
  'search:indexPdfPages','links:create',
  'links:updatePageNote',
  'links:remove',
  'links:listFor',
  'links:listForDescriptor',
  'links:forMaterial',
  'links:graph',
  'link:sendHighlightToNote',
  'link:sendWebClipToNote','credentials:availability',
  'credentials:list',
  'credentials:save',
  'credentials:capture',
  'credentials:forget',
  'credentials:importCsv',
  'browser:importBookmarks',
  'browser:importSources',
  'browser:importFile',
  'browser:importStart',
  'browser:importJob',
  'browser:importCancel',
  'browser:prepareClose',
  'credentials:fill'
] as const satisfies readonly IpcChannel[]

// Fails to compile if a contract channel is missing from IPC_CHANNELS.
type MissingFromList = Exclude<IpcChannel, (typeof IPC_CHANNELS)[number]>
const _allChannelsListed: MissingFromList extends never ? true : never = true
void _allChannelsListed
