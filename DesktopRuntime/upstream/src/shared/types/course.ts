/**
 * Course domain types.
 *
 * A course is a DB row plus a folder on disk. Two kinds of folder exist:
 *  - `managed`: created by Bandal under `<dataRoot>/<slug>` ("새 과목 만들기")
 *  - `linked`:  an arbitrary folder the user pointed at ("폴더에서 추가")
 * Everything downstream (materials tree, watcher, notes, annotations, the
 * path-traversal guard) scopes to `folderPath` — never to the data root.
 */

export type CourseSource = 'managed' | 'linked'
export type WorkspaceKind = 'course' | 'study-space'

export interface Course {
  /** Missing on old clients; the default is an ordinary course. */
  workspaceKind?: WorkspaceKind
  id: string
  name: string
  /** URL/filesystem-safe slug derived from the name. */
  slug: string
  /** Semantic color key or CSS color used for course identity. */
  color: string
  /** Absolute, symlink-resolved path to the course folder on disk. */
  folderPath: string
  /** How the folder came to be — see CourseSource. */
  source: CourseSource
  /**
   * True when `folderPath` is not a readable directory right now (moved,
   * deleted, unmounted or permission-denied). Computed on every read; the
   * UI surfaces it as 연결 끊김 and offers 다시 연결.
   */
  missing: boolean
  archived: boolean
  /** Present for explicitly requested deleted-space recovery; normal lists omit these rows. */
  deletedAt?: string | null
  /** 과목 그룹(학기) id, ungrouped일 때 null. */
  groupId: string | null
  sortOrder: number
  createdAt: string
  updatedAt: string
}

/**
 * 과목 그룹(학기). A named sidebar section; membership is `Course.groupId`,
 * so a course belongs to at most one group and null means ungrouped.
 */
export interface CourseGroup {
  id: string
  name: string
  sortOrder: number
  createdAt: string
  updatedAt: string
}

export interface CreateCourseInput {
  workspaceKind?: WorkspaceKind
  name: string
  color: string
}

export interface RenameCourseInput {
  courseId: string
  name: string
}

export interface SetCourseColorInput {
  courseId: string
  color: string
}

export interface AddCourseFromFolderInput {
  /** Absolute path to an existing folder. */
  folderPath: string
  /** Defaults to the folder's basename when omitted or blank. */
  name?: string
  color: string
}

export interface RelinkCourseInput {
  courseId: string
  folderPath: string
}

/** Why a folder could not be registered as (or re-linked to) a course. */
export type CourseFolderProblem = 'missing' | 'not-a-directory' | 'unreadable'

/**
 * Outcome of registering or re-linking a folder. `duplicate` is not an error:
 * `course` is the course that already owns the folder, so the caller can just
 * focus it.
 */
export type CourseFolderResult =
  | { status: 'ok'; course: Course }
  | { status: 'duplicate'; course: Course }
  | { status: 'failed'; reason: CourseFolderProblem }

/** A folder chosen in the native picker. */
export interface PickedFolder {
  /** Absolute, symlink-resolved path. */
  path: string
  /** Folder basename — the default course name. */
  name: string
}
