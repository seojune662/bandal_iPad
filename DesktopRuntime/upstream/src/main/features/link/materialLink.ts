import {
  BANDAL_LINK_SCHEME,
  type MaterialLink
} from '../../../shared/types/link'

const MATERIAL_LINK_TARGET = 'material'

/** encodeURIComponent plus the RFC 3986 characters that can break markdown. */
function encodeQueryComponent(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  )
}

/** Creates the portable URL stored in an ordinary markdown link. */
export function createMaterialLink(link: MaterialLink): string {
  const query = [`path=${encodeQueryComponent(link.relPath)}`]
  if (link.page !== null) query.push(`page=${link.page}`)
  if (link.annotationId !== undefined) {
    query.push(`annotationId=${encodeQueryComponent(link.annotationId)}`)
  }
  return `${BANDAL_LINK_SCHEME}//${MATERIAL_LINK_TARGET}?${query.join('&')}`
}

/**
 * Parses only Bandal material links. Invalid, foreign, and future Bandal
 * routes are deliberately returned as null so callers never guess.
 */
export function parseMaterialLink(href: string): MaterialLink | null {
  if (typeof href !== 'string' || href.trim().length === 0) return null

  let url: URL
  try {
    url = new URL(href.trim())
  } catch {
    return null
  }

  if (
    url.protocol !== BANDAL_LINK_SCHEME ||
    url.hostname !== MATERIAL_LINK_TARGET ||
    (url.pathname !== '' && url.pathname !== '/')
  ) {
    return null
  }

  const relPath = url.searchParams.get('path')
  if (relPath === null || relPath.length === 0) return null

  const rawPage = url.searchParams.get('page')
  let page: number | null = null
  if (rawPage !== null) {
    if (!/^\d+$/.test(rawPage)) return null
    page = Number(rawPage)
    if (!Number.isSafeInteger(page) || page < 1) return null
  }

  const annotationId = url.searchParams.get('annotationId')
  return annotationId === null || annotationId.length === 0
    ? { relPath, page }
    : { relPath, page, annotationId }
}
