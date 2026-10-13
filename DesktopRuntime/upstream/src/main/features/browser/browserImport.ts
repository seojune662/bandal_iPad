import type { SaveLoginInput } from '../../../shared/types/credentials'

const MAX_IMPORT_ROWS = 10_000

function csvRows(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let quoted = false
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index] ?? ''
    if (quoted) {
      if (char === '"' && text[index + 1] === '"') {
        field += '"'
        index += 1
      } else if (char === '"') {
        quoted = false
      } else {
        field += char
      }
      continue
    }
    if (char === '"') quoted = true
    else if (char === ',') {
      row.push(field)
      field = ''
    } else if (char === '\n') {
      row.push(field.replace(/\r$/, ''))
      rows.push(row)
      row = []
      field = ''
      if (rows.length > MAX_IMPORT_ROWS + 1) break
    } else field += char
  }
  if (field !== '' || row.length > 0) {
    row.push(field.replace(/\r$/, ''))
    rows.push(row)
  }
  return rows
}

/** Chrome/Edge/Arc and Firefox password CSVs share these three columns. */
export function parsePasswordCsv(text: string): {
  logins: SaveLoginInput[]
  skipped: number
} {
  const rows = csvRows(text.replace(/^\uFEFF/, ''))
  const header = (rows.shift() ?? []).map((cell) => cell.trim().toLowerCase())
  const urlIndex = header.findIndex((name) => ['url', 'origin', 'hostname'].includes(name))
  const usernameIndex = header.indexOf('username')
  const passwordIndex = header.indexOf('password')
  if (urlIndex < 0 || usernameIndex < 0 || passwordIndex < 0) {
    throw new TypeError('비밀번호 CSV에 url, username, password 열이 필요합니다.')
  }
  const logins: SaveLoginInput[] = []
  let skipped = 0
  for (const row of rows.slice(0, MAX_IMPORT_ROWS)) {
    const origin = row[urlIndex]?.trim() ?? ''
    const username = row[usernameIndex] ?? ''
    const password = row[passwordIndex] ?? ''
    if (origin === '' || password === '') {
      skipped += 1
      continue
    }
    logins.push({ origin, username, password, autoSubmit: false })
  }
  skipped += Math.max(0, rows.length - MAX_IMPORT_ROWS)
  return { logins, skipped }
}

function decodeHtml(value: string): string {
  const named: Record<string, string> = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' '
  }
  return value.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, entity: string) => {
    const lower = entity.toLowerCase()
    if (lower.startsWith('#x')) {
      return String.fromCodePoint(Number.parseInt(lower.slice(2), 16))
    }
    if (lower.startsWith('#')) {
      return String.fromCodePoint(Number.parseInt(lower.slice(1), 10))
    }
    return named[lower] ?? whole
  })
}

export interface ImportedBookmark {
  title: string
  url: string
}

/** Parses the Netscape bookmark HTML exported by Chrome, Edge, Arc, and Firefox. */
export function parseBookmarkHtml(text: string): ImportedBookmark[] {
  const bookmarks: ImportedBookmark[] = []
  const anchor = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi
  for (const match of text.matchAll(anchor)) {
    const attrs = match[1] ?? ''
    const href = /\bhref\s*=\s*(["'])(.*?)\1/i.exec(attrs)?.[2]
    if (href === undefined) continue
    let url: URL
    try {
      url = new URL(decodeHtml(href))
    } catch {
      continue
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') continue
    const rawTitle = (match[2] ?? '').replace(/<[^>]*>/g, '').trim()
    const title = decodeHtml(rawTitle).trim() || url.hostname
    bookmarks.push({ title: title.slice(0, 240), url: url.href })
    if (bookmarks.length >= MAX_IMPORT_ROWS) break
  }
  return bookmarks
}
