/**
 * `bandal-plugin://<pluginId>/ui/…` — serves a plugin's panel pages.
 *
 * Pure (no electron import) like `materials/mediaProtocol.ts`. Registered per
 * plugin session in `pluginPanels.ts`, because `Session.protocol` is
 * per-session and plugin guests live in `plugin:<id>` partitions.
 *
 * Surface: ONLY `<root>/ui/**` plus `<root>/styles.css` when the manifest
 * declares it. Every failure — bad URL, unknown plugin, traversal, missing
 * file, directory, unlisted extension — is a 404 so the page cannot probe
 * the filesystem. HTML responses get the panel CSP and, when declared, a
 * `<link rel="stylesheet" href="/styles.css">` injected before `</head>`.
 */

import { readFile as fsReadFile } from 'node:fs/promises'
import { join } from 'node:path'
import { resolveInsideReal } from '../../db/validate'

export const PLUGIN_SCHEME = 'bandal-plugin'
export const PLUGIN_UI_DIR = 'ui'
export const PLUGIN_STYLES_FILE = 'styles.css'

export const PLUGIN_PANEL_CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'none'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'none'"
].join('; ')

const CONTENT_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8'
}

export interface ParsedPluginUrl {
  pluginId: string
  /** Path segments under `ui/` (decoded); empty for the styles request. */
  segments: string[]
  isStyles: boolean
}

function isSafeSegment(segment: string): boolean {
  return (
    segment !== '' &&
    segment !== '.' &&
    segment !== '..' &&
    !segment.includes('/') &&
    !segment.includes('\\') &&
    !segment.includes('\u0000')
  )
}

/** Never throws; null → 404. */
export function parsePluginUrl(url: string): ParsedPluginUrl | null {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return null
  }
  if (parsed.protocol !== `${PLUGIN_SCHEME}:`) return null
  const pluginId = parsed.hostname
  if (pluginId === '') return null

  const rawSegments = parsed.pathname.split('/').slice(1)
  let decoded: string[]
  try {
    decoded = rawSegments.map((segment) => decodeURIComponent(segment))
  } catch {
    return null
  }
  if (decoded.length === 1 && decoded[0] === PLUGIN_STYLES_FILE) {
    return { pluginId, segments: [], isStyles: true }
  }
  const [head, ...rest] = decoded
  if (head !== PLUGIN_UI_DIR || rest.length === 0) return null
  if (!rest.every(isSafeSegment)) return null
  return { pluginId, segments: rest, isStyles: false }
}

export function pluginContentTypeFor(fileName: string): string | null {
  const dot = fileName.lastIndexOf('.')
  if (dot <= 0) return null
  return CONTENT_TYPES[fileName.slice(dot).toLowerCase()] ?? null
}

export interface PluginProtocolDeps {
  /** Absolute plugin folder for an installed plugin, else null. */
  rootFor(pluginId: string): string | null
  /** Whether the manifest declares `styles: 'styles.css'`. */
  stylesFor(pluginId: string): boolean
  readFile?(path: string): Promise<Uint8Array>
}

function notFound(): Response {
  return new Response('not found', {
    status: 404,
    headers: { 'Content-Type': 'text/plain; charset=utf-8' }
  })
}

const STYLES_LINK = `<link rel="stylesheet" href="/${PLUGIN_STYLES_FILE}">`

export function injectStylesLink(html: string): string {
  const index = html.search(/<\/head\s*>/i)
  if (index < 0) return `${STYLES_LINK}${html}`
  return `${html.slice(0, index)}${STYLES_LINK}${html.slice(index)}`
}

export function createPluginProtocolHandler(
  deps: PluginProtocolDeps
): (request: Request) => Promise<Response> {
  const readFile =
    deps.readFile ?? (async (path: string) => new Uint8Array(await fsReadFile(path)))

  return async (request) => {
    const parsed = parsePluginUrl(request.url)
    if (parsed === null) return notFound()
    const root = deps.rootFor(parsed.pluginId)
    if (root === null) return notFound()

    let absPath: string
    let fileName: string
    if (parsed.isStyles) {
      if (!deps.stylesFor(parsed.pluginId)) return notFound()
      fileName = PLUGIN_STYLES_FILE
      absPath = join(root, PLUGIN_STYLES_FILE)
    } else {
      fileName = parsed.segments.at(-1) ?? ''
      const relPath = [PLUGIN_UI_DIR, ...parsed.segments].join('/')
      try {
        absPath = resolveInsideReal(root, relPath)
      } catch {
        return notFound()
      }
    }

    const contentType = pluginContentTypeFor(fileName)
    if (contentType === null) return notFound()

    let bytes: Uint8Array
    try {
      bytes = await readFile(absPath)
    } catch {
      return notFound()
    }

    const headers: Record<string, string> = {
      'Content-Type': contentType,
      'Content-Security-Policy': PLUGIN_PANEL_CSP,
      'X-Content-Type-Options': 'nosniff',
      'Cache-Control': 'no-store'
    }

    if (contentType.startsWith('text/html')) {
      let html = new TextDecoder().decode(bytes)
      if (deps.stylesFor(parsed.pluginId)) html = injectStylesLink(html)
      return new Response(html, { status: 200, headers })
    }
    return new Response(bytes, { status: 200, headers })
  }
}
