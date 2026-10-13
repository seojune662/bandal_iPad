/** Wheel deltas are pixels, lines or pages. Pinch gestures use pixel deltas. */
export function wheelZoomFactor(deltaY: number, deltaMode: number, viewportHeight: number): number {
  if (!Number.isFinite(deltaY)) return 1
  const pixels = deltaY * (deltaMode === 1 ? 16 : deltaMode === 2 ? viewportHeight : 1)
  return Math.exp(-Math.max(-600, Math.min(600, pixels)) * 0.002)
}
