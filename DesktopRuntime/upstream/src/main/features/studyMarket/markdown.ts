import { createWikilinkResolver, formatWikilink, parseWikilink, wikilinkPattern } from '../../../shared/wikilink'
import { hasPdfPageNoteHeader, recoverPdfPageNoteAsMarkdown } from '../../../shared/pdfPageNote'
import { createMaterialLink, parseMaterialLink } from '../link/materialLink'

/** Markdown is copied, never edited in the seller's course. */
function outsideCode(markdown: string, transform: (text: string) => string): string {
  // Keep fenced/inline code verbatim: examples of links are not dependencies.
  return markdown.split(/(^ {0,3}(?:`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}(?:`{3,}|~{3,})[^\n]*(?:\n|$)|`+[^`\n]*`+)/gm)
    .map((part, index) => index % 2 === 0 ? transform(part) : part).join('')
}

const inlineLink = (): RegExp => /(!?)\[([^\]\n]*(?:\\.[^\]\n]*)*)\]\(\s*(?:<([^>\n]+)>|((?:\\.|[^\\\s()]|\([^()\n]*\))+))(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^\)\n]*\)))?\s*\)/g
const referenceDefinition = (): RegExp => /^ {0,3}\[([^\]\n]+)\]:\s*(?:<([^>\n]+)>|(\S+))[^\n]*$/gm
const referenceUse = (): RegExp => /(!?)\[([^\]\n]+)\](?:\[([^\]\n]*)\])?(?![([:])/g

function referenceKey(value: string): string { return value.trim().replace(/\s+/g, ' ').toLowerCase() }

/** The app stores relative image URLs relative to the course root. */
export function localMarkdownPath(value: string): string | null {
  let decoded: string
  const path = value.split('#', 1)[0]!
  try { decoded = decodeURIComponent(path.replace(/\\([ ()])/g, '$1')) } catch { decoded = path }
  if (/^[a-z][a-z0-9+.-]*:/i.test(decoded) || decoded.startsWith('#') || decoded.startsWith('/')) return null
  return decoded.replace(/^\.\//, '') || null
}

function references(markdown: string): Map<string, string> {
  const result = new Map<string, string>()
  outsideCode(markdown, text => {
    for (const match of text.matchAll(referenceDefinition())) result.set(referenceKey(match[1]!), match[2] ?? match[3]!)
    return text
  })
  return result
}

export function markdownImageDependencies(markdown: string, coursePaths: readonly string[]): string[] {
  const result = new Set<string>()
  const definitions = references(markdown)
  const resolver = createWikilinkResolver(coursePaths.map(relPath => ({ relPath })))
  const add = (source: string): void => { const path = localMarkdownPath(source); if (path) result.add(path) }
  outsideCode(markdown, text => {
    for (const match of text.matchAll(inlineLink())) if (match[1] === '!') add(match[3] ?? match[4]!)
    for (const match of text.matchAll(referenceUse())) if (match[1] === '!') {
      const target = definitions.get(referenceKey(match[3] || match[2]!)); if (target) add(target)
    }
    for (const match of text.matchAll(wikilinkPattern())) {
      const parsed = parseWikilink(match[0]); if (!parsed?.embed) continue
      const target = resolver.resolve(parsed.target)
      if (target && /\.(?:png|jpe?g|webp)$/i.test(target)) result.add(target)
    }
    return text
  })
  return [...result]
}

export interface MarketMarkdownOptions {
  /** All source files, so an omitted document cannot resolve to another buyer file. */
  coursePaths: readonly string[]
  includedPaths: readonly string[]
  /** Empty when publishing; the fresh bundle directory when importing. */
  prefix?: string
}

export function rewriteMarketMarkdown(source: string, options: MarketMarkdownOptions): string {
  const markdown = hasPdfPageNoteHeader(source) ? recoverPdfPageNoteAsMarkdown(source) : source
  const resolver = createWikilinkResolver(options.coursePaths.map(relPath => ({ relPath })))
  const included = new Map(options.includedPaths.map(path => [path.normalize('NFC').toLowerCase(), path]))
  const exact = (path: string): string | null => included.get(path.normalize('NFC').toLowerCase()) ?? null
  const rebase = (path: string): string => options.prefix ? `${options.prefix}/${path}` : path
  const definitions = references(markdown)
  const mapped = (href: string): string | null => {
    const bandal = parseMaterialLink(href)
    if (bandal) {
      const target = exact(bandal.relPath)
      return target ? createMaterialLink({ relPath: rebase(target), page: bandal.page }) : null
    }
    if (/^bandal:/i.test(href)) return null
    const local = localMarkdownPath(href)
    if (local === null) return /^(?:https?:|mailto:|#|data:image\/(?:png|jpeg|webp);base64,)/i.test(href) ? href : null
    const fragment = href.split('#', 2)[1]
    const target = exact(local)
    return target ? `${rebase(target).split('/').map(part => encodeURIComponent(part).replace(/\(/g, '%28').replace(/\)/g, '%29')).join('/')}${fragment === undefined ? '' : `#${fragment}`}` : null
  }
  return outsideCode(markdown, text => {
    // Reference syntax is processed first, before inline links are emitted.
    let result = text.replace(referenceUse(), (full, _image: string, label: string, ref: string | undefined) => {
      const destination = definitions.get(referenceKey(ref || label))
      if (!destination) return full
      return mapped(destination) === null ? label : full
    })
    result = result.replace(referenceDefinition(), (full, _label: string, angled: string | undefined, bare: string | undefined) => {
      const destination = angled ?? bare!
      const target = mapped(destination)
      return target === null ? '' : full.replace(destination, target)
    })
    result = result.replace(inlineLink(), (_full, image: string, label: string, angled: string | undefined, bare: string | undefined) => {
      const target = mapped(angled ?? bare!)
      return target === null ? label : `${image}[${label}](${target})`
    })
    return result.replace(wikilinkPattern(), full => {
      const parsed = parseWikilink(full)
      if (!parsed) return full
      const resolved = resolver.resolve(parsed.target)
      const target = resolved && exact(resolved)
      if (!target) return parsed.alias ?? parsed.target
      return formatWikilink({ ...parsed, target: rebase(target) })
    })
  })
}
