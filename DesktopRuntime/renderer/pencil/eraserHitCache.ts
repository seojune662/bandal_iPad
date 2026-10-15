import type { DrawingPoint, DrawingShape } from '../../upstream/src/shared/types/drawing'
import { strokeCenterlineV4, type InkRenderSampleV4 } from '../../upstream/src/shared/inkV4'
import { strokeCenterlineV5 } from '../../upstream/src/shared/inkV5'
import { drawingHit } from '../../upstream/src/renderer/src/features/ink/inkGeometry'

interface Limits { entries: number; rawPoints: number; renderedPoints: number; accountedBytes: number }
interface Entry {
  kind: DrawingShape['kind']; version: 4 | 5; width: number; aspect: number
  /** x/y/p/t plus a presence flag: undefined and numeric NaN stay distinct. */
  raw: Float64Array
  points: InkRenderSampleV4[]
  bytes: number
}
const DEFAULT_LIMITS: Limits = { entries: 512, rawPoints: 32_768, renderedPoints: 65_536, accountedBytes: 4 * 1024 * 1024 }

/** An eraser contact owns this cache. Raw primitives are compared on EVERY hit;
 * object/array identity and caller-supplied revisions never authorize reuse.
 * The canonical hit function remains the sole owner of distance/threshold/
 * malformed-shape semantics. Prepared samples are display-only, never saved. */
export class EraserGestureHitCache {
  private active = false
  private entries = new Map<string, Entry>()
  private rawPoints = 0
  private renderedPoints = 0
  private accountedBytes = 0
  private computations = 0
  private reuses = 0
  private fallbacks = 0
  private readonly limits: Limits

  constructor(limits: Partial<Limits> = {}) {
    this.limits = { ...DEFAULT_LIMITS, ...limits }
    for (const value of Object.values(this.limits)) {
      if (!Number.isSafeInteger(value) || value < 0) throw new Error('Invalid eraser cache limit')
    }
  }
  begin(): void { this.clear(); this.active = true }
  clear(): void {
    this.active = false; this.entries.clear()
    this.rawPoints = 0; this.renderedPoints = 0; this.accountedBytes = 0
    this.computations = 0; this.reuses = 0; this.fallbacks = 0
  }
  get statistics(): Readonly<Limits & { computations: number; reuses: number; fallbacks: number; active: boolean }> {
    return { entries: this.entries.size, rawPoints: this.rawPoints, renderedPoints: this.renderedPoints,
      accountedBytes: this.accountedBytes, computations: this.computations, reuses: this.reuses,
      fallbacks: this.fallbacks, active: this.active }
  }

  hit(shape: DrawingShape, point: DrawingPoint, aspect: number): boolean {
    const fallback = (): boolean => { this.fallbacks++; return drawingHit(shape, point, aspect) }
    if (!this.active) return fallback()
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) return fallback()
    const id = shape.id, source = shape.data.points, width = shape.style.width
    const safeAspect = Number.isFinite(aspect) && aspect > 0 ? aspect : 1
    if ((shape.kind !== 'ink' && shape.kind !== 'highlighter') || (shape.data.inkVersion !== 4 && shape.data.inkVersion !== 5) ||
        typeof id !== 'string' || !id || !Array.isArray(source) ||
        source.length > this.limits.rawPoints || !Number.isFinite(width) || width <= 0) {
      this.drop(id); return fallback()
    }
    // Unusual/malformed input keeps the pure function's exact behavior, including
    // its locationless fallback. No point is repaired or silently filtered here.
    for (const raw of source) {
      if (!raw || ![raw.x, raw.y, raw.p, raw.y * safeAspect].every(Number.isFinite) ||
          (raw.t !== undefined && typeof raw.t !== 'number')) { this.drop(id); return fallback() }
    }
    let entry = this.entries.get(id)
    if (entry && this.matches(entry, shape.kind, shape.data.inkVersion, width, safeAspect, source)) this.reuses++
    else {
      this.drop(id)
      if (this.entries.size >= this.limits.entries || this.rawPoints + source.length > this.limits.rawPoints) return fallback()
      const points = shape.data.inkVersion === 5
        ? strokeCenterlineV5(source, width, safeAspect, shape.kind === 'highlighter').map(({ x, y, factor }) => ({ x, y, p: factor }))
        : strokeCenterlineV4(source, width, safeAspect)
      this.computations++
      // Raw bytes are exact typed-array storage. Rendered samples + array slots
      // use a conservative 96-byte charge, with bounded entry/key overhead.
      // This is a deterministic retention budget, not a JS heap measurement.
      const bytes = source.length * 5 * 8 + points.length * 96 + 256 + id.length * 2
      if (this.renderedPoints + points.length > this.limits.renderedPoints ||
          this.accountedBytes + bytes > this.limits.accountedBytes) {
        // Already computed once: use it for this call without retaining it,
        // rather than falling back and computing the same curve a second time.
        this.fallbacks++
        return this.hitPolyline(shape, point, safeAspect, points)
      }
      const raw = new Float64Array(source.length * 5)
      for (let index = 0; index < source.length; index++) {
        const value = source[index]!, offset = index * 5
        raw[offset] = value.x; raw[offset + 1] = value.y; raw[offset + 2] = value.p
        raw[offset + 3] = value.t === undefined ? 0 : value.t; raw[offset + 4] = value.t === undefined ? 0 : 1
      }
      entry = { kind: shape.kind, version: shape.data.inkVersion, width, aspect: safeAspect, raw, points, bytes }
      this.entries.set(id, entry)
      this.rawPoints += source.length; this.renderedPoints += points.length; this.accountedBytes += bytes
    }
    // A v3-tagged, render-only polyline selects canonical drawingHit's same
    // metric transform, finite filtering, box fallback and distance threshold.
    // It does NOT select the v3 rendering algorithm or change the source row.
    return this.hitPolyline(shape, point, safeAspect, entry.points)
  }

  private hitPolyline(shape: DrawingShape, point: DrawingPoint, aspect: number, points: InkRenderSampleV4[]): boolean {
    return drawingHit({ ...shape, data: { ...shape.data, inkVersion: 3, points } }, point, aspect)
  }

  private matches(entry: Entry, kind: DrawingShape['kind'], version: 4 | 5, width: number, aspect: number, source: readonly DrawingPoint[]): boolean {
    if (entry.kind !== kind || entry.version !== version || !Object.is(entry.width, width) || !Object.is(entry.aspect, aspect) || entry.raw.length !== source.length * 5) return false
    for (let index = 0; index < source.length; index++) {
      const point = source[index]!, offset = index * 5, raw = entry.raw
      if (!Object.is(raw[offset], point.x) || !Object.is(raw[offset + 1], point.y) || !Object.is(raw[offset + 2], point.p) ||
          raw[offset + 4] !== (point.t === undefined ? 0 : 1) ||
          (point.t !== undefined && !Object.is(raw[offset + 3], point.t))) return false
    }
    return true
  }
  private drop(id: string): void {
    const entry = this.entries.get(id)
    if (!entry) return
    this.entries.delete(id); this.rawPoints -= entry.raw.length / 5
    this.renderedPoints -= entry.points.length; this.accountedBytes -= entry.bytes
  }
}
