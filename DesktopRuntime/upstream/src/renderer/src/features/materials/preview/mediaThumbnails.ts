import type { DrawingBox } from '../../../../../shared/types/drawing'
import { invoke } from '../../../lib/ipc'
import { mediaUrlFor } from '../mediaUrl'
import { runThumbnailTask } from './thumbnailQueue'

export interface MediaThumbnail {
  dataUrl: string
  pageCount?: number
  durationSeconds?: number
}

interface ImageThumbnailSource {
  sourceDataUrl: string
  width: number
  height: number
}

const THUMBNAIL_LIMIT = 24
const THUMBNAIL_EDGE = 360
const thumbnails = new Map<string, MediaThumbnail>()

function cached(key: string): MediaThumbnail | undefined {
  const value = thumbnails.get(key)
  if (value !== undefined) {
    thumbnails.delete(key)
    thumbnails.set(key, value)
  }
  return value
}

function remember(key: string, value: MediaThumbnail): MediaThumbnail {
  thumbnails.delete(key)
  thumbnails.set(key, value)
  while (thumbnails.size > THUMBNAIL_LIMIT) {
    const oldest = thumbnails.keys().next().value
    if (oldest !== undefined) thumbnails.delete(oldest)
  }
  return value
}

/** All referenced metadata reads also share the two-slot lane with decoding. */
export function loadReferencedThumbnail(
  courseId: string,
  relPath: string,
  signal: AbortSignal,
  pageNumber = 1,
  crop?: DrawingBox
): Promise<MediaThumbnail> {
  return runThumbnailTask(signal, async () => {
    const metadata = await invoke('materials:hoverPreview', { courseId, relPath })
    signal.throwIfAborted()
    const version = `${metadata.mtime}:${metadata.size}`
    if (metadata.content.kind === 'pdf') {
      const key = JSON.stringify(['pdf', courseId, relPath, version, pageNumber, crop])
      return renderPdfThumbnail(key, courseId, relPath, signal, pageNumber, crop)
    }
    if (metadata.content.kind === 'image') {
      const key = JSON.stringify(['image', courseId, relPath, version])
      return renderImageThumbnail(key, metadata.content, signal)
    }
    throw new Error('Reference preview unavailable')
  })
}

export function loadImageThumbnail(
  courseId: string,
  relPath: string,
  version: string,
  source: ImageThumbnailSource,
  signal: AbortSignal
): Promise<MediaThumbnail> {
  const key = JSON.stringify(['image', courseId, relPath, version])
  return runThumbnailTask(signal, () => renderImageThumbnail(key, source, signal))
}

function decodedLocalImage(dataUrl: string, signal: AbortSignal): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image()
    const removeListeners = (): void => {
      image.onload = null
      image.onerror = null
      signal.removeEventListener('abort', abort)
    }
    const abort = (): void => { removeListeners(); image.removeAttribute('src'); reject(signal.reason) }
    image.onload = () => { removeListeners(); resolve(image) }
    image.onerror = () => { removeListeners(); image.removeAttribute('src'); reject(new Error('Image decoding failed')) }
    signal.addEventListener('abort', abort, { once: true })
    image.src = dataUrl
  })
}

async function renderImageThumbnail(key: string, source: ImageThumbnailSource, signal: AbortSignal): Promise<MediaThumbnail> {
  signal.throwIfAborted()
  const previous = cached(key)
  if (previous !== undefined) return previous
  const { width, height } = source
  if (!Number.isFinite(width) || !Number.isFinite(height) || width < 1 || height < 1 || Math.max(width, height) > 8192 || width * height > 16 * 1024 * 1024) throw new Error('Image dimensions exceed preview limits')
  const match = /^data:(image\/[\w.+-]+);base64,([A-Za-z0-9+/=]+)$/.exec(source.sourceDataUrl)
  if (match === null || source.sourceDataUrl.length > 6 * 1024 * 1024) throw new Error('Invalid image preview source')
  const scale = Math.min(1, THUMBNAIL_EDGE / Math.max(width, height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(width * scale))
  canvas.height = Math.max(1, Math.round(height * scale))
  const context = canvas.getContext('2d')
  if (context === null) throw new Error('Canvas unavailable')
  if (typeof createImageBitmap === 'function') {
    let bitmap: ImageBitmap | null = null
    try {
      const binary = atob(match[2]!)
      const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0))
      bitmap = await createImageBitmap(new Blob([bytes], { type: match[1]! }), { resizeWidth: canvas.width, resizeHeight: canvas.height, resizeQuality: 'high' })
      signal.throwIfAborted()
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
    } catch (error) {
      signal.throwIfAborted()
      // Chromium may reject SVG in createImageBitmap; its guarded immutable
      // data source can still be decoded by an inert local image element.
      if (match[1] !== 'image/svg+xml') throw error
      const image = await decodedLocalImage(source.sourceDataUrl, signal)
      try { signal.throwIfAborted(); context.drawImage(image, 0, 0, canvas.width, canvas.height) }
      finally { image.removeAttribute('src') }
    } finally { bitmap?.close() }
  } else {
    const image = await decodedLocalImage(source.sourceDataUrl, signal)
    try { signal.throwIfAborted(); context.drawImage(image, 0, 0, canvas.width, canvas.height) }
    finally { image.removeAttribute('src') }
  }
  signal.throwIfAborted()
  return remember(key, { dataUrl: canvas.toDataURL('image/png') })
}

export function thumbnailFrameTime(durationSeconds: number): number {
  return Number.isFinite(durationSeconds) && durationSeconds > 0
    ? Math.min(1, durationSeconds * 0.1)
    : 0
}

/** A small first-page render; range loading never starts background prefetch. */
export async function loadPdfThumbnail(
  courseId: string,
  relPath: string,
  version: string,
  signal: AbortSignal,
  pageNumber = 1,
  crop?: DrawingBox
): Promise<MediaThumbnail> {
  const key = JSON.stringify(['pdf', courseId, relPath, version, pageNumber, crop])
  return runThumbnailTask(signal, () => renderPdfThumbnail(key, courseId, relPath, signal, pageNumber, crop))
}

async function renderPdfThumbnail(
  key: string,
  courseId: string,
  relPath: string,
  signal: AbortSignal,
  pageNumber: number,
  crop?: DrawingBox
): Promise<MediaThumbnail> {
  // Recheck after queueing: another independent request may have just cached it.
  const previous = cached(key)
  signal.throwIfAborted()
  if (previous !== undefined) return previous
  const [{ pdfjs }, { configurePdfWorker }] = await Promise.all([
    import('react-pdf'),
    import('../../pdf/pdfWorker')
  ])
  signal.throwIfAborted()
  configurePdfWorker()
  const loading = pdfjs.getDocument({
    url: mediaUrlFor(courseId, relPath),
    disableStream: true,
    disableAutoFetch: true,
    rangeChunkSize: 65536,
    isEvalSupported: false
  })
  const abort = (): void => { void loading.destroy().catch(() => undefined) }
  signal.addEventListener('abort', abort, { once: true })
  try {
    const pdf = await loading.promise
    signal.throwIfAborted()
    const page = await pdf.getPage(pageNumber)
    const natural = page.getViewport({ scale: 1 })
    const viewport = page.getViewport({ scale: THUMBNAIL_EDGE / Math.max(natural.width, natural.height) })
    const canvas = document.createElement('canvas')
    canvas.width = Math.max(1, Math.round(viewport.width))
    canvas.height = Math.max(1, Math.round(viewport.height))
    const context = canvas.getContext('2d', { alpha: false })
    if (context === null) throw new Error('Canvas unavailable')
    const render = page.render({ canvas, canvasContext: context, viewport })
    const cancelRender = (): void => render.cancel()
    signal.addEventListener('abort', cancelRender, { once: true })
    try { await render.promise } finally { signal.removeEventListener('abort', cancelRender) }
    signal.throwIfAborted()
    let output = canvas
    if (crop !== undefined) {
      output = document.createElement('canvas')
      const x = Math.max(0, Math.min(1, crop.x)) * canvas.width
      const y = Math.max(0, Math.min(1, crop.y)) * canvas.height
      output.width = Math.max(1, Math.round(Math.min(1 - crop.x, crop.width) * canvas.width))
      output.height = Math.max(1, Math.round(Math.min(1 - crop.y, crop.height) * canvas.height))
      output.getContext('2d')?.drawImage(canvas, x, y, output.width, output.height, 0, 0, output.width, output.height)
    }
    return remember(key, { dataUrl: output.toDataURL('image/png'), pageCount: pdf.numPages })
  } finally {
    signal.removeEventListener('abort', abort)
    await loading.destroy().catch(() => undefined)
  }
}

/** Seeks a muted detached video without ever playing it, then releases its decoder. */
export function loadVideoThumbnail(
  courseId: string,
  relPath: string,
  version: string,
  signal: AbortSignal
): Promise<MediaThumbnail> {
  const key = JSON.stringify(['video', courseId, relPath, version])
  return runThumbnailTask(signal, () => renderVideoThumbnail(key, courseId, relPath, signal))
}

function renderVideoThumbnail(key: string, courseId: string, relPath: string, signal: AbortSignal): Promise<MediaThumbnail> {
  const previous = cached(key)
  if (signal.aborted) return Promise.reject(signal.reason)
  if (previous !== undefined) return Promise.resolve(previous)
  return new Promise((resolve, reject) => {
    const video = document.createElement('video')
    video.muted = true
    video.preload = 'metadata'
    video.playsInline = true
    let settled = false
    const cleanup = (): void => {
      clearTimeout(timeout)
      signal.removeEventListener('abort', abort)
      video.onloadedmetadata = null
      video.onloadeddata = null
      video.onseeked = null
      video.onerror = null
      video.pause()
      video.removeAttribute('src')
      video.load()
    }
    const finish = (value?: MediaThumbnail, error?: unknown): void => {
      if (settled) return
      settled = true
      cleanup()
      if (value !== undefined) resolve(remember(key, value))
      else reject(error ?? new Error('Video preview unavailable'))
    }
    const abort = (): void => finish(undefined, signal.reason)
    const timeout = setTimeout(() => finish(), 8000)
    const capture = (): void => {
      if (video.readyState < 2 || video.videoWidth === 0) return
      try {
        const scale = Math.min(1, THUMBNAIL_EDGE / Math.max(video.videoWidth, video.videoHeight))
        const canvas = document.createElement('canvas')
        canvas.width = Math.max(1, Math.round(video.videoWidth * scale))
        canvas.height = Math.max(1, Math.round(video.videoHeight * scale))
        const context = canvas.getContext('2d')
        if (context === null) return finish()
        context.drawImage(video, 0, 0, canvas.width, canvas.height)
        finish({ dataUrl: canvas.toDataURL('image/jpeg', 0.8), durationSeconds: Number.isFinite(video.duration) ? video.duration : 0 })
      } catch (error) { finish(undefined, error) }
    }
    video.onloadedmetadata = () => {
      const time = thumbnailFrameTime(video.duration)
      if (time === 0) capture()
      else video.currentTime = time
    }
    video.onloadeddata = () => { if (thumbnailFrameTime(video.duration) === 0) capture() }
    video.onseeked = capture
    video.onerror = () => finish()
    signal.addEventListener('abort', abort, { once: true })
    video.src = mediaUrlFor(courseId, relPath)
    video.load()
  })
}
