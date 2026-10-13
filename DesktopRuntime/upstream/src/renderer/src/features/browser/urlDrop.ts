export interface UrlDropResult {
  url: string
  fileName?: string
}

function firstUri(value: string): string {
  return (
    value
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find((line) => line !== '' && !line.startsWith('#')) ?? ''
  )
}

function httpUrl(value: string): string | null {
  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:'
      ? url.toString()
      : null
  } catch {
    return null
  }
}

function downloadUrl(value: string): UrlDropResult | null {
  const mimeEnd = value.indexOf(':')
  const nameEnd = value.indexOf(':', mimeEnd + 1)
  if (mimeEnd <= 0 || nameEnd <= mimeEnd + 1) return null
  const fileName = value.slice(mimeEnd + 1, nameEnd).trim()
  const url = httpUrl(value.slice(nameEnd + 1).trim())
  if (url === null) return null
  return fileName === '' ? { url } : { url, fileName }
}

function firstHtmlUrl(value: string): string | null {
  const match = /\bhref\s*=\s*(["'])(https?:\/\/.*?)\1/iu.exec(value)
  if (match?.[2] === undefined) return null
  return httpUrl(match[2].replaceAll('&amp;', '&'))
}

export function urlFromDataTransfer(
  types: readonly string[],
  getData: (type: string) => string,
): UrlDropResult | null {
  const typeSet = new Set(types)
  if (typeSet.has('text/uri-list')) {
    const url = httpUrl(firstUri(getData('text/uri-list')))
    if (url !== null) return { url }
  }
  if (typeSet.has('DownloadURL')) {
    const result = downloadUrl(getData('DownloadURL'))
    if (result !== null) return result
  }
  if (typeSet.has('text/html')) {
    const url = firstHtmlUrl(getData('text/html'))
    if (url !== null) return { url }
  }
  if (!typeSet.has('text/plain')) return null
  const url = httpUrl(getData('text/plain').trim())
  return url === null ? null : { url }
}
