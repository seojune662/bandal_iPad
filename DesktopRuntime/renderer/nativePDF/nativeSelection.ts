import type { PDFDocumentProxy, PDFPageProxy } from 'pdfjs-dist'
import type { AnnotationAnchor, AnnotationRect } from '../../upstream/src/shared/types/annotation'
import { buildAnchor, normalizeWhitespace } from '../../upstream/src/renderer/src/features/pdf/lib/quoteAnchor'

export interface NativeSelectionQuote { page: number; quote: string; rects: AnnotationRect[] }
interface Item {
  str: string; start: number; end: number
  transform?: number[]; width?: number; height?: number; dir?: string; vertical?: boolean | undefined; ascent?: number | undefined
}
interface PageText { text: string; items: Item[]; viewport: ReturnType<PDFPageProxy['getViewport']> }
const documents = new WeakMap<PDFDocumentProxy, Map<number, Promise<PageText>>>()

/** Match the original desktop page-text index: str, followed only by hasEOL.
 * Keep extraction outside the selection UI and bound each document to 8 pages. */
function pageText(pdf: PDFDocumentProxy, pageNumber: number): Promise<PageText> {
  let pages = documents.get(pdf)
  if (!pages) { pages = new Map(); documents.set(pdf, pages) }
  const previous = pages.get(pageNumber)
  if (previous) return previous
  const pending = (async (): Promise<PageText> => {
    const page = await pdf.getPage(pageNumber), content = await page.getTextContent()
    let text = ''; const items: Item[] = []
    for (const item of content.items) {
      if (!('str' in item)) continue
      const start = text.length; text += item.str
      const font = content.styles[item.fontName]
      items.push({ ...item, start, end: text.length, vertical: font?.vertical, ascent: font?.ascent })
      if (item.hasEOL) text += '\n'
    }
    return { text, items, viewport: page.getViewport({ scale: 1 }) }
  })()
  pages.set(pageNumber, pending)
  if (pages.size > 8) pages.delete(pages.keys().next().value!)
  void pending.catch(() => { if (pages?.get(pageNumber) === pending) pages.delete(pageNumber) })
  return pending
}

/** Preserve original UTF-16 offsets while collapsing whitespace like findAnchor. */
function normalizedIndex(text: string): { text: string; starts: number[]; ends: number[] } {
  let normalized = '', whitespace = -1
  const starts: number[] = [], ends: number[] = []
  for (let index = 0; index < text.length; index++) {
    if (/\s/.test(text[index]!)) { if (whitespace < 0) whitespace = index; continue }
    if (whitespace >= 0 && normalized.length) { normalized += ' '; starts.push(whitespace); ends.push(index) }
    whitespace = -1; normalized += text[index]; starts.push(index); ends.push(index + 1)
  }
  return { text: normalized, starts, ends }
}

function usable(rect: AnnotationRect): boolean {
  return [rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) && rect.width > 0 && rect.height > 0
}
function distance(a: AnnotationRect, b: AnnotationRect): number {
  const dx = Math.max(0, a.x - b.x - b.width, b.x - a.x - a.width)
  const dy = Math.max(0, a.y - b.y - b.height, b.y - a.y - a.height)
  // Rectangle overlap first, then center proximity to disambiguate repeated
  // phrases within one long text item. This is only a locator, never saved geometry.
  return Math.hypot(dx, dy) * 4 + Math.hypot(a.x + a.width / 2 - b.x - b.width / 2, a.y + a.height / 2 - b.y - b.height / 2)
}
function textRect(item: Item, start: number, end: number, viewport: PageText['viewport']): AnnotationRect | null {
  const matrix = item.transform
  if (!matrix || matrix.length < 6 || !matrix.every(Number.isFinite) || !Number.isFinite(item.width) || !Number.isFinite(item.height)) return null
  const [a = 0, b = 0, c = 0, d = 0, x = 0, y = 0] = matrix
  const magnitude = Math.hypot(a, b), fontHeight = Math.hypot(c, d), height = fontHeight || Math.abs(item.height ?? 0)
  if (!magnitude || !height || viewport.width <= 0 || viewport.height <= 0) return null
  let ux = a / magnitude, uy = b / magnitude
  if (item.vertical) { const old = ux; ux = -uy; uy = old }
  const vx = !item.vertical && fontHeight ? c / fontHeight : -uy, vy = !item.vertical && fontHeight ? d / fontHeight : ux
  const length = item.end - item.start
  let from = (start - item.start) / length, to = (end - item.start) / length
  if (item.dir === 'rtl') { const old = from; from = 1 - to; to = 1 - old }
  const advance = Math.abs(item.vertical ? item.height ?? 0 : item.width ?? 0)
  const ascent = Number.isFinite(item.ascent) ? item.ascent! : 0.8
  const corners = [from, to].flatMap(fraction => [ascent, ascent - 1].map(vertical =>
    viewport.convertToViewportPoint(x + ux * advance * fraction + vx * height * vertical, y + uy * advance * fraction + vy * height * vertical)))
  const xs = corners.map(point => point[0]!), ys = corners.map(point => point[1]!)
  return { x: Math.min(...xs) / viewport.width, y: Math.min(...ys) / viewport.height,
    width: (Math.max(...xs) - Math.min(...xs)) / viewport.width, height: (Math.max(...ys) - Math.min(...ys)) / viewport.height }
}

/** Reuse the desktop quote-anchor contract for PDFKit selections. Context comes
 * from PDF.js's original page text; repeated phrases are located with the native
 * selection rectangles in rotated display coordinates. Ambiguity/extraction
 * errors preserve the selected quote instead of inventing surrounding text.
 * Callers must discard a late result after their selection/document changes. */
export async function resolveNativeSelectionAnchor(pdf: PDFDocumentProxy | null, selection: NativeSelectionQuote): Promise<AnnotationAnchor> {
  const fallback = { quote: selection.quote, prefix: '', suffix: '' }
  if (!pdf || !Number.isInteger(selection.page) || selection.page < 1 || selection.page > pdf.numPages) return fallback
  const quote = normalizeWhitespace(selection.quote)
  if (!quote) return fallback
  try {
    const page = await pageText(pdf, selection.page), index = normalizedIndex(page.text)
    const candidates: Array<{ start: number; end: number; distance: number }> = []
    const rects = selection.rects.filter(usable)
    let from = 0
    for (let count = 0; count < 256; count++) {
      const match = index.text.indexOf(quote, from)
      if (match < 0) break
      const start = index.starts[match]!, end = index.ends[match + quote.length - 1]!
      const positions = page.items.filter(item => item.end > start && item.start < end && item.str.length).map(item =>
        textRect(item, Math.max(start, item.start), Math.min(end, item.end), page.viewport)).filter((rect): rect is AnnotationRect => !!rect && usable(rect))
      const proximity = rects.length && positions.length ? positions.reduce((sum, rect) => sum + Math.min(...rects.map(native => distance(rect, native))), 0) / positions.length : Infinity
      candidates.push({ start, end, distance: proximity }); from = match + 1
    }
    if (index.text.indexOf(quote, from) >= 0) return fallback
    if (!candidates.length) return fallback
    candidates.sort((a, b) => a.distance - b.distance)
    const best = candidates[0]!
    if (candidates.length > 1 && (!Number.isFinite(best.distance) || best.distance > 0.2 || Math.abs(best.distance - candidates[1]!.distance) < 0.001)) return fallback
    const anchor = buildAnchor(page.text, best.start, best.end)
    return anchor ? { ...anchor, quote: selection.quote } : fallback
  } catch { return fallback }
}
