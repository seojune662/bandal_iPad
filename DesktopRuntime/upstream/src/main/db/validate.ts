/**
 * Boundary validation helpers shared by all repos.
 *
 * Fail fast with typed errors (see ./errors) so bad renderer input never
 * reaches SQL or the filesystem.
 */

import { existsSync, realpathSync } from 'node:fs'
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path'
import { PathTraversalError, ValidationError } from './errors'

/** Asserts `value` is a non-empty string (after trim) and returns it. */
export function requireNonEmptyString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new ValidationError(`${field} must be a non-empty string`)
  }
  return value
}

/** Asserts `value` looks like an id (non-empty string, no control chars). */
export function requireId(value: unknown, field: string): string {
  const id = requireNonEmptyString(value, field)
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f]/.test(id)) {
    throw new ValidationError(`${field} contains control characters`)
  }
  return id.trim()
}

/** Asserts `value` is a finite integer >= min. */
export function requireInt(value: unknown, field: string, min: number): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < min) {
    throw new ValidationError(`${field} must be an integer >= ${min}`)
  }
  return value
}

/**
 * Resolves `relPath` inside `rootDir` and asserts the result does not
 * escape the root (path-traversal guard). Returns the absolute path.
 *
 * Rejects absolute relPaths, `..` segments that climb out of the root and
 * null bytes. `relPath === ''` resolves to the root itself when
 * `allowRoot` is true.
 */
export function resolveInside(
  rootDir: string,
  relPath: string,
  options: { allowRoot?: boolean } = {}
): string {
  if (typeof relPath !== 'string') {
    throw new ValidationError('relPath must be a string')
  }
  if (relPath.includes('\u0000')) {
    throw new PathTraversalError(relPath)
  }
  if (relPath === '') {
    if (options.allowRoot === true) {
      return resolve(rootDir)
    }
    throw new ValidationError('relPath must be a non-empty string')
  }
  if (isAbsolute(relPath)) {
    throw new PathTraversalError(relPath)
  }
  const root = resolve(rootDir)
  const target = resolve(root, relPath)
  const rel = relative(root, target)
  if (rel === '' && options.allowRoot !== true) {
    throw new PathTraversalError(relPath)
  }
  if (rel.startsWith(`..${sep}`) || rel === '..' || isAbsolute(rel)) {
    throw new PathTraversalError(relPath)
  }
  return target
}

/**
 * Asserts that the existing filesystem portion of `absPath` resolves inside
 * `rootDir`. Call this after the lexical `resolveInside` guard.
 *
 * The target itself may not exist yet (for example, before a write). In that
 * case the nearest existing ancestor is canonicalized instead. The root is
 * canonicalized independently so a course folder that is itself a symlink is
 * valid, while a symlink below it cannot redirect access outside the course.
 */
export function assertRealInside(rootDir: string, absPath: string): string {
  if (!isAbsolute(absPath)) {
    throw new ValidationError('absPath must be absolute')
  }

  let canonicalRoot: string
  try {
    canonicalRoot = realpathSync.native(rootDir)
  } catch {
    throw new ValidationError('course root must exist and be resolvable')
  }

  let existingAncestor = absPath
  while (!existsSync(existingAncestor)) {
    const parent = dirname(existingAncestor)
    if (parent === existingAncestor) {
      throw new ValidationError('path must have a resolvable ancestor')
    }
    existingAncestor = parent
  }

  let canonicalAncestor: string
  try {
    canonicalAncestor = realpathSync.native(existingAncestor)
  } catch {
    throw new ValidationError('path must have a resolvable ancestor')
  }

  const rel = relative(canonicalRoot, canonicalAncestor)
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new ValidationError('path resolves outside the course folder')
  }
  return absPath
}

/** Lexically resolves a relative path, then enforces the realpath boundary. */
export function resolveInsideReal(rootDir: string, relPath: string): string {
  return assertRealInside(rootDir, resolveInside(rootDir, relPath))
}

/** Current timestamp in the ISO-8601 format used by every table. */
export function nowIso(): string {
  return new Date().toISOString()
}
