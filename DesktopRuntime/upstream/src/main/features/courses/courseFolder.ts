/**
 * Folder-path helpers shared by the courses repo and the IPC layer.
 *
 * A course folder is an ARBITRARY absolute path — either one Bandal created
 * under the data root ('managed') or one the user pointed at ('linked'). Every
 * path that enters the system goes through `normalizeFolderPath` so that
 * duplicate detection, the traversal guard and the watcher all agree on one
 * canonical spelling (symlinks resolved, case as stored on disk).
 */

import { accessSync, constants, realpathSync, statSync } from 'node:fs'
import { basename, isAbsolute, resolve } from 'node:path'
import type { CourseFolderProblem } from '../../../shared/types/course'
import { ValidationError } from '../../db/errors'
import { requireNonEmptyString } from '../../db/validate'

export type FolderState = 'ok' | CourseFolderProblem

/**
 * Validates and canonicalizes an absolute folder path.
 *
 * Symlinks are resolved so `/tmp/link` and `/private/tmp/real` cannot be
 * registered as two different courses; when the path does not exist yet (or
 * cannot be resolved) the lexically resolved form is returned so the caller
 * can still report a precise `missing` / `unreadable` reason.
 */
export function normalizeFolderPath(value: unknown): string {
  const raw = requireNonEmptyString(value, 'folderPath')
  if (!isAbsolute(raw)) {
    throw new ValidationError(`folderPath must be an absolute path (got "${raw}")`)
  }
  if (raw.includes('\u0000')) {
    throw new ValidationError('folderPath contains a null byte')
  }
  const resolved = resolve(raw)
  try {
    return realpathSync.native(resolved)
  } catch {
    return resolved
  }
}

/** Classifies a folder path: usable, gone, not a folder, or not readable. */
export function folderState(absPath: string): FolderState {
  let stat: ReturnType<typeof statSync>
  try {
    stat = statSync(absPath)
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    return code === 'EACCES' || code === 'EPERM' ? 'unreadable' : 'missing'
  }
  if (!stat.isDirectory()) {
    return 'not-a-directory'
  }
  try {
    // Read + traverse: listing the tree needs both.
    accessSync(absPath, constants.R_OK | constants.X_OK)
  } catch {
    return 'unreadable'
  }
  return 'ok'
}

/** True when the folder can be read right now. */
export function isFolderUsable(absPath: string): boolean {
  return folderState(absPath) === 'ok'
}

/** Default course name for a folder: its basename (falls back to the path). */
export function folderDisplayName(absPath: string): string {
  const name = basename(absPath).trim()
  return name.length > 0 ? name : absPath
}
