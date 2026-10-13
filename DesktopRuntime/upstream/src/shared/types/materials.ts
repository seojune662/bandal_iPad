/**
 * Materials: files that live inside a course folder (PDFs, markdown notes,
 * images, etc.), surfaced as a tree in the right rail.
 */

export type MaterialKind = 'pdf' | 'note' | 'image' | 'video' | 'other'

export interface MaterialNode {
  /** Path relative to the course folder root, POSIX separators. */
  relPath: string
  /** Base name of the file or directory. */
  name: string
  kind: 'dir' | MaterialKind
  /** Byte size for files; undefined for directories. */
  size?: number
  /** Modification time (epoch ms) for files. */
  mtime?: number
  /** First added to this course (epoch ms); absent for pre-existing materials. */
  addedAt?: number
  /** Present (possibly empty) for directories, absent for files. */
  children?: MaterialNode[]
}

export interface MaterialSearchHit {
  relPath: string
  name: string
  kind: MaterialKind
  /** Simple relevance score, higher is better. */
  score: number
  /** First added to this course (epoch ms); absent for pre-existing materials. */
  addedAt?: number
}

/** Result of reading a material file's contents over IPC. */
export type MaterialFileContent =
  | { encoding: 'utf8'; data: string }
  | { encoding: 'base64'; data: string }

export interface ImportResult {
  imported: string[]
  /** Absolute source paths that failed, with reasons. */
  failed: { path: string; reason: string }[]
}
