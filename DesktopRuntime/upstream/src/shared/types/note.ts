/**
 * Markdown note types. Notes are plain .md files inside the course folder;
 * the app reads/writes them through the main process.
 */

export interface NoteRef {
  courseId: string
  /** Path relative to the course folder root. */
  relPath: string
}

export interface NoteContent extends NoteRef {
  markdown: string
  /** mtime (epoch ms) at read time, for conflict detection on write. */
  mtime: number
}

export interface WriteNoteInput extends NoteRef {
  markdown: string
  /**
   * If provided, the write fails when the file changed on disk since this
   * mtime (optimistic concurrency).
   */
  expectedMtime?: number
}

export interface CreateNoteInput {
  courseId: string
  /** Directory (relative) in which to create the note; '' = course root. */
  dirRelPath: string
  /** Title used to derive the file name. */
  title: string
}
