import type { DrawingPoint } from './types/drawing'
import type { InkVertex } from './inkV2'

export const INK_V3_CIRCLE_SEGMENTS = 32

/** Causal render-only pressure filtering. Saved coordinates/pressure/time are
 * never rewritten; appending predictions cannot alter a measured prefix. */
export function filteredPressuresV3(points: readonly DrawingPoint[]): number[] {
  if (points.length === 0) return []
  let filtered = Math.max(0, Math.min(1, points[0]!.p))
  const result = [filtered]
  for (let i = 1; i < points.length; i++) {
    const point = points[i]!, previous = points[i - 1]!
    const delta = Number.isFinite(point.t) && Number.isFinite(previous.t)
      ? Math.max(0, Math.min(32, point.t! - previous.t!)) : 4
    const alpha = -Math.expm1(-delta / 24)
    filtered += alpha * (Math.max(0, Math.min(1, point.p)) - filtered)
    result.push(filtered)
  }
  return result
}

/** One nonzero union fill, like v2. The common external tangents meet both
 * circles without the shoulders caused by perpendicular variable-width quads.
 * Coordinates stay in the exact original display-normalized plane. */
export function strokePolygonsV3(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean): InkVertex[][] {
  if (!Number.isFinite(width) || width <= 0 || !Number.isFinite(aspect) || aspect <= 0 ||
      points.some(p => ![p.x, p.y, p.p].every(Number.isFinite))) return []
  const pressures = filteredPressuresV3(points)
  const radii = pressures.map(pressure => width * (highlighter ? 1 : 0.42 + 0.20 * pressure) / 2)
  const polygons: InkVertex[][] = []
  for (let i = 0; i < points.length; i++) {
    const point = points[i]!, radius = radii[i]!
    const previous = points[i - 1]
    if (previous) {
      const before = radii[i - 1]!, dx = point.x - previous.x, dy = (point.y - previous.y) * aspect
      const distance = Math.hypot(dx, dy), difference = before - radius
      // A contained disk contributes no connecting area. Keep its original
      // sample and circle, so a pressure-only dot is still the disk union.
      if (distance > Math.abs(difference) && distance > 1e-12) {
        const ux = dx / distance, uy = dy / distance, along = difference / distance
        const across = Math.sqrt(Math.max(0, 1 - along * along))
        const lowX = ux * along + uy * across, lowY = uy * along - ux * across
        const highX = ux * along - uy * across, highY = uy * along + ux * across
        polygons.push([[previous.x + lowX * before, previous.y + lowY * before / aspect],
          [point.x + lowX * radius, point.y + lowY * radius / aspect],
          [point.x + highX * radius, point.y + highY * radius / aspect],
          [previous.x + highX * before, previous.y + highY * before / aspect]])
      }
    }
    polygons.push(Array.from({ length: INK_V3_CIRCLE_SEGMENTS }, (_, step): InkVertex => {
      const angle = step * 2 * Math.PI / INK_V3_CIRCLE_SEGMENTS
      return [point.x + radius * Math.cos(angle), point.y + radius * Math.sin(angle) / aspect]
    }))
  }
  return polygons
}

export function strokePathV3(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean, scaleX = 1, scaleY = 1): string {
  return strokePolygonsV3(points, width, aspect, highlighter).map(polygon =>
    polygon.map(([x, y], i) => `${i === 0 ? 'M' : 'L'} ${x * scaleX} ${y * scaleY}`).join(' ') + ' Z').join(' ')
}
