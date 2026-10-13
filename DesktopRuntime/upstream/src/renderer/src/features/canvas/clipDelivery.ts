/**
 * Sending a PDF clip to a whiteboard that is not on screen.
 *
 * Dragging a clip only works when a whiteboard is already open next to the
 * PDF. Clicking has to work too, and by then the board may not be mounted —
 * so the clip is parked here and the board picks it up when it mounts, using
 * its own measured aspect. Mirrors `pdfPageNavigation`.
 */

import type { DrawingClipSource } from '../../../../shared/types/drawing'

export const CLIP_DELIVERY_EVENT = 'bandal:canvas-clip-delivery'

const pending = new Map<string, DrawingClipSource[]>()

export function requestClipDelivery(
  boardId: string,
  source: DrawingClipSource
): void {
  pending.set(boardId, [...(pending.get(boardId) ?? []), source])
  window.dispatchEvent(
    new CustomEvent(CLIP_DELIVERY_EVENT, { detail: { boardId } })
  )
}

/** Returns and clears everything queued for the board. */
export function takeClipDeliveries(boardId: string): DrawingClipSource[] {
  const queued = pending.get(boardId)
  if (queued === undefined) return []
  pending.delete(boardId)
  return queued
}
