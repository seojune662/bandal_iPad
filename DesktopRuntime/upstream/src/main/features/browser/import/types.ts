import type { SaveLoginInput } from '../../../../shared/types/credentials'
import type { BrowserImportItem } from '../../../../shared/types/browserImport'
import type { ImportedBookmark } from '../browserImport'

export type ImportDisposition = 'imported' | 'kept' | 'unsupported' | 'failed'
export interface ImportedHistoryEntry {
  url: string
  title: string
  visitCount: number
  lastVisitedAt: string
}

/** Electron CookieDetails subset; omitting expirationDate preserves a session cookie. */
export interface ImportedCookie {
  url: string
  name: string
  value: string
  domain?: string
  path: string
  secure: boolean
  httpOnly: boolean
  sameSite: 'unspecified' | 'no_restriction' | 'lax' | 'strict'
  expirationDate?: number
}

export interface ImportPayload {
  bookmarks: ImportedBookmark[]
  history: ImportedHistoryEntry[]
  cookies: ImportedCookie[]
  passwords: SaveLoginInput[]
  unsupported: Partial<Record<BrowserImportItem, number>>
  failed: Partial<Record<BrowserImportItem, number>>
  messages: string[]
}

export function emptyPayload(): ImportPayload {
  return { bookmarks: [], history: [], cookies: [], passwords: [], unsupported: {}, failed: {}, messages: [] }
}

export class ImportReadError extends Error {
  constructor(readonly reason: 'locked' | 'permission' | 'format' | 'helper' | 'cancelled') {
    super(reason)
  }
}

export function checkCancelled(signal: AbortSignal): void {
  if (signal.aborted) throw new ImportReadError('cancelled')
}
