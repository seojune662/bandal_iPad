import type { DrawingPoint } from './types/drawing'

export type InkVertex = [number, number]
export const INK_CIRCLE_SEGMENTS = 24
/** Version 2 uses one nonzero fill for the union of segment quads and round
 * caps. Do not alpha-blend each piece: overlapping highlighter stays uniform.
 * Positions and width use the owning surface's normalized display space. */
export function strokePolygonsV2(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean): InkVertex[][] {
  if (!Number.isFinite(width) || width <= 0 || !Number.isFinite(aspect) || aspect <= 0 ||
      points.some(p => ![p.x, p.y, p.p].every(Number.isFinite))) return []
  const polygons: InkVertex[][] = []
  const radius = (p: DrawingPoint): number => width * (highlighter ? 1 : 0.35 + 0.65 * Math.max(0, Math.min(1, p.p))) / 2
  for (let i = 0; i < points.length; i++) {
    const point = points[i]!, r = radius(point)
    const previous = points[i - 1]
    if (previous) {
      const dx = point.x - previous.x, dy = (point.y - previous.y) * aspect, length = Math.hypot(dx, dy)
      if (length > 1e-12) {
        const nx = -dy / length, ny = dx / length, a = radius(previous)
        polygons.push([[previous.x - nx * a, previous.y - ny * a / aspect],
          [point.x - nx * r, point.y - ny * r / aspect], [point.x + nx * r, point.y + ny * r / aspect],
          [previous.x + nx * a, previous.y + ny * a / aspect]])
      }
    }
    polygons.push(Array.from({ length: INK_CIRCLE_SEGMENTS }, (_, step): InkVertex => {
      const angle = step * 2 * Math.PI / INK_CIRCLE_SEGMENTS
      return [point.x + r * Math.cos(angle), point.y + r * Math.sin(angle) / aspect]
    }))
  }
  return polygons
}
export function strokePathV2(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean, scaleX = 1, scaleY = 1): string {
  return strokePolygonsV2(points, width, aspect, highlighter).map(polygon =>
    polygon.map(([x, y], i) => `${i === 0 ? 'M' : 'L'} ${x * scaleX} ${y * scaleY}`).join(' ') + ' Z').join(' ')
}
