import { normalizeHttpUrl } from '../../shared/universities/courseLink'

const EXPLICIT_HTTP_SCHEME = /^https?:/i

/** Returns the canonical URL that may be handed to the OS, or null. */
export function normalizeAllowedExternalUrl(rawUrl: string): string | null {
  const trimmed = rawUrl.trim()
  if (EXPLICIT_HTTP_SCHEME.test(trimmed)) {
    return normalizeHttpUrl(trimmed)
  }

  try {
    const parsed = new URL(trimmed)
    return parsed.protocol === 'mailto:' ? parsed.href : null
  } catch {
    return null
  }
}

export function isAllowedExternalUrl(url: string): boolean {
  return normalizeAllowedExternalUrl(url) !== null
}

export function externalUrlScheme(rawUrl: string): string {
  try {
    return new URL(rawUrl.trim()).protocol.toLowerCase()
  } catch {
    const match = /^([a-z][a-z0-9+.-]*):/i.exec(rawUrl.trim())
    return match === null ? '(unknown)' : `${match[1]!.toLowerCase()}:`
  }
}
