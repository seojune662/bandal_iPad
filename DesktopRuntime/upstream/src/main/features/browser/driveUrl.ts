type GoogleFileKind = 'drive' | 'document' | 'spreadsheets' | 'presentation'

interface GoogleFile {
  id: string
  kind: GoogleFileKind
}

function parseGoogleFile(rawUrl: string): GoogleFile | null {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }

  if (url.hostname === 'drive.google.com') {
    const fileId = /^\/file\/d\/([A-Za-z0-9_-]+)(?:\/|$)/u.exec(
      url.pathname
    )?.[1]
    const queryId = url.pathname === '/open' || url.pathname === '/uc'
      ? url.searchParams.get('id')
      : null
    const id = fileId ?? queryId
    return id === null || id === '' ? null : { id, kind: 'drive' }
  }

  if (url.hostname !== 'docs.google.com') return null
  const match = /^\/(document|spreadsheets|presentation)\/d\/([A-Za-z0-9_-]+)(?:\/|$)/u.exec(
    url.pathname
  )
  if (match?.[1] === undefined || match[2] === undefined) return null
  return { id: match[2], kind: match[1] as GoogleFileKind }
}

export function googleDriveFileId(url: string): string | null {
  return parseGoogleFile(url)?.id ?? null
}

export function rewriteDriveUrl(url: string): string {
  const file = parseGoogleFile(url)
  if (file === null) return url
  const id = encodeURIComponent(file.id)
  if (file.kind === 'drive') {
    return `https://drive.google.com/uc?export=download&id=${id}`
  }
  if (file.kind === 'presentation') {
    return `https://docs.google.com/presentation/d/${id}/export/pptx`
  }
  const format = file.kind === 'document' ? 'docx' : 'xlsx'
  return `https://docs.google.com/${file.kind}/d/${id}/export?format=${format}`
}

function decodeAttribute(value: string): string {
  return value
    .replace(/&amp;/giu, '&')
    .replace(/&quot;/giu, '"')
    .replace(/&#(?:39|x27);/giu, "'")
}

function attributes(source: string): Map<string, string> {
  const result = new Map<string, string>()
  const pattern = /([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gu
  for (const match of source.matchAll(pattern)) {
    const name = match[1]
    const value = match[2] ?? match[3] ?? match[4]
    if (name !== undefined && value !== undefined) {
      result.set(name.toLowerCase(), decodeAttribute(value))
    }
  }
  return result
}

const CONFIRM_ACTION = 'https://drive.usercontent.google.com/download'
const CONFIRM_FIELDS = new Set(['id', 'export', 'confirm', 'uuid'])

export function driveConfirmUrl(html: string): string | null {
  const forms = html.matchAll(/<form\b([^>]*)>([\s\S]*?)<\/form>/giu)
  for (const form of forms) {
    const formAttributes = attributes(form[1] ?? '')
    if (formAttributes.get('action') !== CONFIRM_ACTION) continue
    const query = new URLSearchParams()
    for (const input of (form[2] ?? '').matchAll(/<input\b([^>]*)>/giu)) {
      const inputAttributes = attributes(input[1] ?? '')
      const name = inputAttributes.get('name')
      if (
        inputAttributes.get('type')?.toLowerCase() === 'hidden' &&
        name !== undefined &&
        CONFIRM_FIELDS.has(name)
      ) {
        query.set(name, inputAttributes.get('value') ?? '')
      }
    }
    if (!query.has('id')) return null
    return `${CONFIRM_ACTION}?${query.toString()}`
  }
  return null
}
