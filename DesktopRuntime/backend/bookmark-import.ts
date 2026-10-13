import { randomUUID } from './shims/crypto'
import { Buffer } from './shims/buffer'
import { parseBookmarkHtml } from '../upstream/src/main/features/browser/browserImport'
import type { FavoritesRepo } from '../upstream/src/main/features/favorites/favoritesRepo'

/** Same profile-scoped favorite descriptors as the desktop import sink. */
export function importBookmarkHTML(db: { transaction<T>(operation: () => T): () => T }, favorites: FavoritesRepo, request: { profileId?: unknown; html?: unknown }) {
  const { profileId, html } = request
  if (typeof profileId !== 'string' || (profileId !== 'default' && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(profileId))) throw new Error('브라우저 프로필을 확인해 주세요.')
  if (typeof html !== 'string' || Buffer.byteLength(html, 'utf8') > 8 * 1024 * 1024) throw new Error('8MB 이하의 HTML 북마크 파일을 선택해 주세요.')
  // The desktop parser caps rows silently. Reject an oversized export before
  // writing so an import can never claim a truncated file was fully handled.
  if ([...html.matchAll(/<a\b/gi)].length > 10_000) throw new Error('북마크는 한 번에 10,000개까지 가져올 수 있습니다.')
  const parsed = parseBookmarkHtml(html)
  const entries = parsed.filter(entry => { const url = new URL(entry.url); return !url.username && !url.password })
  if (!entries.length) throw new Error('가져올 HTTP 또는 HTTPS 북마크가 없습니다.')
  return db.transaction(() => {
    const existing = new Set(favorites.list(null).flatMap(favorite => favorite.descriptor.kind === 'browser' && (favorite.descriptor.payload.profileId ?? 'default') === profileId ? [favorite.descriptor.payload.initialUrl] : []))
    let imported = 0, skipped = 0
    for (const entry of entries) {
      if (existing.has(entry.url)) { skipped++; continue }
      favorites.add({ courseId: null, label: entry.title, descriptor: { kind: 'browser', payload: { tabId: randomUUID(), initialUrl: entry.url, profileId } } })
      existing.add(entry.url); imported++
    }
    return { imported, skipped, ignored: parsed.length - entries.length, cancelled: false }
  })()
}
