import { readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import JSZip from 'jszip'
import type { BrowserImportItem } from '../../../../shared/types/browserImport'
import { parseBookmarkHtml, parsePasswordCsv } from '../browserImport'
import { HISTORY_MAX_ROWS, HISTORY_RETENTION_DAYS, isRecordableUrl } from '../historyRepo'
import { createChromiumDecryptor, type SecretHelper } from './crypto'
import type { PrivateImportSource } from './discovery'
import { readSnapshot, tableColumns } from './sqlite'
import { checkCancelled, emptyPayload, ImportReadError, type ImportedCookie, type ImportedHistoryEntry, type ImportPayload } from './types'

const MAX_SOURCE_BYTES = 64 * 1024 * 1024
const MAX_ITEMS = 50_000
const CHROME_EPOCH_MS = 11_644_473_600_000
const DAY_MS = 86_400_000
type Row = Record<string, unknown>
const text = (value: unknown): string => typeof value === 'string' ? value : ''
const number = (value: unknown): number => typeof value === 'number' && Number.isFinite(value) ? value : 0
export function chromiumTime(value: unknown): number { return number(value) / 1000 - CHROME_EPOCH_MS }

async function readBounded(path: string): Promise<Buffer> {
  if ((await stat(path)).size > MAX_SOURCE_BYTES) throw new ImportReadError('format')
  const data = await readFile(path)
  if (data.length > MAX_SOURCE_BYTES) throw new ImportReadError('format')
  return data
}

export function boundHistory(entries: ImportedHistoryEntry[], now: number): ImportedHistoryEntry[] {
  const unique = new Map<string, ImportedHistoryEntry>()
  for (const item of entries) {
    const timestamp = Date.parse(item.lastVisitedAt)
    if (!isRecordableUrl(item.url) || !Number.isFinite(timestamp) || timestamp < now - HISTORY_RETENTION_DAYS * DAY_MS || timestamp > now + DAY_MS) continue
    const next = { ...item, title: item.title.slice(0, 1000), visitCount: Math.max(1, Math.min(2_147_483_647, Math.trunc(item.visitCount))) }
    const previous = unique.get(item.url)
    if (previous) {
      next.visitCount = Math.max(previous.visitCount, next.visitCount)
      if (previous.lastVisitedAt > next.lastVisitedAt) { next.lastVisitedAt = previous.lastVisitedAt; next.title = previous.title }
    }
    unique.set(item.url, next)
  }
  return [...unique.values()].sort((a, b) => b.lastVisitedAt.localeCompare(a.lastVisitedAt)).slice(0, HISTORY_MAX_ROWS)
}

function historyEntry(row: Row, milliseconds: number, count: unknown): ImportedHistoryEntry | null {
  if (!Number.isFinite(milliseconds) || milliseconds <= 0 || milliseconds > 8.64e15 || !isRecordableUrl(text(row.url))) return null
  return { url: text(row.url), title: text(row.title), visitCount: Math.max(1, number(count)), lastVisitedAt: new Date(milliseconds).toISOString() }
}

function cookieBase(row: Row, browser: 'chromium' | 'firefox', value: string, now: number): ImportedCookie | null {
  const host = text(row[browser === 'chromium' ? 'host_key' : 'host'])
  const domain = host.replace(/^\./, '')
  if (!domain || /[\s/:?#@\\]/.test(domain)) return null
  const path = text(row.path) || '/'
  if (!path.startsWith('/')) return null
  const secure = number(row[browser === 'chromium' ? 'is_secure' : 'isSecure']) === 1
  const expires = browser === 'chromium' ? chromiumTime(row.expires_utc) / 1000 : number(row.expiry)
  const session = browser === 'chromium' ? (row.has_expires !== undefined ? number(row.has_expires) === 0 : number(row.expires_utc) === 0) : number(row.isSession) === 1 || expires === 0
  if (!session && expires <= now / 1000) return null
  const sameSite = number(row[browser === 'chromium' ? 'samesite' : 'sameSite'])
  const cookie: ImportedCookie = {
    url: `${secure ? 'https' : 'http'}://${domain}${path}`,
    name: text(row.name), value, path, secure,
    httpOnly: number(row[browser === 'chromium' ? 'is_httponly' : 'isHttpOnly']) === 1,
    sameSite: browser === 'chromium' && sameSite === -1 ? 'unspecified' : sameSite === 2 ? 'strict' : sameSite === 1 ? 'lax' : 'no_restriction'
  }
  // Omission, rather than a bare domain, preserves Chromium host-only semantics.
  if (host.startsWith('.')) cookie.domain = host
  if (!session) cookie.expirationDate = expires
  return cookie
}

export async function readProfile(source: PrivateImportSource, items: BrowserImportItem[], options: { platform: NodeJS.Platform; helper: SecretHelper; signal: AbortSignal; now: number; onItem?: (item: BrowserImportItem) => void }): Promise<ImportPayload> {
  const payload = emptyPayload()
  const { signal, now } = options
  const firefox = source.public.browser === 'firefox'
  for (const item of items) {
    checkCancelled(signal)
    options.onItem?.(item)
    if (!source.public.capabilities[item].supported) { payload.unsupported[item] = 1; continue }
    try {
      if (item === 'bookmarks') {
        if (firefox) {
          payload.bookmarks = readSnapshot(join(source.path, 'places.sqlite'), (db) => (db.prepare(`SELECT p.url, b.title FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id WHERE b.type = 1 ORDER BY b.id LIMIT ?`).all(MAX_ITEMS) as Row[]).filter((row) => /^https?:\/\//i.test(text(row.url))).map((row) => ({ url: text(row.url), title: text(row.title).slice(0, 240) || text(row.url) })))
        } else {
          const data = JSON.parse((await readBounded(join(source.path, 'Bookmarks'))).toString('utf8')) as { roots?: Record<string, unknown> }
          const stack: unknown[] = Object.values(data.roots ?? {}).reverse()
          let visited = 0
          while (stack.length && visited++ < MAX_ITEMS * 4) {
            const value = stack.pop()
            if (!value || typeof value !== 'object') continue
            const node = value as { type?: string; name?: string; url?: string; children?: unknown[] }
            if (node.type === 'url' && /^https?:\/\//i.test(node.url ?? '')) payload.bookmarks.push({ url: node.url!, title: (node.name ?? node.url!).slice(0, 240) })
            if (Array.isArray(node.children)) stack.push(...node.children.slice(0, MAX_ITEMS).reverse())
            if (payload.bookmarks.length >= MAX_ITEMS) break
          }
        }
      } else if (item === 'history') {
        const cutoff = now - HISTORY_RETENTION_DAYS * DAY_MS
        const rows = firefox
          ? readSnapshot(join(source.path, 'places.sqlite'), (db) => db.prepare('SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE last_visit_date >= ? ORDER BY last_visit_date DESC LIMIT ?').all(cutoff * 1000, HISTORY_MAX_ROWS) as Row[])
          : readSnapshot(join(source.path, 'History'), (db) => db.prepare('SELECT url, title, visit_count, last_visit_time FROM urls WHERE last_visit_time >= ? ORDER BY last_visit_time DESC LIMIT ?').all((cutoff + CHROME_EPOCH_MS) * 1000, HISTORY_MAX_ROWS) as Row[])
        payload.history = boundHistory(rows.map((row) => historyEntry(row, firefox ? number(row.last_visit_date) / 1000 : chromiumTime(row.last_visit_time), row.visit_count)).filter((entry): entry is ImportedHistoryEntry => entry !== null), now)
      } else if (item === 'cookies') {
        if (firefox) {
          const rows = readSnapshot(join(source.path, 'cookies.sqlite'), (db) => db.prepare('SELECT * FROM moz_cookies LIMIT ?').all(MAX_ITEMS) as Row[])
          for (const row of rows) {
            if (text(row.originAttributes) !== '' || number(row.isPartitioned) !== 0) { payload.unsupported.cookies = (payload.unsupported.cookies ?? 0) + 1; continue }
            const cookie = cookieBase(row, 'firefox', text(row.value), now)
            if (cookie) payload.cookies.push(cookie)
          }
        } else {
          let path = join(source.path, 'Network/Cookies')
          try { await stat(path) } catch { path = join(source.path, 'Cookies') }
          const snapshot = readSnapshot(path, (db) => {
            const columns = tableColumns(db, 'cookies')
            if (!columns.has('host_key') || !columns.has('encrypted_value')) throw new ImportReadError('format')
            const version = db.prepare("SELECT value FROM meta WHERE key = 'version'").get() as { value: string } | undefined
            return { version: Number(version?.value ?? 0), rows: db.prepare('SELECT * FROM cookies LIMIT ?').all(MAX_ITEMS) as Row[] }
          })
          const decryptor = createChromiumDecryptor({ platform: options.platform, browser: source.public.browser === 'edge' ? 'edge' : 'chrome', root: source.root ?? source.path, helper: options.helper, signal, cookieVersion: snapshot.version })
          try {
            for (let index = 0; index < snapshot.rows.length; index += 1) {
              checkCancelled(signal)
              if (index % 100 === 0) await new Promise<void>((resolve) => setImmediate(resolve))
              const row = snapshot.rows[index]!
              if (text(row.top_frame_site_key) !== '' || number(row.has_cross_site_ancestor) !== 0) { payload.unsupported.cookies = (payload.unsupported.cookies ?? 0) + 1; continue }
              let value = text(row.value)
              const encrypted = row.encrypted_value
              if (Buffer.isBuffer(encrypted) && encrypted.length > 0) {
                const decrypted = await decryptor.decrypt(encrypted, text(row.host_key))
                if (!decrypted) { payload.unsupported.cookies = (payload.unsupported.cookies ?? 0) + 1; continue }
                value = decrypted.toString('utf8')
                decrypted.fill(0)
              }
              const cookie = cookieBase(row, 'chromium', value, now)
              if (cookie) payload.cookies.push(cookie)
            }
          } finally { decryptor.dispose() }
        }
      } else if (item === 'passwords') {
        const rows = readSnapshot(join(source.path, 'Login Data'), (db) => db.prepare('SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0 LIMIT ?').all(MAX_ITEMS) as Row[])
        const decryptor = createChromiumDecryptor({ platform: options.platform, browser: source.public.browser === 'edge' ? 'edge' : 'chrome', root: source.root ?? source.path, helper: options.helper, signal })
        try {
          for (let index = 0; index < rows.length; index += 1) {
            checkCancelled(signal)
            if (index % 100 === 0) await new Promise<void>((resolve) => setImmediate(resolve))
            const row = rows[index]!
            if (!Buffer.isBuffer(row.password_value)) { payload.failed.passwords = (payload.failed.passwords ?? 0) + 1; continue }
            const decrypted = await decryptor.decrypt(row.password_value)
            if (!decrypted) { payload.unsupported.passwords = (payload.unsupported.passwords ?? 0) + 1; continue }
            const password = decrypted.toString('utf8')
            decrypted.fill(0)
            if (!password || !text(row.origin_url).startsWith('https://')) { payload.unsupported.passwords = (payload.unsupported.passwords ?? 0) + 1; continue }
            payload.passwords.push({ origin: text(row.origin_url), username: text(row.username_value), password, autoSubmit: false })
          }
        } finally { decryptor.dispose() }
      }
    } catch (error) {
      if (signal.aborted) throw new ImportReadError('cancelled')
      payload.failed[item] = (payload.failed[item] ?? 0) + 1
      const reason = error instanceof ImportReadError ? error.reason : 'format'
      payload.messages.push(reason === 'locked' ? '원본 브라우저가 저장소를 사용 중입니다. 종료한 뒤 다시 시도해 주세요.' : reason === 'permission' ? 'OS 접근이 허용되지 않았습니다. 권한을 확인하거나 내보내기 파일을 선택해 주세요.' : reason === 'helper' ? '암호화된 항목을 읽지 못했습니다. 비밀번호 CSV를 사용하거나 다시 로그인해 주세요.' : '일부 원본 데이터를 읽을 수 없습니다. 원본 브라우저를 종료하거나 내보내기 파일을 선택해 주세요.')
    }
  }
  return payload
}

async function zipEntryText(entry: JSZip.JSZipObject, signal: AbortSignal): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    let settled = false
    // JSZip uses readable-stream v2, which does not implement async iteration.
    const stream = entry.nodeStream('nodebuffer')
    const fail = (reason: 'cancelled' | 'format'): void => {
      if (settled) return
      settled = true
      stream.pause()
      signal.removeEventListener('abort', cancel)
      for (const chunk of chunks) chunk.fill(0)
      chunks.length = 0
      reject(new ImportReadError(reason))
    }
    const cancel = (): void => fail('cancelled')
    signal.addEventListener('abort', cancel, { once: true })
    stream.on('data', (buffer: Buffer) => {
      if (settled) return
      size += buffer.length
      if (size > MAX_SOURCE_BYTES) { fail('format'); return }
      chunks.push(buffer)
    })
    stream.on('error', () => fail('format'))
    stream.on('end', () => {
      if (settled) return
      settled = true
      signal.removeEventListener('abort', cancel)
      const output = Buffer.concat(chunks)
      resolve(output.toString('utf8'))
      output.fill(0)
      for (const chunk of chunks) chunk.fill(0)
    })
    if (signal.aborted) cancel()
  })
}

export async function readImportFile(source: PrivateImportSource, items: BrowserImportItem[], signal: AbortSignal, now: number): Promise<ImportPayload> {
  const payload = emptyPayload()
  checkCancelled(signal)
  const data = await readBounded(source.path)
  if (source.public.kind === 'bookmarks-html') {
    if (items.includes('bookmarks')) payload.bookmarks = parseBookmarkHtml(data.toString('utf8'))
  } else if (source.public.kind === 'passwords-csv') {
    if (items.includes('passwords')) { const parsed = parsePasswordCsv(data.toString('utf8')); payload.passwords = parsed.logins; payload.failed.passwords = parsed.skipped }
  } else if (source.public.kind === 'safari-zip') {
    // File names are localized. Identify format by extension and JSON metadata,
    // never by the English names or by extracting archive paths to disk.
    const zip = await JSZip.loadAsync(data)
    const entries = Object.values(zip.files).filter((entry) => !entry.dir && !entry.name.startsWith('__MACOSX/'))
    if (entries.length > 100) throw new ImportReadError('format')
    let expanded = 0
    let recognized = false
    for (const entry of entries) {
      checkCancelled(signal)
      const extension = entry.name.split('.').at(-1)?.toLowerCase()
      if (!['html', 'htm', 'csv', 'json'].includes(extension ?? '')) continue
      if (extension === 'csv' && !items.includes('passwords') || (extension === 'html' || extension === 'htm') && !items.includes('bookmarks') || extension === 'json' && !items.includes('history')) continue
      const contents = await zipEntryText(entry, signal)
      expanded += Buffer.byteLength(contents)
      if (expanded > MAX_SOURCE_BYTES) throw new ImportReadError('format')
      if (extension === 'html' || extension === 'htm') { payload.bookmarks.push(...parseBookmarkHtml(contents)); recognized = true }
      else if (extension === 'csv') {
        const parsed = parsePasswordCsv(contents)
        payload.passwords.push(...parsed.logins)
        payload.failed.passwords = (payload.failed.passwords ?? 0) + parsed.skipped
        recognized = true
      } else {
        const document = JSON.parse(contents) as { metadata?: { data_type?: string; schema_version?: number }; history?: Row[] }
        if (document.metadata?.data_type !== 'history') continue
        if (document.metadata.schema_version !== 1 || !Array.isArray(document.history)) throw new ImportReadError('format')
        for (const row of document.history) {
          const entry = historyEntry(row, number(row.time_usec) / 1000, row.visits_count)
          if (entry) payload.history.push(entry)
        }
        recognized = true
      }
    }
    if (!recognized && items.some((item) => source.public.capabilities[item].supported)) throw new ImportReadError('format')
    payload.history = boundHistory(payload.history, now)
    payload.bookmarks = payload.bookmarks.slice(0, MAX_ITEMS)
    payload.passwords = payload.passwords.slice(0, MAX_ITEMS)
  }
  for (const item of items) if (!source.public.capabilities[item].supported) payload.unsupported[item] = 1
  return payload
}
