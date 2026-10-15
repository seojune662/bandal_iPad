import type { DrawingPoint } from './types/drawing'
import type { InkVertex } from './inkV2'
import { filteredPressuresV3, INK_V3_CIRCLE_SEGMENTS } from './inkV3'

/** Render-only samples. Pressure is already filtered; never persist these. */
export interface InkRenderSampleV4 { x: number; y: number; p: number }
export interface InkCubicV4 { start: InkVertex; control1: InkVertex; control2: InkVertex; end: InkVertex }
export interface InkSegmentV4 { index: number; samples: InkRenderSampleV4[] }
export const INK_V4_MAX_SUBDIVISION_DEPTH = 5
const EPSILON = 1e-12
const add = (a: InkVertex, b: InkVertex): InkVertex => [a[0] + b[0], a[1] + b[1]]
const sub = (a: InkVertex, b: InkVertex): InkVertex => [a[0] - b[0], a[1] - b[1]]
const scale = (a: InkVertex, factor: number): InkVertex => [a[0] * factor, a[1] * factor]
const length = (a: InkVertex): number => Math.hypot(a[0], a[1])
const dot = (a: InkVertex, b: InkVertex): number => a[0] * b[0] + a[1] * b[1]
const midpoint = (a: InkVertex, b: InkVertex): InkVertex => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]
const metric = (point: DrawingPoint, aspect: number): InkVertex => [point.x, point.y * aspect]
const valid = (points: readonly DrawingPoint[], width: number, aspect: number): boolean =>
  Number.isFinite(width) && width > 0 && Number.isFinite(aspect) && aspect > 0 &&
  points.every(point => [point.x, point.y, point.y * aspect, point.p].every(Number.isFinite))

function smoothJoint(incoming: InkVertex, outgoing: InkVertex): boolean {
  const before = length(incoming), after = length(outgoing)
  return before > EPSILON && after > EPSILON && dot(scale(incoming, 1 / before), scale(outgoing, 1 / after)) > 0.5 + EPSILON
}
function boundedHandle(handle: InkVertex, chord: InkVertex): InkVertex {
  const distance = length(chord), size = length(handle)
  if (!Number.isFinite(distance) || !Number.isFinite(size) || distance <= EPSILON || size <= EPSILON) return [0, 0]
  const unit = scale(chord, 1 / distance)
  if (dot(handle, unit) <= 0) return [0, 0]
  const normal = Math.abs(handle[0] * unit[1] - handle[1] * unit[0])
  const factor = Math.min(1, 0.5 * distance / size, normal > 0 ? 0.25 * distance / normal : 1)
  return scale(handle, factor)
}

/** Centripetal Hermite controls in the physical metric (x, y * aspect).
 * Reflected endpoints make the first/last segment available immediately.
 * Sharp turns retain their measured corner instead of rounding past it. */
export function cubicControlsV4(points: readonly DrawingPoint[], index: number, aspect: number): InkCubicV4 | null {
  const first = points[index], last = points[index + 1]
  if (!Number.isInteger(index) || index < 0 || !first || !last || !Number.isFinite(aspect) || aspect <= 0) return null
  const p1 = metric(first, aspect), p2 = metric(last, aspect)
  const p0 = index > 0 ? metric(points[index - 1]!, aspect) : sub(scale(p1, 2), p2)
  const p3 = index + 2 < points.length ? metric(points[index + 2]!, aspect) : sub(scale(p2, 2), p1)
  if (![...p0, ...p1, ...p2, ...p3].every(Number.isFinite)) return null
  const before = sub(p1, p0), chord = sub(p2, p1), after = sub(p3, p2)
  const d01 = Math.sqrt(length(before)), d12 = Math.sqrt(length(chord)), d23 = Math.sqrt(length(after))
  let h1: InkVertex = [0, 0], h2: InkVertex = [0, 0]
  if (length(chord) > EPSILON) {
    if (smoothJoint(before, chord)) {
      const h = scale(add(sub(scale(before, 1 / d01), scale(sub(p2, p0), 1 / (d01 + d12))), scale(chord, 1 / d12)), d12 / 3)
      h1 = boundedHandle(h, chord)
    }
    if (smoothJoint(chord, after)) {
      const h = scale(add(sub(scale(chord, 1 / d12), scale(sub(p3, p1), 1 / (d12 + d23))), scale(after, 1 / d23)), d12 / 3)
      h2 = boundedHandle(h, chord)
    }
  }
  return { start: p1, control1: add(p1, h1), control2: sub(p2, h2), end: p2 }
}

function flat(cubic: InkCubicV4, tolerance: number): boolean {
  const chord = sub(cubic.end, cubic.start), distance = length(chord)
  const unit = distance > EPSILON ? scale(chord, 1 / distance) : [0, 0]
  const deviation = (point: InkVertex): number => {
    const offset = sub(point, cubic.start)
    return distance <= EPSILON ? length(offset) : Math.abs(offset[0] * unit[1]! - offset[1] * unit[0]!)
  }
  return Math.max(deviation(cubic.control1), deviation(cubic.control2)) <= tolerance
}

/** Includes both raw endpoints. The caller supplies the one causal pressure
 * pass, allowing a live cache to recompute only its changing trailing segments. */
export function segmentSamplesV4(points: readonly DrawingPoint[], index: number, width: number, aspect: number,
  pressures: readonly number[]): InkRenderSampleV4[] {
  const cubic = cubicControlsV4(points, index, aspect)
  const first = points[index], last = points[index + 1], p0 = pressures[index], p1 = pressures[index + 1]
  if (!cubic || !first || !last || !Number.isFinite(width) || width <= 0 || p0 === undefined || p1 === undefined ||
      !Number.isFinite(p0) || !Number.isFinite(p1)) return []
  const samples: InkRenderSampleV4[] = [{ x: first.x, y: first.y, p: p0 }]
  const tolerance = Math.min(1e-4, Math.max(1e-5, width * 0.08))
  const visit = (curve: InkCubicV4, from: number, to: number, depth: number): void => {
    if (depth === INK_V4_MAX_SUBDIVISION_DEPTH || flat(curve, tolerance)) {
      // Avoid roundoff in the canonical measured endpoint and its pressure.
      samples.push(to === 1 ? { x: last.x, y: last.y, p: p1 } :
        { x: curve.end[0], y: curve.end[1] / aspect, p: p0 + (p1 - p0) * to })
      return
    }
    const a = midpoint(curve.start, curve.control1), b = midpoint(curve.control1, curve.control2), c = midpoint(curve.control2, curve.end)
    const d = midpoint(a, b), e = midpoint(b, c), center = midpoint(d, e), middle = (from + to) / 2
    visit({ start: curve.start, control1: a, control2: d, end: center }, from, middle, depth + 1)
    visit({ start: center, control1: e, control2: c, end: curve.end }, middle, to, depth + 1)
  }
  visit(cubic, 0, 1, 0)
  return samples
}

export function* strokeSegmentsV4(points: readonly DrawingPoint[], width: number, aspect: number): Generator<InkSegmentV4> {
  if (!valid(points, width, aspect)) return
  const pressures = filteredPressuresV3(points)
  for (let index = 0; index + 1 < points.length; index++) {
    yield { index, samples: segmentSamplesV4(points, index, width, aspect, pressures) }
  }
}

export function strokeCenterlineV4(points: readonly DrawingPoint[], width: number, aspect: number): InkRenderSampleV4[] {
  if (!valid(points, width, aspect) || !points.length) return []
  const first = points[0]!, result: InkRenderSampleV4[] = [{ x: first.x, y: first.y, p: Math.max(0, Math.min(1, first.p)) }]
  for (const segment of strokeSegmentsV4(points, width, aspect)) result.push(...segment.samples.slice(1))
  return result
}

/** The v3 external-tangent/disk union, consuming already-filtered pressure.
 * Convex pieces support the native triangle-fan renderer. One compound fill
 * must cover all pieces, including predictions, to avoid antialias seams. */
export function* segmentPolygonsV4(samples: readonly InkRenderSampleV4[], width: number, aspect: number,
  highlighter: boolean, includeFirst = true): Generator<InkVertex[]> {
  if (!valid(samples, width, aspect)) return
  const radius = (sample: InkRenderSampleV4): number => width * (highlighter ? 1 : 0.42 + 0.20 * sample.p) / 2
  for (let i = 0; i < samples.length; i++) {
    const point = samples[i]!, r = radius(point), previous = samples[i - 1]
    if (previous) {
      const before = radius(previous), dx = point.x - previous.x, dy = (point.y - previous.y) * aspect
      const distance = Math.hypot(dx, dy), difference = before - r
      if (Number.isFinite(distance) && distance > Math.abs(difference) && distance > EPSILON) {
        const ux = dx / distance, uy = dy / distance, along = difference / distance
        const across = Math.sqrt(Math.max(0, 1 - along * along))
        const lowX = ux * along + uy * across, lowY = uy * along - ux * across
        const highX = ux * along - uy * across, highY = uy * along + ux * across
        yield [[previous.x + lowX * before, previous.y + lowY * before / aspect],
          [point.x + lowX * r, point.y + lowY * r / aspect],
          [point.x + highX * r, point.y + highY * r / aspect],
          [previous.x + highX * before, previous.y + highY * before / aspect]]
      }
    }
    if (i > 0 || includeFirst) yield Array.from({ length: INK_V3_CIRCLE_SEGMENTS }, (_, step): InkVertex => {
      const angle = step * 2 * Math.PI / INK_V3_CIRCLE_SEGMENTS
      return [point.x + r * Math.cos(angle), point.y + r * Math.sin(angle) / aspect]
    })
  }
}

export function* strokePolygonIteratorV4(points: readonly DrawingPoint[], width: number, aspect: number,
  highlighter: boolean): Generator<InkVertex[]> {
  if (!valid(points, width, aspect) || !points.length) return
  const first = points[0]!
  yield* segmentPolygonsV4([{ x: first.x, y: first.y, p: Math.max(0, Math.min(1, first.p)) }], width, aspect, highlighter)
  for (const segment of strokeSegmentsV4(points, width, aspect)) yield* segmentPolygonsV4(segment.samples, width, aspect, highlighter, false)
}

export function strokePolygonsV4(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean): InkVertex[][] {
  return [...strokePolygonIteratorV4(points, width, aspect, highlighter)]
}

export function strokePathV4(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean, scaleX = 1, scaleY = 1): string {
  const paths: string[] = []
  for (const polygon of strokePolygonIteratorV4(points, width, aspect, highlighter)) {
    paths.push(polygon.map(([x, y], i) => `${i === 0 ? 'M' : 'L'} ${x * scaleX} ${y * scaleY}`).join(' ') + ' Z')
  }
  return paths.join(' ')
}

/** Predictions cannot be p3 of a measured curve. Their straight, replaceable
 * tail starts at the exact last measured endpoint with constant filtered force. */
export function predictionPolygonsV4(measured: readonly DrawingPoint[], predictions: readonly DrawingPoint[],
  width: number, aspect: number, highlighter: boolean): InkVertex[][] {
  if (!valid(measured, width, aspect) || !measured.length) return []
  const last = measured[measured.length - 1]!, pressure = filteredPressuresV3(measured).at(-1)!
  const samples: InkRenderSampleV4[] = [{ x: last.x, y: last.y, p: pressure }]
  for (const point of predictions) {
    if (samples.length === 9) break
    if ([point.x, point.y, point.y * aspect].every(Number.isFinite)) samples.push({ x: point.x, y: point.y, p: pressure })
  }
  return [...segmentPolygonsV4(samples, width, aspect, highlighter, false)]
}
