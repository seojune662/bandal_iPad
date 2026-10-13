/**
 * DOM-side selection helpers for the PDF text layer. These translate a live
 * `Selection` inside a rendered pdf.js text layer into the pure inputs the
 * anchor/geometry modules need (page text + character offsets + client
 * rects). Kept separate from the pure modules so those stay unit-testable.
 */

import { buildAnchor } from './quoteAnchor'
import type { AnnotationAnchor } from '../../../../../shared/types/annotation'
import type { RectLike } from './annotationGeometry'

export interface PageSelection {
  /** 1-based page number the selection lives on. */
  page: number
  /** The page wrapper element (positioning context for the page). */
  pageElement: HTMLElement
  anchor: AnnotationAnchor
  /** Raw client rects of the selection range. */
  clientRects: RectLike[]
  /** Client rect of the whole range (toolbar anchoring). */
  boundsClientRect: RectLike
}

function textLayerOf(node: Node): HTMLElement | null {
  const element =
    node instanceof HTMLElement ? node : node.parentElement
  return element?.closest<HTMLElement>('.textLayer') ?? null
}

function pageWrapperOf(element: HTMLElement): HTMLElement | null {
  return element.closest<HTMLElement>('[data-pdf-page]')
}

/**
 * Character offset of (container, offset) within the text layer, counting
 * the concatenated text of all its text nodes in document order.
 */
function offsetWithin(layer: HTMLElement, container: Node, offset: number): number {
  const range = document.createRange()
  range.selectNodeContents(layer)
  range.setEnd(container, offset)
  return range.toString().length
}

/** Full text of a page's text layer (matches offsetWithin's counting). */
export function textLayerText(layer: HTMLElement): string {
  return layer.textContent ?? ''
}

/**
 * Reads the current selection if (and only if) it is fully contained in a
 * single page's text layer. Returns null otherwise.
 */
export function readPageSelection(selection: Selection | null): PageSelection | null {
  if (selection === null || selection.isCollapsed || selection.rangeCount === 0) {
    return null
  }
  const range = selection.getRangeAt(0)
  const startLayer = textLayerOf(range.startContainer)
  const endLayer = textLayerOf(range.endContainer)
  if (startLayer === null || startLayer !== endLayer) return null

  const pageElement = pageWrapperOf(startLayer)
  if (pageElement === null) return null
  const page = Number(pageElement.dataset['pdfPage'])
  if (!Number.isInteger(page) || page < 1) return null

  const pageText = textLayerText(startLayer)
  const start = offsetWithin(startLayer, range.startContainer, range.startOffset)
  const end = offsetWithin(startLayer, range.endContainer, range.endOffset)
  const anchor = buildAnchor(pageText, start, end)
  if (anchor === null) return null

  const clientRects = [...range.getClientRects()].map((rect) => ({
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height
  }))
  if (clientRects.length === 0) return null
  const bounds = range.getBoundingClientRect()

  return {
    page,
    pageElement,
    anchor,
    clientRects,
    boundsClientRect: {
      left: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height
    }
  }
}
