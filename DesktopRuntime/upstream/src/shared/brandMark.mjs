import geometry from './moonGeometry.json' with { type: 'json' }

export const MOON_SHAPES = geometry.shapes.map(shape => ({
  name: shape.name, pivot: shape.pivot,
  path: `M ${shape.points.map(point => point.join(' ')).join(' L ')} Z`
}))
export const MOON_SCALE = geometry.motion.scale
export const MOON_VIEWBOX = '0 0 452 448'
export const MOON_LOOP_MS = 4000
export const MOON_INTRO_MS = 2000
export function moonPose(progress) {
  const t = Math.max(0, Math.min(1, progress)) * (geometry.motion.poses.length - 1)
  const index = Math.floor(t)
  const a = geometry.motion.poses[index], b = geometry.motion.poses[Math.min(index + 1, geometry.motion.poses.length - 1)]
  return [a[0] + (b[0] - a[0]) * (t - index), a[1] + (b[1] - a[1]) * (t - index)]
}
export function moonTransform(index, angle = 0) {
  const [x, y] = MOON_SHAPES[index].pivot
  return `translate(${x} ${y}) rotate(${angle}) scale(${MOON_SCALE}) translate(${-x} ${-y})`
}
export function moonSvgPaths(fill = 'currentColor') {
  return MOON_SHAPES.map((shape, index) => `<path d="${shape.path}" transform="${moonTransform(index)}" fill="${fill}"/>`).join('')
}

/**
 * Geometry shared by the build-time icon generator and the React mark.
 *
 * This JavaScript module is the runtime source of truth because Node can load
 * it directly from `scripts/generate-icon.mjs`. `brandMark.ts` only provides a
 * typed application-facing re-export.
 */

export const ICON_MOON_CX = 512
export const ICON_MOON_CY = 498

export const MARK_CX = 12
export const MARK_CY = 12
export const MARK_RADIUS = 9

export const MOON_TILT = -14
export const TERMINATOR_BULGE = 0.15

/**
 * The lit hemisphere, closed by a curved terminator rather than a diameter.
 *
 * Rotation remains an SVG group transform so the circle, rim, craters, and
 * path all share the exact same axis. `tilt` is accepted here as part of the
 * complete geometry contract and validated with the path coordinates.
 */
export function litHalfPath(cx, cy, radius, tilt, bulge) {
  if (![cx, cy, radius, tilt, bulge].every(Number.isFinite)) {
    throw new TypeError('brand mark geometry must contain only finite numbers')
  }
  if (radius <= 0 || bulge <= 0) {
    throw new RangeError('brand mark radius and bulge must be positive')
  }

  const top = `${cx} ${cy - radius}`
  const bottom = `${cx} ${cy + radius}`
  const terminatorRadius = (radius * bulge).toFixed(1)
  return `M ${top} A ${radius} ${radius} 0 0 1 ${bottom} A ${terminatorRadius} ${radius} 0 0 1 ${top} Z`
}
