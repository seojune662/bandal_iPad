const EVENT = 'bandal:open-pdf-page-note'
const pending = new Set<string>()

function key(courseId: string, relPath: string): string {
  return `${courseId}\u0000${relPath.normalize('NFC').toLocaleLowerCase()}`
}

export interface OpenPdfPageNoteTarget {
  courseId: string
  relPath: string
}

export function requestOpenPdfPageNote(target: OpenPdfPageNoteTarget): void {
  pending.add(key(target.courseId, target.relPath))
  window.dispatchEvent(new CustomEvent(EVENT, { detail: target }))
}

export function takeOpenPdfPageNote(
  courseId: string,
  relPath: string
): boolean {
  return pending.delete(key(courseId, relPath))
}

export function subscribeOpenPdfPageNote(
  listener: (target: OpenPdfPageNoteTarget) => void
): () => void {
  const handle = (event: Event): void => {
    if (!(event instanceof CustomEvent)) return
    const detail = event.detail as Partial<OpenPdfPageNoteTarget>
    if (typeof detail.courseId === 'string' && typeof detail.relPath === 'string') {
      listener({ courseId: detail.courseId, relPath: detail.relPath })
    }
  }
  window.addEventListener(EVENT, handle)
  return () => window.removeEventListener(EVENT, handle)
}
