/**
 * HTML inside the ink layer's `<svg viewBox="0 0 1 1">`.
 *
 * A `foreignObject` child inherits the SVG's user coordinate system, so every
 * CSS pixel inside it means "one board width". A 1px border becomes a border
 * as wide as the whole board; an 8px radius becomes a radius eight boards
 * across, which renders as a huge curved wedge rather than a rounded box.
 *
 * The foreignObject itself, rather than its HTML child, must own the scale.
 * Chromium does not keep a CSS-transformed HTML child's origin local to a
 * normalized foreignObject: as x/y changes, the child paint origin drifts away
 * from the SVG box while the foreignObject clip and hit area stay behind. The
 * result is invisible text, stale hit targets and selection handles that move
 * without their content.
 *
 * We therefore express the foreignObject in real surface pixels and transform
 * that SVG element back into the normalized viewBox. HTML then lays out at
 * ordinary CSS pixel scale with a local 100% box.
 */

import type { CSSProperties, SVGProps } from 'react'
import type { DrawingBox } from '../../../../shared/types/drawing'

function isFinitePositive(value: number): boolean {
  return Number.isFinite(value) && value > 0
}

/**
 * Pixel-space geometry for a foreignObject plus the local style for its HTML
 * child. Returns `null` before the surface has been measured — rendering then
 * would divide by zero and produce the wedge described above.
 */
export function foreignObjectLayout(
  box: DrawingBox,
  baseWidthPx: number,
  aspect: number
): {
  objectProps: Pick<
    SVGProps<SVGForeignObjectElement>,
    'x' | 'y' | 'width' | 'height' | 'transform'
  >
  contentStyle: CSSProperties
} | null {
  if (!isFinitePositive(baseWidthPx) || !isFinitePositive(aspect)) return null
  const baseHeightPx = baseWidthPx * aspect
  if (!isFinitePositive(baseHeightPx)) return null

  return {
    objectProps: {
      x: box.x * baseWidthPx,
      y: box.y * baseHeightPx,
      width: box.width * baseWidthPx,
      height: box.height * baseHeightPx,
      transform: `scale(${1 / baseWidthPx} ${1 / baseHeightPx})`
    },
    contentStyle: {
      width: '100%',
      height: '100%'
    }
  }
}
