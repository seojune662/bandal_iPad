/**
 * Pure geometry helpers for PDF highlights.
 *
 * Client rects coming from `Range.getClientRects()` are normalized into
 * page-relative percentage coordinates (0..1, matching AnnotationRect in
 * the shared contract) so they survive zooming and window resizes. The
 * inverse converts them back to CSS pixel boxes for a rendered page.
 */

import type { AnnotationRect } from '../../../../../shared/types/annotation'

/** Structural subset of DOMRect so the logic stays testable without a DOM. */
export interface RectLike {
  left: number
  top: number
  width: number
  height: number
}

/** Rects smaller than this fraction of the page in either axis are noise. */
const MIN_RECT_FRACTION = 0.001

/** Vertical overlap ratio above which two rects count as "same line". */
const SAME_LINE_OVERLAP = 0.5

const clamp01 = (value: number): number => Math.min(1, Math.max(0, value))

/** Normalizes one client rect against the page's client rect. */
export function normalizeRect(rect: RectLike, page: RectLike): AnnotationRect {
  if (page.width <= 0 || page.height <= 0) {
    return { x: 0, y: 0, width: 0, height: 0 }
  }
  const x = clamp01((rect.left - page.left) / page.width)
  const y = clamp01((rect.top - page.top) / page.height)
  const right = clamp01((rect.left + rect.width - page.left) / page.width)
  const bottom = clamp01((rect.top + rect.height - page.top) / page.height)
  return { x, y, width: right - x, height: bottom - y }
}

/** Converts a normalized rect back into CSS pixels for a rendered page. */
export function denormalizeRect(
  rect: AnnotationRect,
  pageWidth: number,
  pageHeight: number
): RectLike {
  return {
    left: rect.x * pageWidth,
    top: rect.y * pageHeight,
    width: rect.width * pageWidth,
    height: rect.height * pageHeight
  }
}

function verticalOverlap(a: AnnotationRect, b: AnnotationRect): number {
  const top = Math.max(a.y, b.y)
  const bottom = Math.min(a.y + a.height, b.y + b.height)
  const overlap = bottom - top
  const minHeight = Math.min(a.height, b.height)
  if (minHeight <= 0) return 0
  return overlap / minHeight
}

function horizontallyTouching(a: AnnotationRect, b: AnnotationRect): boolean {
  const gap = Math.max(a.x, b.x) - Math.min(a.x + a.width, b.x + b.width)
  return gap <= MIN_RECT_FRACTION * 4
}

function union(a: AnnotationRect, b: AnnotationRect): AnnotationRect {
  const x = Math.min(a.x, b.x)
  const y = Math.min(a.y, b.y)
  return {
    x,
    y,
    width: Math.max(a.x + a.width, b.x + b.width) - x,
    height: Math.max(a.y + a.height, b.y + b.height) - y
  }
}

/**
 * Merges the raw line-fragment rects a selection produces into clean
 * per-line boxes: drops sub-pixel noise, then unions rects that sit on the
 * same text line and touch or overlap horizontally.
 */
export function mergeRects(rects: AnnotationRect[]): AnnotationRect[] {
  const usable = rects.filter(
    (rect) => rect.width > MIN_RECT_FRACTION && rect.height > MIN_RECT_FRACTION
  )
  const sorted = [...usable].sort((a, b) => a.y - b.y || a.x - b.x)

  const merged: AnnotationRect[] = []
  for (const rect of sorted) {
    const previous = merged[merged.length - 1]
    if (
      previous !== undefined &&
      verticalOverlap(previous, rect) >= SAME_LINE_OVERLAP &&
      horizontallyTouching(previous, rect)
    ) {
      merged[merged.length - 1] = union(previous, rect)
    } else {
      merged.push(rect)
    }
  }
  return merged
}

/**
 * Full pipeline: client rects → normalized page space → merged lines.
 * Returns an empty array when nothing usable remains (caller should treat
 * that as "no highlight to create").
 */
export function normalizeSelectionRects(
  rects: RectLike[],
  page: RectLike
): AnnotationRect[] {
  return mergeRects(rects.map((rect) => normalizeRect(rect, page)))
}

/** Point-in-rects hit test (page-relative 0..1 coords). */
export function rectsContainPoint(
  rects: AnnotationRect[],
  x: number,
  y: number
): boolean {
  return rects.some(
    (rect) =>
      x >= rect.x &&
      x <= rect.x + rect.width &&
      y >= rect.y &&
      y <= rect.y + rect.height
  )
}

/** Topmost point of an annotation's rects — used for popover anchoring. */
export function rectsBoundingBox(rects: AnnotationRect[]): AnnotationRect {
  if (rects.length === 0) return { x: 0, y: 0, width: 0, height: 0 }
  let minX = 1
  let minY = 1
  let maxX = 0
  let maxY = 0
  for (const rect of rects) {
    minX = Math.min(minX, rect.x)
    minY = Math.min(minY, rect.y)
    maxX = Math.max(maxX, rect.x + rect.width)
    maxY = Math.max(maxY, rect.y + rect.height)
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
}
