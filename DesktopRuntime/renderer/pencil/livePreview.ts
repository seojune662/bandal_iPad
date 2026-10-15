import type { DrawingPoint, DrawingStyle } from '../../upstream/src/shared/types/drawing'
import type { InkVertex } from '../../upstream/src/shared/inkV2'
import { filteredPressuresV3 } from '../../upstream/src/shared/inkV3'
import { segmentSamplesV4, segmentPolygonsV4 } from '../../upstream/src/shared/inkV4'
import { InkProfileBuilderV5, type InkProfileV5, segmentSamplesV5, segmentPolygonsV5, INK_V5_TAIL_SEGMENTS } from '../../upstream/src/shared/inkV5'

const SVG_NAMESPACE = 'http://www.w3.org/2000/svg'
const paths = (polygons: Iterable<InkVertex[]>): string => {
  const result: string[] = []
  for (const polygon of polygons) result.push(polygon.map(([x, y], index) =>
    `${index === 0 ? 'M' : 'L'} ${x} ${y}`).join(' ') + ' Z')
  return result.join(' ')
}
const join = (prefix: string, tail: string): string => prefix + (prefix && tail ? ' ' : '') + tail

/** Append-only measured input. Each segment needs one future measured neighbor,
 * so only the last segment is provisional. Earlier geometry and serialized
 * paths are reused. Predicted positions never become measured curve controls. */
export class IncrementalInkPathV4 {
  private count = 0
  private pressures: number[] = []
  private settledSegments = 0
  private prefix = ''
  private measured = ''
  private last: DrawingPoint | undefined

  constructor(private width: number, private aspect: number, private highlighter: boolean) {}

  get settledPath(): string { return this.prefix }
  get measuredPath(): string { return this.measured }

  update(points: readonly DrawingPoint[]): string {
    if (points.length === this.count) return this.measured
    if (points.length < this.count) throw new Error('Live ink measured samples must be append-only')
    for (let i = this.count; i < points.length; i++) {
      const point = points[i]!
      const pair = i > 0 ? [{ ...points[i - 1]!, p: this.pressures[i - 1]! }, point] : [point]
      this.pressures.push(filteredPressuresV3(pair).at(-1)!)
    }
    if (this.count === 0 && points[0]) {
      this.prefix = paths(segmentPolygonsV4([{ x: points[0].x, y: points[0].y, p: this.pressures[0]! }],
        this.width, this.aspect, this.highlighter))
    }
    for (; this.settledSegments < points.length - 2; this.settledSegments++) {
      this.prefix = join(this.prefix, this.segment(points, this.settledSegments))
    }
    this.measured = join(this.prefix, points.length > 1 ? this.segment(points, points.length - 2) : '')
    this.count = points.length
    this.last = points.at(-1)
    return this.measured
  }

  predictionPath(predictions: readonly DrawingPoint[]): string {
    if (!this.last) return ''
    const pressure = this.pressures.at(-1)!
    const samples = [{ x: this.last.x, y: this.last.y, p: pressure }]
    for (const point of predictions) {
      if (samples.length === 9) break
      if ([point.x, point.y, point.y * this.aspect].every(Number.isFinite)) {
        samples.push({ x: point.x, y: point.y, p: pressure })
      }
    }
    return paths(segmentPolygonsV4(samples, this.width, this.aspect, this.highlighter, false))
  }

  private segment(points: readonly DrawingPoint[], index: number): string {
    const samples = segmentSamplesV4(points, index, this.width, this.aspect, this.pressures)
    return paths(segmentPolygonsV4(samples, this.width, this.aspect, this.highlighter, false))
  }
}

/** Causal pressure/start profile and travel are computed once per measured
 * sample. Only the final 16 segments have mutable end taper (and V4's final
 * control handle); earlier geometry and serialized text stay settled. */
export class IncrementalInkPathV5 {
  private count = 0
  private profiles: InkProfileBuilderV5
  private profile: InkProfileV5
  private settledSegments = 0
  private prefix = ''
  private measured = ''
  private generated = 0
  constructor(private width: number, private aspect: number, highlighter: boolean) {
    this.profiles = new InkProfileBuilderV5(width, aspect, highlighter)
    this.profile = this.profiles.profile
  }
  get settledPath(): string { return this.profile.highlighter || this.profile.points.length > 1 ? this.prefix : '' }
  get measuredPath(): string { return this.measured }
  get generatedSegments(): number { return this.generated }
  update(points: readonly DrawingPoint[]): string {
    if (points.length === this.count) return this.measured
    const profile = this.profiles.update(points)
    // Before the first moving segment settles, stationary pressure changes can
    // still change the initial dot. Afterwards its causal group is immutable.
    if (this.settledSegments === 0 && profile.points[0]) this.prefix = paths(segmentPolygonsV5([
      { x: profile.points[0].x, y: profile.points[0].y, factor: profile.factors[0]! }
    ], this.width, this.aspect))
    const tailStart = Math.max(0, profile.points.length - 1 - INK_V5_TAIL_SEGMENTS)
    for (; this.settledSegments < tailStart; this.settledSegments++) this.prefix = join(this.prefix, this.segment(this.settledSegments))
    const tail: string[] = []
    for (let i = tailStart; i + 1 < profile.points.length; i++) tail.push(this.segment(i))
    this.measured = join(this.prefix, tail.join(' ')); this.count = points.length
    return this.measured
  }
  predictionPath(predictions: readonly DrawingPoint[]): string {
    const last = this.profile.points.at(-1)
    if (!last) return ''
    const factor = this.profile.factors.at(-1)!
    const samples = [{ x: last.x, y: last.y, factor }]
    for (const point of predictions) {
      if (samples.length === 9) break
      if ([point.x, point.y, point.y * this.aspect].every(Number.isFinite)) samples.push({ x: point.x, y: point.y, factor })
    }
    return paths(segmentPolygonsV5(samples, this.width, this.aspect, false))
  }
  private segment(index: number): string {
    this.generated++
    return paths(segmentPolygonsV5(segmentSamplesV5(this.profile, index, this.width, this.aspect), this.width, this.aspect, false))
  }
}

/** React owns the empty host group. Update one canonical compound path inside
 * the input event, without a display-link or React scheduling hop. Geometry and
 * its serialized settled prefix are incremental; WebKit still parses the full
 * path on each update. Separate paths (including clip-path children) antialias
 * overlaps differently, so measured and predicted ink must share one fill. */
export class LiveInkPreview {
  private path: SVGPathElement | null = null
  private points: readonly DrawingPoint[] | null = null
  private builder: IncrementalInkPathV5 | null = null
  private measuredCount = 0
  private hasPredictions = false
  private width = 0
  private aspect = 0
  private highlighter = false

  clear(): void {
    this.path?.remove()
    this.path = null
    this.points = null
    this.builder = null
    this.measuredCount = 0
    this.hasPredictions = false
  }

  render(host: SVGGElement | null, points: readonly DrawingPoint[], style: DrawingStyle,
    aspect: number, highlighter: boolean, color: string, predictions: readonly DrawingPoint[] = []): void {
    if (!host) return
    if (this.points !== points || this.measuredCount > points.length || this.path?.parentNode !== host ||
        this.width !== style.width || this.aspect !== aspect || this.highlighter !== highlighter) {
      this.clear()
      this.points = points
      this.width = style.width
      this.aspect = aspect
      this.highlighter = highlighter
      this.builder = new IncrementalInkPathV5(style.width, aspect, highlighter)
      this.path = document.createElementNS(SVG_NAMESPACE, 'path')
      this.path.setAttribute('class', highlighter ? 'ink-layer__preview is-highlighter' : 'ink-layer__preview')
      this.path.setAttribute('fill', color)
      this.path.setAttribute('opacity', String(style.opacity))
      this.path.setAttribute('data-ink-measured', '')
      host.append(this.path)
    }
    if (this.measuredCount !== points.length || predictions.length > 0 || this.hasPredictions) {
      const measured = this.builder!.update(points), tail = this.builder!.predictionPath(predictions)
      this.path!.setAttribute('d', join(measured, tail))
      this.measuredCount = points.length
      this.hasPredictions = tail.length > 0
      if (this.hasPredictions) this.path!.setAttribute('data-ink-prediction', '')
      else this.path!.removeAttribute('data-ink-prediction')
    }
  }
}
