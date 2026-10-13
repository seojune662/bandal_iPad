export interface PdfPageNavigationTarget {
  courseId: string
  relPath: string
  page: number
}

export const PDF_PAGE_NAVIGATION_EVENT = 'bandal:pdf-page-navigation'

const pendingPages = new Map<string, number>()

function targetKey(courseId: string, relPath: string): string {
  return JSON.stringify([courseId, relPath])
}

export function requestPdfPageNavigation(target: PdfPageNavigationTarget): void {
  pendingPages.set(targetKey(target.courseId, target.relPath), target.page)
  window.dispatchEvent(new CustomEvent(PDF_PAGE_NAVIGATION_EVENT, { detail: target }))
}

export function takePdfPageNavigation(
  courseId: string,
  relPath: string
): number | null {
  const key = targetKey(courseId, relPath)
  const page = pendingPages.get(key)
  if (page === undefined) return null
  pendingPages.delete(key)
  return page
}
