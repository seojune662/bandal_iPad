import type { DisplayInfo, RawCapture } from './desktopSurface'

export const MAX_LONG_EDGE = 1568
export const JPEG_QUALITY = 72
export const FALLBACK_JPEG_QUALITY = 60
export const FALLBACK_LONG_EDGE = 1280
export const MAX_IMAGE_BYTES = 1.5 * 1024 * 1024

export function fitWithin(
  width: number,
  height: number,
  maxLongEdge: number
): { width: number; height: number } {
  const longEdge = Math.max(width, height)
  if (longEdge <= maxLongEdge) return { width, height }

  const scale = maxLongEdge / longEdge
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale))
  }
}

/**
 * Encodes once at the normal quality, then once at the lower quality if the
 * image is still too large. A second oversized result tells the surface to
 * ask the OS for a smaller capture; this module never resizes pixel data.
 */
export function encodeForVision(capture: RawCapture): {
  jpeg: Buffer
  quality: number
  needsSmaller: boolean
} {
  const normal = capture.toJPEG(JPEG_QUALITY)
  if (normal.byteLength <= MAX_IMAGE_BYTES) {
    return { jpeg: normal, quality: JPEG_QUALITY, needsSmaller: false }
  }

  const fallback = capture.toJPEG(FALLBACK_JPEG_QUALITY)
  return {
    jpeg: fallback,
    quality: FALLBACK_JPEG_QUALITY,
    needsSmaller: fallback.byteLength > MAX_IMAGE_BYTES
  }
}

/** Maps pixels in the captured image back to display-independent OS points. */
export function toScreenPoint(
  px: number,
  py: number,
  capture: {
    imageWidth: number
    imageHeight: number
    bounds: DisplayInfo['bounds']
  }
): { x: number; y: number } {
  return {
    x: capture.bounds.x + (px / capture.imageWidth) * capture.bounds.width,
    y: capture.bounds.y + (py / capture.imageHeight) * capture.bounds.height
  }
}
