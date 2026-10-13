import type { DrawingImageSource } from '../../../../shared/types/drawing'

export const BANDAL_IMAGE_MIME = 'application/x-bandal-material-image'

interface DragDataWriter {
  effectAllowed: string
  setData: (format: string, data: string) => void
}

interface DragDataReader {
  getData: (format: string) => string
}

export function isDrawingImageSource(value: unknown): value is DrawingImageSource {
  if (typeof value !== 'object' || value === null) return false
  const source = value as Record<string, unknown>
  const relPath = source['relPath']
  return (
    typeof relPath === 'string' &&
    relPath.length > 0 &&
    !relPath.startsWith('/') &&
    !relPath.includes('\\') &&
    !relPath.split('/').includes('..') &&
    typeof source['label'] === 'string' &&
    source['label'].length > 0
  )
}

export function writeBandalImageDragData(
  dataTransfer: DragDataWriter,
  source: DrawingImageSource
): void {
  dataTransfer.effectAllowed = 'copy'
  dataTransfer.setData(BANDAL_IMAGE_MIME, JSON.stringify(source))
}

export function readBandalImageDragData(
  dataTransfer: DragDataReader
): DrawingImageSource | null {
  const raw = dataTransfer.getData(BANDAL_IMAGE_MIME)
  if (raw.length === 0) return null
  try {
    const parsed: unknown = JSON.parse(raw)
    return isDrawingImageSource(parsed)
      ? { relPath: parsed.relPath, label: parsed.label }
      : null
  } catch {
    return null
  }
}
