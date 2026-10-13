import { fileToBase64 } from '../materials/clipboardPaste'

export const WHITEBOARD_IMAGE_MAX_SOURCE_BYTES = 25 * 1024 * 1024
export const WHITEBOARD_IMAGE_MAX_PIXELS = 32 * 1024 * 1024
export const WHITEBOARD_IMAGE_MAX_EDGE = 4_096
export const WHITEBOARD_IMAGE_MAX_FILES = 20
export const WHITEBOARD_IMAGE_WEBP_QUALITY = 0.88

const SUPPORTED_IMAGE_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'image/avif',
  'image/bmp'
])

export interface NormalizedWhiteboardImage {
  fileName: string
  mimeType: 'image/webp'
  base64: string
  dataUrl: string
  widthPx: number
  heightPx: number
  aspect: number
}

export function fittedImageSize(
  width: number,
  height: number,
  maxEdge = WHITEBOARD_IMAGE_MAX_EDGE
): { width: number; height: number } {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    throw new TypeError('이미지 크기를 읽을 수 없어요.')
  }
  if (width * height > WHITEBOARD_IMAGE_MAX_PIXELS) {
    throw new RangeError('이미지 해상도가 너무 커요. 32MP 이하 사진을 사용해 주세요.')
  }
  const ratio = Math.min(1, maxEdge / Math.max(width, height))
  return {
    width: Math.max(1, Math.round(width * ratio)),
    height: Math.max(1, Math.round(height * ratio))
  }
}

export function validateWhiteboardImageFile(file: File): void {
  if (!SUPPORTED_IMAGE_TYPES.has(file.type.toLowerCase())) {
    throw new TypeError('JPEG, PNG, WebP, GIF, AVIF, BMP 이미지만 추가할 수 있어요.')
  }
  if (file.size > WHITEBOARD_IMAGE_MAX_SOURCE_BYTES) {
    throw new RangeError('사진 하나는 25MB 이하여야 해요.')
  }
}

function canvasBlob(canvas: HTMLCanvasElement): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => blob === null
        ? reject(new Error('이미지를 최적화하지 못했어요.'))
        : resolve(blob),
      'image/webp',
      WHITEBOARD_IMAGE_WEBP_QUALITY
    )
  })
}

/** Decodes orientation, bounds memory, and produces one durable board asset. */
export async function normalizeWhiteboardImage(
  file: File
): Promise<NormalizedWhiteboardImage> {
  validateWhiteboardImageFile(file)
  let bitmap: ImageBitmap
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
  } catch {
    throw new TypeError('이 이미지를 해석할 수 없어요.')
  }
  try {
    const fitted = fittedImageSize(bitmap.width, bitmap.height)
    const canvas = document.createElement('canvas')
    canvas.width = fitted.width
    canvas.height = fitted.height
    const context = canvas.getContext('2d', { alpha: true })
    if (context === null) throw new Error('이미지 처리기를 열지 못했어요.')
    context.drawImage(bitmap, 0, 0, fitted.width, fitted.height)
    const blob = await canvasBlob(canvas)
    const optimized = new File([blob], `${crypto.randomUUID()}.webp`, {
      type: 'image/webp'
    })
    const base64 = await fileToBase64(optimized)
    return {
      fileName: optimized.name,
      mimeType: 'image/webp',
      base64,
      dataUrl: `data:image/webp;base64,${base64}`,
      widthPx: fitted.width,
      heightPx: fitted.height,
      aspect: fitted.height / fitted.width
    }
  } finally {
    bitmap.close()
  }
}

export function clipboardImageFiles(data: DataTransfer): File[] {
  return Array.from(data.files)
    .filter((file) => file.type.toLowerCase().startsWith('image/'))
    .slice(0, WHITEBOARD_IMAGE_MAX_FILES)
}
