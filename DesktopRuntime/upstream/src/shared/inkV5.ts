import type { DrawingPoint } from './types/drawing'
import type { InkVertex } from './inkV2'
import { INK_V3_CIRCLE_SEGMENTS } from './inkV3'
import { segmentSamplesV4 } from './inkV4'

/** Display-only diameter factors. Never substitute these for measured pressure. */
export interface InkRenderSampleV5 { x: number; y: number; factor: number }
export interface InkSegmentV5 { index: number; samples: InkRenderSampleV5[] }
export const INK_V5_TAIL_SEGMENTS = 16
const clamp = (value: number): number => Math.max(0, Math.min(1, value))
const smoothstep = (value: number): number => { const t = clamp(value); return t * t * (3 - 2 * t) }
const valid = (points: readonly DrawingPoint[], width: number, aspect: number): boolean =>
  Number.isFinite(width) && width > 0 && Number.isFinite(aspect) && aspect > 0 &&
  points.every(point => [point.x, point.y, point.y * aspect, point.p].every(Number.isFinite))
const delta = (before: DrawingPoint, after: DrawingPoint): number =>
  before.t !== undefined && after.t !== undefined && Number.isFinite(before.t) && Number.isFinite(after.t)
    ? after.t - before.t : NaN

/** Four original samples, with bounded causal age; duplicate/invalid time uses 4ms. */
export function filteredPressureV5(points: readonly DrawingPoint[], index: number): number {
  let age = 0, sum = 0, weights = 0
  for (let cursor = index; cursor >= 0 && cursor > index - 4; cursor--) {
    const point = points[cursor]!
    if (cursor < index) {
      const dt = delta(point, points[cursor + 1]!)
      age += Number.isFinite(dt) && dt > 0 ? Math.min(32, dt) : 4
    }
    if (age > 24) break
    const weight = Math.exp(-age / 8)
    sum += clamp(point.p) * weight
    weights += weight
  }
  return weights > 0 ? sum / weights : 0
}

export function cumulativeTravelV5(points: readonly DrawingPoint[], aspect: number): number[] {
  if (!Number.isFinite(aspect) || aspect <= 0) return []
  const result: number[] = []
  for (let index = 0; index < points.length; index++) {
    const point = points[index]!, previous = points[index - 1]
    const next = previous ? result[index - 1]! + Math.hypot(point.x - previous.x, (point.y - previous.y) * aspect) : 0
    if (!Number.isFinite(next)) return []
    result.push(next)
  }
  return result
}

/** Pressure/speed response only; taper is evaluated at local display travel. */
export function baseDiameterFactorV5(points: readonly DrawingPoint[], pressureIndex: number,
  arrivalIndex: number, aspect: number): number {
  const point = points[arrivalIndex]!, previous = points[arrivalIndex - 1]
  const dt = previous ? delta(previous, point) : NaN
  const speed = previous && Number.isFinite(dt) && dt > 0 && dt <= 64
    ? Math.min(3, Math.max(0, Math.hypot(point.x - previous.x, (point.y - previous.y) * aspect) * 1000 / dt)) : 0
  return (0.24 + 0.68 * Math.pow(filteredPressureV5(points, pressureIndex), 0.8)) * (1 - 0.12 * clamp(speed / 0.8))
}
export function startGainV5(travel: number, width: number): number {
  return 0.75 + 0.25 * smoothstep(travel / (1.2 * width))
}
export function endLengthV5(cumulative: readonly number[], width: number): number {
  const last = cumulative.length - 1, start = Math.max(0, last - INK_V5_TAIL_SEGMENTS)
  return last < 0 ? 0 : Math.min(2.2 * width, 0.28 * cumulative[last]!, cumulative[last]! - cumulative[start]!)
}
export function endGainV5(travel: number, cumulative: readonly number[], width: number): number {
  const length = endLengthV5(cumulative, width)
  if (!(length > 0)) return 1
  const strength = smoothstep(length / (0.75 * width))
  return 1 - 0.68 * strength * (1 - smoothstep((cumulative.at(-1)! - travel) / length))
}

export interface InkProfileV5 {
  points: DrawingPoint[]
  baseFactors: number[]
  travel: number[]
  factors: number[]
  /** Inclusive first/last raw indices, never persisted as replacement input. */
  sourceRanges: [number, number][]
  sampleTimes: number[]
  highlighter: boolean
}

/** Append-only cache. Pen pressure-only repeats share one display anchor, but
 * every original pressure still contributes to the four-RAW-sample filter.
 * Group arrival speed stays fixed so dwelling cannot inflate a stable tip. */
export class InkProfileBuilderV5 {
  readonly profile: InkProfileV5
  private count = 0
  constructor(private width: number, private aspect: number, highlighter: boolean) {
    this.profile = { points: [], baseFactors: [], travel: [], factors: [], sourceRanges: [], sampleTimes: [], highlighter }
  }
  update(raw: readonly DrawingPoint[]): InkProfileV5 {
    if (raw.length < this.count) throw new Error('V5 profile measured samples must be append-only')
    const p = this.profile, oldCount = p.points.length
    for (let i = this.count; i < raw.length; i++) {
      const point = raw[i]!, previous = p.points.at(-1)
      if (!p.highlighter && previous && point.x === previous.x && point.y === previous.y) {
        const group = p.points.length - 1, range = p.sourceRanges[group]!
        range[1] = i
        p.points[group] = { ...point }
        p.baseFactors[group] = baseDiameterFactorV5(raw, i, range[0], this.aspect)
      } else {
        const group = p.points.length
        p.points.push({ ...point }); p.sourceRanges.push([i, i]); p.sampleTimes.push(group)
        p.travel.push(previous ? p.travel[group - 1]! + Math.hypot(point.x - previous.x, (point.y - previous.y) * this.aspect) : 0)
        p.baseFactors.push(p.highlighter ? 1 : baseDiameterFactorV5(raw, i, i, this.aspect))
      }
    }
    for (let i = Math.max(0, oldCount - 1 - INK_V5_TAIL_SEGMENTS); i < p.points.length; i++) {
      p.factors[i] = p.highlighter ? 1 : p.baseFactors[i]! * startGainV5(p.travel[i]!, this.width) * endGainV5(p.travel[i]!, p.travel, this.width)
    }
    this.count = raw.length
    return p
  }
}
export function renderProfileV5(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean): InkProfileV5 {
  const builder = new InkProfileBuilderV5(width, aspect, highlighter)
  if (!valid(points, width, aspect) || cumulativeTravelV5(points, aspect).length !== points.length) return builder.profile
  return builder.update(points)
}
/** Raw-count diagnostic mapping only; these factors never replace pressure. */
export function diameterFactorsV5(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean): number[] {
  const profile = renderProfileV5(points, width, aspect, highlighter), factors: number[] = []
  for (const [index, [first, last]] of profile.sourceRanges.entries()) {
    for (let raw = first; raw <= last; raw++) factors[raw] = profile.factors[index]!
  }
  return factors
}

/** The original V4 accepted polyline is retained exactly. Bounded extra knots
 * localize taper inside the two endpoint windows, including very sparse lines.
 * The pressure interpolation channel carries exact dyadic segment t, not force. */
export function segmentSamplesV5(profile: InkProfileV5, index: number, width: number, aspect: number): InkRenderSampleV5[] {
  const original = segmentSamplesV4(profile.points, index, width, aspect, profile.sampleTimes)
  if (!original.length) return []
  const first = profile.points[index]!, last = profile.points[index + 1]!
  const start = profile.travel[index]!, distance = profile.travel[index + 1]! - start
  const times = original.map(sample => sample.p - index)
  if (!profile.highlighter && distance > 0) {
    const endLength = endLengthV5(profile.travel, width), total = profile.travel.at(-1)!
    for (let step = 0; step < 8; step++) {
      for (const travel of [1.2 * width * (step + 1) / 8, total - endLength + endLength * step / 8]) {
        const t = (travel - start) / distance
        if (t > 0 && t < 1) times.push(t)
      }
    }
  }
  times.sort((a, b) => a - b)
  const unique = times.filter((t, i) => i === 0 || t !== times[i - 1])
  let cursor = 1
  return unique.map(t => {
    while (cursor < original.length - 1 && original[cursor]!.p - index < t) cursor++
    const after = original[cursor]!, before = original[cursor - 1]!
    let x: number, y: number
    if (t === 0) { x = first.x; y = first.y }
    else if (t === 1) { x = last.x; y = last.y }
    else if (t === after.p - index) { x = after.x; y = after.y }
    else {
      const local = (t - (before.p - index)) / (after.p - before.p)
      x = before.x + (after.x - before.x) * local; y = before.y + (after.y - before.y) * local
    }
    const base = profile.baseFactors[index]! + (profile.baseFactors[index + 1]! - profile.baseFactors[index]!) * t
    const travel = start + distance * t
    const factor = t === 0 ? profile.factors[index]! : t === 1 ? profile.factors[index + 1]! :
      profile.highlighter ? 1 : base * startGainV5(travel, width) * endGainV5(travel, profile.travel, width)
    return { x, y, factor }
  })
}
export function* strokeSegmentsV5(points: readonly DrawingPoint[], width: number, aspect: number,
  highlighter = false): Generator<InkSegmentV5> {
  const profile = renderProfileV5(points, width, aspect, highlighter)
  for (let index = 0; index + 1 < profile.points.length; index++) yield { index, samples: segmentSamplesV5(profile, index, width, aspect) }
}
export function strokeCenterlineV5(points: readonly DrawingPoint[], width: number, aspect: number, highlighter = false): InkRenderSampleV5[] {
  const profile = renderProfileV5(points, width, aspect, highlighter), first = profile.points[0]
  if (!first) return []
  const result: InkRenderSampleV5[] = [{ x: first.x, y: first.y, factor: profile.factors[0]! }]
  for (let index = 0; index + 1 < profile.points.length; index++) result.push(...segmentSamplesV5(profile, index, width, aspect).slice(1))
  return result
}

/** One nonzero compound fill unions the same convex 32-disk/tangent pieces as V4. */
export function* segmentPolygonsV5(samples: readonly InkRenderSampleV5[], width: number, aspect: number,
  includeFirst = true): Generator<InkVertex[]> {
  if (!(Number.isFinite(width) && width > 0 && Number.isFinite(aspect) && aspect > 0) ||
    !samples.every(point => [point.x, point.y, point.y * aspect, point.factor].every(Number.isFinite) && point.factor >= 0)) return
  for (let index = 0; index < samples.length; index++) {
    const point = samples[index]!, r = width * point.factor / 2, previous = samples[index - 1]
    if (previous) {
      const before = width * previous.factor / 2, dx = point.x - previous.x, dy = (point.y - previous.y) * aspect
      const distance = Math.hypot(dx, dy), difference = before - r
      if (Number.isFinite(distance) && distance > Math.abs(difference) && distance > 1e-12) {
        const ux = dx / distance, uy = dy / distance, along = difference / distance
        const across = Math.sqrt(Math.max(0, 1 - along * along))
        const lowX = ux * along + uy * across, lowY = uy * along - ux * across
        const highX = ux * along - uy * across, highY = uy * along + ux * across
        yield [[previous.x + lowX * before, previous.y + lowY * before / aspect],
          [point.x + lowX * r, point.y + lowY * r / aspect], [point.x + highX * r, point.y + highY * r / aspect],
          [previous.x + highX * before, previous.y + highY * before / aspect]]
      }
    }
    if (index > 0 || includeFirst) yield Array.from({ length: INK_V3_CIRCLE_SEGMENTS }, (_, step): InkVertex => {
      const angle = step * 2 * Math.PI / INK_V3_CIRCLE_SEGMENTS
      return [point.x + r * Math.cos(angle), point.y + r * Math.sin(angle) / aspect]
    })
  }
}

export function* strokePolygonIteratorV5(points: readonly DrawingPoint[], width: number, aspect: number,
  highlighter: boolean): Generator<InkVertex[]> {
  const profile = renderProfileV5(points, width, aspect, highlighter), first = profile.points[0]
  if (!first) return
  yield* segmentPolygonsV5([{ x: first.x, y: first.y, factor: profile.factors[0]! }], width, aspect)
  for (let index = 0; index + 1 < profile.points.length; index++) {
    yield* segmentPolygonsV5(segmentSamplesV5(profile, index, width, aspect), width, aspect, false)
  }
}

export function strokePolygonsV5(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean): InkVertex[][] {
  return [...strokePolygonIteratorV5(points, width, aspect, highlighter)]
}

export function strokePathV5(points: readonly DrawingPoint[], width: number, aspect: number, highlighter: boolean, scaleX = 1, scaleY = 1): string {
  const paths: string[] = []
  for (const polygon of strokePolygonIteratorV5(points, width, aspect, highlighter)) {
    paths.push(polygon.map(([x, y], index) => `${index === 0 ? 'M' : 'L'} ${x * scaleX} ${y * scaleY}`).join(' ') + ' Z')
  }
  return paths.join(' ')
}

export function predictionPolygonsV5(measured: readonly DrawingPoint[], predictions: readonly DrawingPoint[],
  width: number, aspect: number, highlighter: boolean): InkVertex[][] {
  if (!valid(measured, width, aspect) || !measured.length) return []
  const last = measured[measured.length - 1]!, factor = diameterFactorsV5(measured, width, aspect, highlighter).at(-1)!
  const samples: InkRenderSampleV5[] = [{ x: last.x, y: last.y, factor }]
  for (const point of predictions) {
    if (samples.length === 9) break
    if ([point.x, point.y, point.y * aspect].every(Number.isFinite)) samples.push({ x: point.x, y: point.y, factor })
  }
  return [...segmentPolygonsV5(samples, width, aspect, false)]
}
