/**
 * Chrome's own zoom stops, as webContents zoom levels. Shared so the settings
 * sanitizer (main) and the browser chrome (renderer) agree on what a valid
 * default zoom is.
 */
export const ZOOM_LEVELS = [
  -7.6, -6.08, -4.8, -3.8, -2.2, -1.58, -1.22, -0.58, 0, 0.53, 1.22, 2.22,
  3.07, 3.8, 5.03, 6.03, 7.6
] as const

export const DEFAULT_ZOOM_LEVEL = 0

export function isZoomLevel(value: unknown): value is number {
  return typeof value === 'number' && ZOOM_LEVELS.some((level) => level === value)
}

/** Percent shown in the chrome for a level (Chrome's 1.2^level curve). */
export function zoomPercent(level: number): number {
  return Math.round(Math.pow(1.2, level) * 100)
}
