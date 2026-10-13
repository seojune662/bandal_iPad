import { pdfjs } from 'react-pdf'
import type { DrawingBox, DrawingClipSource } from '../../../../shared/types/drawing'
import { mediaUrlFor } from '../materials/mediaUrl'
import type { RenderClip } from '../ink'
import './pdfWorker'

interface RenderedPage {
  canvas: HTMLCanvasElement
}

const PAGE_RENDER_WIDTH_PX = 1400
const PAGE_CACHE_LIMIT = 8
const OUTPUT_CACHE_LIMIT = 24
const pageCache = new Map<string, Promise<RenderedPage | null>>()

function touchPageCache(
  key: string,
  value: Promise<RenderedPage | null>
): void {
  pageCache.delete(key)
  pageCache.set(key, value)
  while (pageCache.size > PAGE_CACHE_LIMIT) {
    const oldest = pageCache.keys().next().value as string | undefined
    if (oldest === undefined) return
    pageCache.delete(oldest)
  }
}

async function renderPdfPage(
  courseId: string,
  source: DrawingClipSource
): Promise<RenderedPage | null> {
  try {
    // bandal-media:// URL — CSP connect-src 가 이 스킴을 허용하므로 pdf.js 가
    // 직접 range fetch 한다. base64-over-IPC 시절의 64MB 캡·전체 상주 없음.
    const loadingTask = pdfjs.getDocument({
      url: mediaUrlFor(courseId, source.relPath),
      disableStream: true,
      disableAutoFetch: true
    })
    const document = await loadingTask.promise
    try {
      if (source.page > document.numPages) return null
      const page = await document.getPage(source.page)
      const naturalViewport = page.getViewport({ scale: 1 })
      if (naturalViewport.width <= 0 || naturalViewport.height <= 0) return null
      const viewport = page.getViewport({
        scale: PAGE_RENDER_WIDTH_PX / naturalViewport.width
      })
      const canvas = window.document.createElement('canvas')
      canvas.width = Math.max(1, Math.round(viewport.width))
      canvas.height = Math.max(1, Math.round(viewport.height))
      const context = canvas.getContext('2d', { alpha: false })
      if (context === null) return null
      await page.render({ canvas, canvasContext: context, viewport }).promise
      return { canvas }
    } finally {
      await document.destroy()
    }
  } catch {
    return null
  }
}

function pageFor(
  courseId: string,
  source: DrawingClipSource
): Promise<RenderedPage | null> {
  const key = JSON.stringify([courseId, source.relPath, source.page])
  const cached = pageCache.get(key)
  if (cached !== undefined) {
    touchPageCache(key, cached)
    return cached
  }
  const pending = renderPdfPage(courseId, source)
  touchPageCache(key, pending)
  void pending.then((page) => {
    if (page === null && pageCache.get(key) === pending) pageCache.delete(key)
  })
  return pending
}

function cropCanvas(
  page: HTMLCanvasElement,
  crop: DrawingBox | undefined
): HTMLCanvasElement | null {
  if (crop === undefined) return page
  const x = Math.round(crop.x * page.width)
  const y = Math.round(crop.y * page.height)
  const width = Math.max(1, Math.round(crop.width * page.width))
  const height = Math.max(1, Math.round(crop.height * page.height))
  const canvas = window.document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const context = canvas.getContext('2d', { alpha: false })
  if (context === null) return null
  context.drawImage(page, x, y, width, height, 0, 0, width, height)
  return canvas
}

/** Creates the PDF-backed renderer injected into the surface-free InkLayer. */
export function createPdfClipRenderer(courseId: string): RenderClip {
  const outputCache = new Map<string, Promise<string | null>>()
  return async (source) => {
    const key = JSON.stringify([source.relPath, source.page, source.crop])
    const cached = outputCache.get(key)
    if (cached !== undefined) {
      outputCache.delete(key)
      outputCache.set(key, cached)
      return cached
    }
    const pending = pageFor(courseId, source).then((page) => {
      if (page === null) return null
      try {
        return cropCanvas(page.canvas, source.crop)?.toDataURL('image/png') ?? null
      } catch {
        return null
      }
    }, () => null)
    outputCache.set(key, pending)
    while (outputCache.size > OUTPUT_CACHE_LIMIT) {
      const oldest = outputCache.keys().next().value as string | undefined
      if (oldest === undefined) break
      outputCache.delete(oldest)
    }
    const result = await pending
    if (result === null && outputCache.get(key) === pending) outputCache.delete(key)
    return result
  }
}
