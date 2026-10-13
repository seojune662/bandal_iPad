/**
 * Course activity log + the AI study tools built on top of it.
 *
 * Why an activity log exists at all: the agent runs with the course folder as
 * its cwd and blanket Read/Glob/Grep, so it can already see *files*. What it
 * could never see is what the student actually DID — which slide they
 * highlighted, which task they finished, what they asked last week. All of
 * that lived in SQLite, invisible. These events are the missing half, and they
 * are surfaced to the agent as a generated dossier under `.bandal/` inside the
 * course folder (dotfiles are skipped by the materials indexer and watcher, so
 * it stays invisible in the UI while remaining trivially readable by the CLI).
 */

export type ActivityKind =
  | 'material-added'
  | 'material-opened'
  | 'note-created'
  | 'note-edited'
  | 'highlight-created'
  | 'drawing-created'
  | 'task-created'
  | 'task-completed'
  | 'question-asked'
  | 'study-tool-run'

export interface ActivityEvent {
  id: string
  courseId: string
  kind: ActivityKind
  /** Course-relative path when the event is about a file. */
  relPath: string | null
  /** One human-readable line. Already trimmed — this is what the dossier shows. */
  summary: string
  createdAt: string
}

export interface RecordActivityInput {
  courseId: string
  kind: ActivityKind
  relPath?: string | null
  summary: string
}

// -- AI study tools -----------------------------------------------------------

/**
 * The recipes. Each turns a target document (or the whole course) into a
 * markdown artifact saved back into the course folder, so the result is
 * editable, survives the session, and becomes context for later questions.
 */
export type StudyToolId =
  | 'summary'
  | 'quiz'
  | 'flashcards'
  | 'mindmap'
  | 'structured-notes'
  | 'exam-predictions'
  | 'explain'

export interface StudyToolDefinition {
  id: StudyToolId
  /** Korean label shown in menus. */
  label: string
  /** One line describing what the student gets. */
  description: string
  /** False when the tool needs a specific file rather than the whole course. */
  worksOnCourse: boolean
}

export interface RunStudyToolInput {
  courseId: string
  tool: StudyToolId
  /** Target file; null runs against the whole course. */
  relPath: string | null
  /** Optional selected text to focus on (e.g. a highlighted passage). */
  selection?: string
  /** Validated live browser source, mutually exclusive with a file target. */
  browserTabUrl?: string
  browserTabId?: string
}

export interface RunStudyToolResult {
  /** Where the generated markdown was written, course-relative. */
  relPath: string
}
