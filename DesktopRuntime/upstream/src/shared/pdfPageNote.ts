/**
 * Portable on-disk format for a markdown note whose pages mirror a PDF.
 * Metadata and page boundaries are HTML comments so the file remains useful
 * in every ordinary markdown editor.
 */

import type { TabDescriptor } from './tabs'

export function isPageNoteSource(descriptor: TabDescriptor): descriptor is Extract<TabDescriptor, { kind: 'pdf' | 'file' }> {
  return descriptor.kind === 'pdf' || (descriptor.kind === 'file' && /\.pptx?$/i.test(descriptor.payload.relPath))
}

export interface PdfPageSize {
  width: number
  height: number
}

export interface PdfPageNoteManifest {
  version: 1
  /** URI-encoded course-relative path; encoding prevents `-->` in filenames. */
  source: string
  fingerprint: string
  pages: PdfPageSize[]
}

export interface PdfPageNoteDocument {
  manifest: PdfPageNoteManifest
  title: string
  pages: string[]
  /** Preserved notes from PDF pages that no longer exist. */
  appendix: string
}

/** Persisted in dockview panel params, not in the tab descriptor identity. */
export interface PdfPageNotePairContext {
  connectionId: string
  pairId: string
  role: 'pdf' | 'note'
  initialPage: number
}

export function isPdfPageNotePairContext(
  value: unknown
): value is PdfPageNotePairContext {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return (
    typeof candidate['connectionId'] === 'string' &&
    candidate['connectionId'].length > 0 &&
    typeof candidate['pairId'] === 'string' &&
    candidate['pairId'].length > 0 &&
    (candidate['role'] === 'pdf' || candidate['role'] === 'note') &&
    typeof candidate['initialPage'] === 'number' &&
    Number.isInteger(candidate['initialPage']) &&
    candidate['initialPage'] > 0
  )
}

const MANIFEST_PREFIX = '<!-- bandal:pdf-page-note '
const MANIFEST_SUFFIX = ' -->'
const PAGE_MARKER = /^<!-- bandal:page (\d+) -->[ \t]*$/gm
const APPENDIX_MARKER = '<!-- bandal:appendix -->'

export function hasPdfPageNoteHeader(markdown: string): boolean {
  return markdown.startsWith(MANIFEST_PREFIX)
}

/**
 * Turns even a partially damaged page note into ordinary, readable Markdown.
 * The source file is never changed; callers use this content for a safe copy.
 */
export function recoverPdfPageNoteAsMarkdown(markdown: string): string {
  const firstLineEnd = markdown.indexOf('\n')
  const body = hasPdfPageNoteHeader(markdown)
    ? firstLineEnd < 0
      ? ''
      : markdown.slice(firstLineEnd + 1)
    : markdown
  const recovered = body
    .replace(/^<!-- bandal:page (\d+) -->[ \t]*$/gm, (_marker, page: string) =>
      `## PDF ${page}쪽 필기`
    )
    .replace(/^<!-- bandal:appendix -->[ \t]*$/gm, '## 연결 제외된 페이지')
    .trim()
  return `${recovered || '# 복구된 PDF 페이지 필기'}\n`
}

function validPageSize(value: unknown): value is PdfPageSize {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return (
    typeof candidate['width'] === 'number' &&
    Number.isFinite(candidate['width']) &&
    candidate['width'] > 0 &&
    typeof candidate['height'] === 'number' &&
    Number.isFinite(candidate['height']) &&
    candidate['height'] > 0
  )
}

export function isPdfPageNoteManifest(
  value: unknown
): value is PdfPageNoteManifest {
  if (typeof value !== 'object' || value === null) return false
  const candidate = value as Record<string, unknown>
  return (
    candidate['version'] === 1 &&
    typeof candidate['source'] === 'string' &&
    typeof candidate['fingerprint'] === 'string' &&
    Array.isArray(candidate['pages']) &&
    candidate['pages'].length > 0 &&
    candidate['pages'].every(validPageSize)
  )
}

export function sourceRelPath(manifest: PdfPageNoteManifest): string {
  try {
    return decodeURIComponent(manifest.source)
  } catch {
    return manifest.source
  }
}

function cleanPageContent(markdown: string): string {
  return markdown.replace(/^\n+|\s+$/g, '')
}

export function createPdfPageNoteMarkdown(
  title: string,
  source: string,
  fingerprint: string,
  pageSizes: readonly PdfPageSize[],
  contents: readonly string[] = [],
  appendix = ''
): string {
  if (pageSizes.length === 0) {
    throw new TypeError('A PDF page note needs at least one page')
  }
  const manifest: PdfPageNoteManifest = {
    version: 1,
    source: encodeURIComponent(source),
    fingerprint,
    pages: pageSizes.map(({ width, height }) => ({ width, height }))
  }
  const safeTitle = title.replace(/[\r\n]+/g, ' ').trim() || 'PDF 페이지 필기'
  const sections = pageSizes.map((_, index) => {
    const content = cleanPageContent(contents[index] ?? '')
    return `<!-- bandal:page ${index + 1} -->${content.length > 0 ? `\n\n${content}` : ''}`
  })
  const cleanAppendix = cleanPageContent(appendix)
  const appendixSection = cleanAppendix.length === 0
    ? ''
    : `\n\n${APPENDIX_MARKER}\n\n${cleanAppendix}`
  return `${MANIFEST_PREFIX}${JSON.stringify(manifest)}${MANIFEST_SUFFIX}\n# ${safeTitle}\n\n${sections.join('\n\n')}${appendixSection}\n`
}

export function parsePdfPageNote(
  markdown: string
): PdfPageNoteDocument | null {
  const firstLineEnd = markdown.indexOf('\n')
  const firstLine = markdown.slice(0, firstLineEnd < 0 ? markdown.length : firstLineEnd)
  if (!firstLine.startsWith(MANIFEST_PREFIX) || !firstLine.endsWith(MANIFEST_SUFFIX)) {
    return null
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(
      firstLine.slice(MANIFEST_PREFIX.length, -MANIFEST_SUFFIX.length)
    )
  } catch {
    return null
  }
  if (!isPdfPageNoteManifest(parsed)) return null

  const markers = [...markdown.matchAll(PAGE_MARKER)]
  if (markers.length === 0) return null
  const title = /^#\s+(.+)$/m.exec(
    markdown.slice(firstLineEnd < 0 ? 0 : firstLineEnd + 1, markers[0]?.index ?? 0)
  )?.[1]?.trim() ?? 'PDF 페이지 필기'
  const pages: string[] = []
  const appendixIndex = markdown.indexOf(APPENDIX_MARKER)
  for (let index = 0; index < markers.length; index += 1) {
    const marker = markers[index]
    if (Number(marker?.[1]) !== index + 1 || marker?.index === undefined) return null
    const start = marker.index + marker[0].length
    const end = markers[index + 1]?.index ??
      (appendixIndex >= 0 ? appendixIndex : markdown.length)
    pages.push(cleanPageContent(markdown.slice(start, end)))
  }
  if (pages.length !== parsed.pages.length) return null
  const appendix = appendixIndex < 0
    ? ''
    : cleanPageContent(markdown.slice(appendixIndex + APPENDIX_MARKER.length))
  return { manifest: parsed, title, pages, appendix }
}

export function serializePdfPageNote(document: PdfPageNoteDocument): string {
  return createPdfPageNoteMarkdown(
    document.title,
    sourceRelPath(document.manifest),
    document.manifest.fingerprint,
    document.manifest.pages,
    document.pages,
    document.appendix
  )
}

export function reconcilePdfPageNote(
  document: PdfPageNoteDocument,
  source: string,
  fingerprint: string,
  pageSizes: readonly PdfPageSize[]
): PdfPageNoteDocument {
  const pages = pageSizes.map((_, index) => document.pages[index] ?? '')
  const removed = document.pages
    .slice(pageSizes.length)
    .map((content, index) => ({
      page: pageSizes.length + index + 1,
      content: cleanPageContent(content)
    }))
    .filter(({ content }) => content.length > 0)
  const archived = removed.length === 0
    ? ''
    : [
        '## 연결 제외된 페이지',
        '',
        ...removed.flatMap(({ page, content }) => [
          `### 기존 PDF ${page}쪽`,
          '',
          content,
          ''
        ])
      ].join('\n').trim()
  return {
    title: document.title,
    manifest: {
      version: 1,
      source: encodeURIComponent(source),
      fingerprint,
      pages: pageSizes.map(({ width, height }) => ({ width, height }))
    },
    pages,
    appendix: [document.appendix, archived].filter(Boolean).join('\n\n')
  }
}
