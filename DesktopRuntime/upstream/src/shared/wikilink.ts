/**
 * Obsidian-style wikilinks — the pure half shared by the note editor
 * (renderer), the backlink index and the rename repointer (main).
 *
 *   [[target]]  [[target|alias]]  [[target#heading]]  ![[file.png]]
 *
 * A target is matched against the course's materials by a comparison key
 * (NFC + lowercase, trailing `.md` dropped) so `[[강의 1]]` finds `강의 1.md`
 * whether the filesystem spelled it NFC or NFD, and `[[Chap1]]` finds
 * `Chap1.pdf` when no note of that name exists. Keys are comparison-only:
 * every resolved value is the filesystem's own spelling.
 */

export interface WikilinkParts {
  target: string
  heading: string | null
  alias: string | null
  embed: boolean
}

export interface WikilinkFile {
  relPath: string
}

const WIKILINK_SOURCE =
  '!?\\[\\[([^\\[\\]|#\\n]+?)(?:#([^\\[\\]|\\n]+?))?(?:\\|([^\\[\\]\\n]+?))?\\]\\]'

/**
 * Global pattern for scanning documents. `String#matchAll` and `replace`
 * reset `lastIndex`, but callers that `exec` in a loop should take a fresh
 * copy from `wikilinkPattern()` so state cannot leak between scans.
 */
export const WIKILINK_RE = new RegExp(WIKILINK_SOURCE, 'gu')

const WIKILINK_WHOLE_RE = new RegExp(`^${WIKILINK_SOURCE}$`, 'u')

const NOTE_EXTENSION_RE = /\.(?:md|markdown)$/iu
const ANY_EXTENSION_RE = /\.[^./]+$/u

/** Fresh global RegExp — safe for `exec` loops and `mdast-util-find-and-replace`. */
export function wikilinkPattern(): RegExp {
  return new RegExp(WIKILINK_SOURCE, 'gu')
}

function emptyToNull(value: string | undefined): string | null {
  if (value === undefined) return null
  const trimmed = value.trim()
  return trimmed.length === 0 ? null : trimmed
}

/** Parses one complete wikilink; anything else (including surrounding text) is null. */
export function parseWikilink(text: string): WikilinkParts | null {
  const match = WIKILINK_WHOLE_RE.exec(text)
  if (match === null) return null
  const target = match[1]?.trim() ?? ''
  if (target.length === 0) return null
  return {
    target,
    heading: emptyToNull(match[2]),
    alias: emptyToNull(match[3]),
    embed: text.startsWith('!')
  }
}

export function formatWikilink(parts: WikilinkParts): string {
  const heading = parts.heading === null ? '' : `#${parts.heading}`
  const alias = parts.alias === null ? '' : `|${parts.alias}`
  return `${parts.embed ? '!' : ''}[[${parts.target}${heading}${alias}]]`
}

/** Comparison key: NFC, trimmed, lowercase, trailing `.md`/`.markdown` dropped. */
export function wikilinkKey(value: string): string {
  return value.normalize('NFC').trim().toLowerCase().replace(NOTE_EXTENSION_RE, '')
}

function basenameOf(relPath: string): string {
  return relPath.split('/').at(-1) ?? relPath
}

/** `Chap1.pdf` → `Chap1`; `Chap1.md` → `Chap1`; `README` → `README`. */
export function wikilinkStem(relPath: string): string {
  return basenameOf(relPath).replace(ANY_EXTENSION_RE, '')
}

export function isNoteRelPath(relPath: string): boolean {
  return NOTE_EXTENSION_RE.test(relPath)
}

export interface WikilinkResolver {
  resolve: (target: string) => string | null
}

function pickBest(candidates: readonly string[]): string | null {
  if (candidates.length === 0) return null
  const [best] = [...candidates].sort((a, b) => {
    const noteA = isNoteRelPath(a) ? 0 : 1
    const noteB = isNoteRelPath(b) ? 0 : 1
    if (noteA !== noteB) return noteA - noteB
    if (a.length !== b.length) return a.length - b.length
    return a < b ? -1 : a > b ? 1 : 0
  })
  return best ?? null
}

function appendTo(map: Map<string, string[]>, key: string, relPath: string): void {
  const existing = map.get(key)
  if (existing === undefined) map.set(key, [relPath])
  else if (!existing.includes(relPath)) existing.push(relPath)
}

/**
 * Builds the lookup maps once so a scan of many notes resolves each link in
 * O(1). Match order: exact relPath (with or without `.md`) → basename (with
 * or without extension) → ties prefer notes, then the shortest relPath.
 */
export function createWikilinkResolver(
  files: readonly WikilinkFile[]
): WikilinkResolver {
  const byPath = new Map<string, string[]>()
  const byBasename = new Map<string, string[]>()
  for (const file of files) {
    appendTo(byPath, wikilinkKey(file.relPath), file.relPath)
    appendTo(byBasename, wikilinkKey(basenameOf(file.relPath)), file.relPath)
    appendTo(byBasename, wikilinkKey(wikilinkStem(file.relPath)), file.relPath)
  }
  return {
    resolve: (target) => {
      const key = wikilinkKey(target)
      if (key.length === 0) return null
      return pickBest(byPath.get(key) ?? []) ?? pickBest(byBasename.get(key) ?? [])
    }
  }
}

/** One-off resolution; build a `WikilinkResolver` when resolving many links. */
export function resolveWikilinkTarget(
  target: string,
  files: readonly WikilinkFile[]
): string | null {
  return createWikilinkResolver(files).resolve(target)
}
