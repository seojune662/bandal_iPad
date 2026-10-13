import { MATERIAL_MOVE_MIME } from './materialMoveDrag'

/**
 * Link drops onto the materials tree. Google Drive (and other Chrome-based
 * drag-outs) can carry `DownloadURL` / `text/html` alongside `Files`.
 */
const URL_TYPES = ['text/uri-list', 'DownloadURL', 'text/html', 'text/plain']

export function canAcceptUrlDrop(types: readonly string[]): boolean {
  const typeSet = new Set(types)
  if (typeSet.has(MATERIAL_MOVE_MIME)) return false
  return URL_TYPES.some((type) => typeSet.has(type))
}
