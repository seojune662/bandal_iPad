/**
 * Typed error classes for the main-process data layer.
 *
 * Every repo throws one of these (or a plain Error for unexpected failures);
 * the IPC layer logs and rethrows so the renderer receives a rejected
 * promise whose message starts with a stable `[code]` prefix.
 */

export class ValidationError extends Error {
  constructor(message: string) {
    super(`[validation] ${message}`)
    this.name = 'ValidationError'
  }
}

export class NotFoundError extends Error {
  constructor(entity: string, id: string) {
    super(`[not-found] ${entity} "${id}" does not exist`)
    this.name = 'NotFoundError'
  }
}

export class PathTraversalError extends Error {
  constructor(relPath: string) {
    super(`[path-traversal] "${relPath}" escapes the course folder`)
    this.name = 'PathTraversalError'
  }
}

export class ConflictError extends Error {
  constructor(message: string) {
    super(`[conflict] ${message}`)
    this.name = 'ConflictError'
  }
}
