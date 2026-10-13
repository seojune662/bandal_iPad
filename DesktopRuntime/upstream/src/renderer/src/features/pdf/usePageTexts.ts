import { useCourseActive } from '../workspace/courseActivity'
/**
 * Lazily extracts page text (via the pdf.js document proxy, no rendering
 * required) for every page that carries annotations, so staleness can be
 * shown in the rail even for pages that were never scrolled into view.
 */

import { useEffect, useMemo, useState } from 'react'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import {
  indexExtractedPdfPage,
  type PageTextIndexTarget
} from '../search/pdfPageIndex'
import { isAnchorStale } from './lib/quoteAnchor'
import type { Annotation } from '../../../../shared/types/annotation'

interface TextItemLike {
  str?: string
  hasEOL?: boolean
}

/** Joins pdf.js text items the same way the DOM text layer lays them out. */
export function joinTextItems(items: TextItemLike[]): string {
  let text = ''
  for (const item of items) {
    text += item.str ?? ''
    if (item.hasEOL === true) text += '\n'
  }
  return text
}

/** Map of 1-based page number → extracted text (null while pending). */
export function usePageTexts(
  pdf: PDFDocumentProxy | null,
  annotatedPages: number[],
  indexTarget?: PageTextIndexTarget
): Map<number, string> {
  const courseActive = useCourseActive()
  const [texts, setTexts] = useState<Map<number, string>>(new Map())

  // Reset the cache when the document itself changes.
  useEffect(() => {
    setTexts(new Map())
  }, [pdf])

  const pagesKey = annotatedPages.join(',')

  useEffect(() => {
    if (pdf === null || !courseActive) return
    let cancelled = false
    const missing = annotatedPages.filter((page) => !texts.has(page))
    if (missing.length === 0) return

    void (async () => {
      for (const pageNumber of missing) {
        try {
          await new Promise<void>(resolve => setTimeout(resolve, 32))
          if (cancelled) return
          const page = await pdf.getPage(pageNumber)
          const content = await page.getTextContent()
          if (cancelled) return
          const text = joinTextItems(content.items as TextItemLike[])
          setTexts((current) => {
            if (current.has(pageNumber)) return current
            const next = new Map(current)
            next.set(pageNumber, text)
            return next
          })
          if (indexTarget !== undefined) {
            indexExtractedPdfPage(
              indexTarget,
              pdf.fingerprints[0] ?? 'unknown-fingerprint',
              pageNumber,
              text
            )
          }
        } catch {
          // Text extraction failure → leave page unknown (never marked stale).
        }
      }
    })()

    return () => {
      cancelled = true
    }
    // texts intentionally omitted: re-run is driven by pages/pdf; the
    // in-effect `has` checks make repeats idempotent.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pdf, pagesKey, indexTarget?.courseId, indexTarget?.relPath, courseActive])

  return texts
}

/** Set of annotation ids whose anchors no longer match the page text. */
export function useStaleAnnotationIds(
  annotations: Annotation[],
  pageTexts: Map<number, string>
): Set<string> {
  return useMemo(() => {
    const stale = new Set<string>()
    for (const annotation of annotations) {
      const text = pageTexts.get(annotation.page) ?? null
      if (isAnchorStale(text, annotation.anchor)) {
        stale.add(annotation.id)
      }
    }
    return stale
  }, [annotations, pageTexts])
}
