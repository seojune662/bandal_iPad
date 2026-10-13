import { invoke } from '../../lib/ipc'

export interface PageTextIndexTarget {
  courseId: string
  relPath: string
}

interface PdfPageIndexInput extends PageTextIndexTarget {
  pages: { page: number; text: string }[]
}

type InvokePdfPageIndex = (input: PdfPageIndexInput) => Promise<{ ok: true }>

/** Session-only dedupe; the PDF fingerprint changes when file bytes change. */
const indexedPagesByDocument = new Map<string, Set<number>>()
const MAX_TRACKED_PDF_DOCUMENTS = 100

function trackedPages(key: string): Set<number> {
  const existing = indexedPagesByDocument.get(key)
  if (existing !== undefined) return existing
  if (indexedPagesByDocument.size >= MAX_TRACKED_PDF_DOCUMENTS) {
    const oldest = indexedPagesByDocument.keys().next().value as
      | string
      | undefined
    if (oldest !== undefined) indexedPagesByDocument.delete(oldest)
  }
  const pages = new Set<number>()
  indexedPagesByDocument.set(key, pages)
  return pages
}

/**
 * Sends one already-extracted page to main without awaiting it. Marking before
 * invoke suppresses concurrent repeats; a rejected request clears the mark so
 * a later extraction may retry. Rejections are intentionally swallowed.
 */
export function indexExtractedPdfPage(
  target: PageTextIndexTarget,
  documentFingerprint: string,
  page: number,
  text: string,
  invokeIndex: InvokePdfPageIndex = (input) =>
    invoke('search:indexPdfPages', input)
): void {
  const key = `${target.courseId}\u0000${target.relPath}\u0000${documentFingerprint}`
  const indexedPages = trackedPages(key)
  if (indexedPages.has(page)) return
  indexedPages.add(page)

  try {
    void invokeIndex({ ...target, pages: [{ page, text }] }).catch(() => {
      indexedPages.delete(page)
    })
  } catch {
    indexedPages.delete(page)
  }
}

/** Test-only reset for the module-level remount dedupe. */
export function resetPdfPageIndexTrackerForTests(): void {
  indexedPagesByDocument.clear()
}
