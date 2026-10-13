import type { PDFDocumentProxy } from 'pdfjs-dist'
import { pageImageSize, type RenderedPageImage } from '../../pageImageCopy/pageImage'

/** Reuse the open PDF, but own a separate render task and bitmap. */
export async function renderPdfPageImage(pdf: PDFDocumentProxy, pageNumber: number, signal: AbortSignal): Promise<RenderedPageImage> {
  signal.throwIfAborted()
  const page = await pdf.getPage(pageNumber)
  signal.throwIfAborted()
  const natural = page.getViewport({ scale: 1 })
  const size = pageImageSize(natural.width, natural.height)
  const viewport = page.getViewport({ scale: Math.min(size.width / natural.width, size.height / natural.height) })
  const canvas = document.createElement('canvas')
  canvas.width = size.width
  canvas.height = size.height
  const release = (): void => { canvas.width = canvas.height = 0 }
  let cancel: (() => void) | undefined
  try {
    const task = page.render({ canvas, viewport, background: 'white' })
    cancel = () => task.cancel()
    signal.addEventListener('abort', cancel, { once: true })
    await task.promise
    signal.throwIfAborted()
    return { canvas, release }
  } catch (error) {
    release()
    throw error
  } finally {
    if (cancel) signal.removeEventListener('abort', cancel)
  }
}
