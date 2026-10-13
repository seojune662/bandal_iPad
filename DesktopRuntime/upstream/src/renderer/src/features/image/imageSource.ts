import type { MaterialFileContent } from '../../../../shared/types/materials'

const IMAGE_MIME_BY_EXTENSION: Readonly<Record<string, string>> = {
  avif: 'image/avif',
  bmp: 'image/bmp',
  gif: 'image/gif',
  heic: 'image/heic',
  jpeg: 'image/jpeg',
  jpg: 'image/jpeg',
  png: 'image/png',
  svg: 'image/svg+xml',
  webp: 'image/webp'
}

export function imageMimeType(relPath: string): string | null {
  const fileName = relPath.split('/').at(-1) ?? relPath
  const extension = fileName.split('.').at(-1)?.toLowerCase()
  if (extension === undefined) return null
  return IMAGE_MIME_BY_EXTENSION[extension] ?? null
}

/** Builds an img-safe URL directly. Do not fetch this URL: CSP blocks it. */
export function imageDataUrl(
  relPath: string,
  content: MaterialFileContent
): string | null {
  if (content.encoding !== 'base64') return null
  const mimeType = imageMimeType(relPath)
  return mimeType === null ? null : `data:${mimeType};base64,${content.data}`
}
