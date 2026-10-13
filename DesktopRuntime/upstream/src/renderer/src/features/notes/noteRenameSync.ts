import { replaceNoteTitle } from '../../../../shared/noteTitle'

export interface NoteRenameResponse {
  relPath: string
  mtime: number
  title: string
  markdown: string
}

export interface NoteRenameState {
  currentMarkdown: string
  persistedMarkdown: string
  syncedTitle: string
  dirty: boolean
}

export interface NoteRenameSynchronization {
  sourceMarkdown: string
  title: string
  markdown: string
}

/**
 * Applies the canonical title/markdown returned by notes:rename. A body edit
 * made while rename was in flight is retained, but its H1 is still advanced
 * to the server-selected title (for example, a collision suffix).
 */
export function synchronizeNoteRename(
  currentMarkdown: string,
  markdownSentToRename: string,
  renamed: NoteRenameResponse
): NoteRenameState {
  const nextCurrent =
    currentMarkdown === markdownSentToRename
      ? renamed.markdown
      : replaceNoteTitle(currentMarkdown, renamed.title)
  return {
    currentMarkdown: nextCurrent,
    persistedMarkdown: renamed.markdown,
    syncedTitle: renamed.title,
    dirty: nextCurrent !== renamed.markdown
  }
}
