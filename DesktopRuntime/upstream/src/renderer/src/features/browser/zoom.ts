/**
 * Page zoom for a browser tab.
 *
 * Chromium's zoom "level" is logarithmic: factor = 1.2 ** level. Level 0 is
 * 100%, and the steps below are the ones Chrome itself uses, so ⌘+ lands on
 * familiar percentages instead of arbitrary ones.
 */

import {
  DEFAULT_ZOOM_LEVEL,
  ZOOM_LEVELS,
  zoomPercent
} from '../../../../shared/browserZoom'

export { DEFAULT_ZOOM_LEVEL, ZOOM_LEVELS, zoomPercent }

function stepTo(level: number, direction: 1 | -1): number {
  const stops = direction === 1 ? ZOOM_LEVELS : [...ZOOM_LEVELS].reverse()
  const next = stops.find((stop) =>
    direction === 1 ? stop > level + 1e-6 : stop < level - 1e-6
  )
  // Already at the end of the range: stay put rather than drift past it.
  return next ?? level
}

export function zoomIn(level: number): number {
  return stepTo(level, 1)
}

export function zoomOut(level: number): number {
  return stepTo(level, -1)
}

export function isDefaultZoom(
  level: number,
  defaultLevel: number = DEFAULT_ZOOM_LEVEL
): boolean {
  return Math.abs(level - defaultLevel) < 1e-6
}
