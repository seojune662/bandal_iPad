/**
 * Favicons, fetched in main and handed to the renderer as a data URL.
 *
 * The favicon feature was removed once already because the renderer CSP is
 * `img-src 'self' data: bandal-media:` and a remote icon URL is simply
 * blocked. Relaxing the CSP to let the renderer load arbitrary remote images
 * would be the wrong trade for a 16px decoration, so the fetch happens here,
 * through the browsing session (school portals often gate even their favicon
 * behind the login cookie), and only a `data:` URL crosses the boundary.
 *
 * SVG is deliberately NOT accepted: an SVG is a document that can carry
 * script, and a data-URL SVG would be rendered by the privileged renderer.
 */

import { session } from 'electron'
import { BROWSING_PARTITION } from './webviewPolicy'

/** Raster formats only — see the SVG note above. */
const ALLOWED_TYPES = new Set([
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/x-icon',
  'image/vnd.microsoft.icon'
])

/** A favicon is 16–64px; anything larger is not one. */
const MAX_BYTES = 100 * 1024

/** In-memory, per run. A favicon is not worth a file on disk. */
const MAX_CACHE_ENTRIES = 200

export interface FaviconDeps {
  fetch?: (url: string) => Promise<Response>
}

export function createFaviconFetcher(deps: FaviconDeps = {}) {
  const cache = new Map<string, string | null>()
  const doFetch =
    deps.fetch ??
    ((url: string) => session.fromPartition(BROWSING_PARTITION).fetch(url))

  return async function faviconFor(url: string): Promise<string | null> {
    if (cache.has(url)) return cache.get(url) ?? null

    const result = await load(url)
    if (cache.size >= MAX_CACHE_ENTRIES) {
      // Cheap eviction: the oldest key, since Map preserves insertion order.
      const oldest = cache.keys().next().value
      if (oldest !== undefined) cache.delete(oldest)
    }
    cache.set(url, result)
    return result
  }

  async function load(url: string): Promise<string | null> {
    let parsed: URL
    try {
      parsed = new URL(url)
    } catch {
      return null
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null

    try {
      const response = await doFetch(url)
      if (!response.ok) return null
      const type = (response.headers.get('content-type') ?? '')
        .split(';')[0]
        ?.trim()
        .toLowerCase()
      if (type === undefined || !ALLOWED_TYPES.has(type)) return null
      const buffer = Buffer.from(await response.arrayBuffer())
      if (buffer.byteLength === 0 || buffer.byteLength > MAX_BYTES) return null
      return `data:${type};base64,${buffer.toString('base64')}`
    } catch {
      return null
    }
  }
}

/** Test seam: the cache is module state and outlives a single test. */
export function resetFaviconCacheForTests(): void {
  // Each fetcher owns its profile cache.
}
