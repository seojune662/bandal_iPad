/**
 * Browser history, kept only to make the omnibox useful.
 *
 * Deliberately narrow: no page content, no full visit log, no analytics. A
 * row is a URL the student reached, how often, and when — which is exactly
 * what ranking a suggestion needs and nothing more. School portal URLs carry
 * student numbers and session keys, so the less of them we keep the better.
 *
 * Pruned on boot rather than on write: a rolling window keeps the table small
 * without adding a delete to the hot path.
 */

import { addressSearchTerms } from '../../../shared/browserSearch'
import type { Database } from 'better-sqlite3'
import { requireNonEmptyString } from '../../db/validate'

/** How long a visit stays useful for ranking. */
export const HISTORY_RETENTION_DAYS = 90
/** Hard ceiling, so a scripted page cannot grow the table without bound. */
export const HISTORY_MAX_ROWS = 20_000

export interface HistoryEntry {
  url: string
  title: string
  host: string
  courseId: string | null
  visitCount: number
  lastVisitedAt: string
}

export interface RecordVisitInput {
  url: string
  title: string
  courseId: string | null
}

export interface HistoryRepo {
  /** Import preserves timestamps/counts; retrying never manufactures visits. */
  importMany(entries: readonly { url: string; title: string; visitCount: number; lastVisitedAt: string }[], conflict?: 'keep' | 'replace', at?: Date): { imported: number; kept: number; unsupported: number; failed: number }
  /** Upserts: a revisit bumps the count and the timestamp, never appends. */
  recordVisit(input: RecordVisitInput, at?: Date): void
  /** Empty input returns recent visits; otherwise host prefix, count, recency. */
  search(query: string, limit?: number): HistoryEntry[]
  /** `null` clears everything; a course id clears just that course's rows. */
  clear(courseId: string | null): void
  /** Drops rows outside the retention window and above the row ceiling. */
  prune(at?: Date): void
}

interface HistoryRow {
  url: string
  title: string
  host: string
  course_id: string | null
  visit_count: number
  last_visited_at: string
}

function toEntry(row: HistoryRow): HistoryEntry {
  return {
    url: row.url,
    title: row.title,
    host: row.host,
    courseId: row.course_id,
    visitCount: row.visit_count,
    lastVisitedAt: row.last_visited_at
  }
}

/** Bare hostname, `www.` dropped so a prefix match behaves as a student expects. */
export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./i, '')
  } catch {
    return ''
  }
}

/**
 * Whether a URL is worth remembering. Search-result pages are excluded: the
 * omnibox creates them itself, so keeping them makes every query suggest the
 * student's own past queries instead of the pages they actually opened.
 */
export function isRecordableUrl(url: string): boolean {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return false
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false
  const host = parsed.hostname.replace(/^www\./i, '')
  const isSearchResults =
    (host === 'google.com' && parsed.pathname.startsWith('/search')) ||
    (host === 'search.naver.com') ||
    (host === 'search.daum.net') ||
    (host === 'duckduckgo.com' && parsed.searchParams.has('q'))
  return !isSearchResults
}

export function createHistoryRepo(db: Database): HistoryRepo {
  return {
    importMany(entries, conflict = 'keep', at = new Date()) {
      const result = { imported: 0, kept: 0, unsupported: 0, failed: 0 }
      const cutoff = at.getTime() - HISTORY_RETENTION_DAYS * 86_400_000
      const find = db.prepare('SELECT * FROM browser_history WHERE url = ?')
      const upsert = db.prepare(`INSERT INTO browser_history (url,title,host,course_id,visit_count,last_visited_at)
        VALUES (?,?,?,NULL,?,?) ON CONFLICT(url) DO UPDATE SET title=excluded.title,
        visit_count=MAX(browser_history.visit_count,excluded.visit_count),
        last_visited_at=MAX(browser_history.last_visited_at,excluded.last_visited_at)`)
      db.transaction(() => {
        const cutoffDate = new Date(cutoff).toISOString()
        // Expired destination rows must not turn a valid incoming visit into a
        // keep-conflict that is immediately pruned away.
        db.prepare('DELETE FROM browser_history WHERE last_visited_at < ?').run(cutoffDate)
        const candidates = new Map<string, {
          title: string; visits: number; date: string; count: number; changed: boolean
        }>()
        for (const entry of entries) {
          const timestamp = Date.parse(entry.lastVisitedAt)
          if (!Number.isFinite(timestamp) || !Number.isFinite(entry.visitCount) || entry.visitCount < 0) { result.failed++; continue }
          if (!isRecordableUrl(entry.url) || timestamp < cutoff || timestamp > at.getTime() + 86_400_000) { result.unsupported++; continue }
          const date = new Date(timestamp).toISOString()
          const visits = Math.max(1, Math.floor(entry.visitCount))
          const previous = candidates.get(entry.url)
          if (previous) {
            previous.count++
            previous.visits = Math.max(previous.visits, visits)
            if (date > previous.date) {
              previous.date = date
              previous.title = entry.title.slice(0, 1000)
            }
          } else {
            candidates.set(entry.url, { title: entry.title.slice(0, 1000), visits, date, count: 1, changed: false })
          }
        }
        for (const [url, entry] of candidates) {
          const current = find.get(url) as HistoryRow | undefined
          if (current && (conflict === 'keep' || (current.title === entry.title && current.visit_count >= entry.visits && current.last_visited_at >= entry.date))) continue
          upsert.run(url, entry.title, hostOf(url), entry.visits, entry.date)
          entry.changed = true
        }
        // The ceiling includes both existing and incoming URLs. Count success
        // only after retention, so pruned imports never appear as saved rows.
        db.prepare('DELETE FROM browser_history WHERE url IN (SELECT url FROM browser_history ORDER BY last_visited_at DESC, url ASC LIMIT -1 OFFSET ?)').run(HISTORY_MAX_ROWS)
        const retained = new Set((db.prepare('SELECT url FROM browser_history').all() as { url: string }[]).map(row => row.url))
        for (const [url, entry] of candidates) {
          if (!retained.has(url)) result.unsupported += entry.count
          else if (entry.changed) { result.imported++; result.kept += entry.count - 1 }
          else result.kept += entry.count
        }
      })()
      return result
    },
    recordVisit(input, at = new Date()) {
      const url = requireNonEmptyString(input.url, 'url')
      if (!isRecordableUrl(url)) return
      const host = hostOf(url)
      const title = typeof input.title === 'string' ? input.title : ''
      db.prepare(
        `INSERT INTO browser_history
           (url, title, host, course_id, visit_count, last_visited_at)
         VALUES (?, ?, ?, ?, 1, ?)
         ON CONFLICT(url) DO UPDATE SET
           -- Keep the last non-empty title: a page that briefly reports "" mid
           -- load would otherwise wipe a good one.
           title = CASE WHEN excluded.title = '' THEN browser_history.title
                        ELSE excluded.title END,
           course_id = excluded.course_id,
           visit_count = browser_history.visit_count + 1,
           last_visited_at = excluded.last_visited_at`
      ).run(url, title, host, input.courseId, at.toISOString())
    },

    search(query, limit = 8) {
      const terms = addressSearchTerms(query)
      const boundedLimit = Number.isFinite(limit) ? Math.max(1, Math.min(50, Math.trunc(limit))) : 8
      const escapeLike = (value: string): string => value.replace(/[\\%_]/gu, '\\$&')
      // Treat '%' and '_' literally; all typed words must match, in any order.
      // Also match encoded Korean paths without decoding every row on main.
      const where = terms.map(() => `(lower(url) LIKE ? ESCAPE '\\'
        OR lower(url) LIKE ? ESCAPE '\\' OR lower(title) LIKE ? ESCAPE '\\')`).join(' AND ')
      const args = terms.flatMap((term) => [
        `%${escapeLike(term)}%`,
        `%${escapeLike(encodeURI(term).toLowerCase())}%`,
        `%${escapeLike(term)}%`
      ])
      const prefix = terms.join(' ').replace(/^https?:\/\/(?:www\.)?/u, '')
      const order = terms.length === 0
        ? 'last_visited_at DESC, visit_count DESC'
        : `CASE WHEN lower(host) LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END,
           visit_count DESC, last_visited_at DESC`
      if (terms.length > 0) args.push(`${escapeLike(prefix)}%`)
      const rows = db.prepare(`SELECT * FROM browser_history
        ${where === '' ? '' : `WHERE ${where}`} ORDER BY ${order} LIMIT ?`)
        .all(...args, boundedLimit) as HistoryRow[]
      return rows.map(toEntry)
    },

    clear(courseId) {
      if (courseId === null) {
        db.prepare('DELETE FROM browser_history').run()
        return
      }
      db.prepare('DELETE FROM browser_history WHERE course_id = ?').run(courseId)
    },

    prune(at = new Date()) {
      const cutoff = new Date(
        at.getTime() - HISTORY_RETENTION_DAYS * 24 * 60 * 60 * 1000
      ).toISOString()
      db.prepare('DELETE FROM browser_history WHERE last_visited_at < ?').run(
        cutoff
      )
      db.prepare(
        `DELETE FROM browser_history WHERE url IN (
           SELECT url FROM browser_history
             ORDER BY last_visited_at DESC, url ASC
             LIMIT -1 OFFSET ?
         )`
      ).run(HISTORY_MAX_ROWS)
    }
  }
}
