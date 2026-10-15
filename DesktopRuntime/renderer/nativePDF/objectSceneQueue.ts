import type { NativeObjectScene } from './objectScene'

interface FrozenRow { json: string; payload: Record<string, unknown> }
interface FrozenScene { json: string; payload: Record<string, unknown>; rows?: Map<string, FrozenRow> | undefined }
interface PageScene {
  latest?: FrozenScene | undefined
  pending?: FrozenScene | undefined
  acknowledged?: string | undefined
  base?: { revision: number; rows: Map<string, FrozenRow> } | undefined
  failures: number
  failed: boolean
  error?: unknown
}
const integer = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value > 0
const record = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value)
// Native patch keys are UTF-8 bytes. Lone UTF-16 surrogates cannot identify a
// lossless UTF-8 key; preserve those rows through the legacy full wire instead.
const rowID = (value: unknown): value is string => {
  if (typeof value !== 'string' || !value) return false
  for (let i = 0; i < value.length; i++) {
    const unit = value.charCodeAt(i)
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++i)
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false
  }
  return true
}

/** Presentation only: one RPC per session, one latest scene per mounted page.
 * Every publish serializes all input, including unknown metadata and mutable
 * nested containers. Only acknowledged immutable row JSON can be a delta base.
 * Pointer input, canonical drawings, delete/undo and persistence stay separate. */
export class NativePDFObjectSceneQueue {
  private pages = new Map<number, PageScene>()
  private running: Promise<void> | null = null
  private tool = ''
  private epoch = 0
  private issuedRevision = 0
  private active = false
  private ready = false
  private disposed = false

  constructor(private readonly send: (payload: Record<string, unknown>) => Promise<unknown>,
    private readonly report: (error: unknown, retry: () => Promise<void>) => void,
    private supportsPatch = false) {}

  /** Capability negotiation precedes open/active; old hosts retain full scenes. */
  configurePatch(enabled: boolean): void {
    if (this.active || this.running) throw new Error('PDF 개체 기능 설정이 너무 늦었습니다.')
    this.supportsPatch = enabled
  }

  /** Called by the snapshot publisher's actual send callback, never a publish
   * promise shared by coalesced snapshots. Legacy transport omits the local
   * epoch while still using that exact transmitted snapshot's ownership. */
  async sendSnapshot(payload: Record<string, unknown>, send: (payload: Record<string, unknown>) => Promise<unknown>): Promise<unknown> {
    const epoch = payload.objectSceneEpoch, tool = record(payload.tool) ? payload.tool.name : undefined
    const { objectSceneEpoch: _, ...legacy } = payload
    const reply = await send(this.supportsPatch ? payload : legacy)
    if (this.supportsPatch && (!integer(epoch) || typeof tool !== 'string' || !record(reply) ||
      !integer(reply.objectSceneEpoch) || reply.objectSceneEpoch !== epoch || reply.tool !== tool)) {
      throw new Error('PDF 개체 도구 응답이 일치하지 않습니다.')
    }
    if (integer(epoch) && tool === this.tool) this.acknowledgeTool(epoch)
    return reply
  }

  observeTool(tool: string): number {
    if (this.disposed) return this.epoch
    if (tool !== this.tool) { this.tool = tool; this.invalidate() }
    return this.epoch
  }

  resume(tool: string): void {
    if (this.disposed) return
    this.active = true; this.tool = tool; this.invalidate()
  }
  pause(): void { this.active = false; this.invalidate() }

  acknowledgeTool(epoch: number): void {
    if (this.disposed || !this.active || epoch !== this.epoch || this.isInk() || this.ready) return
    this.ready = true
    for (const state of this.pages.values()) state.pending = state.latest
    this.start()
  }

  publish(page: number, scene: NativeObjectScene, tool: string): void {
    if (this.disposed || !this.active) return
    this.observeTool(tool)
    if (this.isInk()) return
    if (!integer(page)) throw new Error('PDF 개체 페이지가 올바르지 않습니다.')
    // Freeze before waiting: arrays/objects/style may change in place. IDs are
    // exact JS strings, so canonically equivalent Unicode IDs remain distinct.
    const json = JSON.stringify({ ...scene, page })
    let state = this.pages.get(page)
    if (!state) { state = { failures: 0, failed: false }; this.pages.set(page, state) }
    if (state.latest?.json !== json) {
      const payload = JSON.parse(json) as Record<string, unknown>
      state.latest = { json, payload, ...(this.supportsPatch ? { rows: this.rows(payload.objects) } : {}) }
    }
    state.pending = state.acknowledged === json ? undefined : state.latest
    this.start()
  }

  prunePages(mounted: ReadonlySet<number>): void {
    for (const page of this.pages.keys()) if (!mounted.has(page)) this.pages.delete(page)
  }
  dispose(): void { this.disposed = true; this.pause() }

  async retry(): Promise<void> {
    if (this.disposed) return
    for (const state of this.pages.values()) {
      state.error = undefined; state.failed = false; state.failures = 0; state.acknowledged = undefined; state.base = undefined
      state.pending = state.latest
    }
    this.start(); await this.flush()
  }
  /** Test/retry barrier; never part of the native ink durability flush. */
  async flush(): Promise<void> {
    while (this.running) await this.running
    for (const state of this.pages.values()) if (state.failed) throw state.error
  }

  private rows(objects: unknown): Map<string, FrozenRow> | undefined {
    if (!Array.isArray(objects)) return undefined
    const rows = new Map<string, FrozenRow>()
    for (const object of objects) {
      if (!record(object) || !rowID(object.id) || rows.has(object.id)) return undefined
      rows.set(object.id, { json: JSON.stringify(object), payload: object })
    }
    return rows
  }
  private isInk(): boolean { return this.tool === 'pen' || this.tool === 'highlighter' }
  private invalidate(): void {
    this.ready = false; this.pages.clear()
    if (!Number.isSafeInteger(this.epoch + 1)) {
      this.disposed = true; this.active = false
      throw new Error('PDF 개체 도구 버전 한도를 초과했습니다.')
    }
    this.epoch++
    // Issued revision never resets, including prune/remount/tool changes. An
    // old RPC keeps the global slot but cannot ACK a new epoch/page instance.
  }
  private start(): void {
    if (this.disposed || !this.active || !this.ready || this.running || this.isInk()) return
    if (![...this.pages.values()].some(state => state.pending && !state.failed)) return
    this.running = Promise.resolve().then(() => this.drain()).finally(() => { this.running = null; this.start() })
  }

  private request(frame: FrozenScene, state: PageScene, epoch: number): Record<string, unknown> {
    if (!this.supportsPatch) return frame.payload
    if (!Number.isSafeInteger(this.issuedRevision + 1)) throw new Error('PDF 개체 화면 버전 한도를 초과했습니다.')
    const revision = ++this.issuedRevision
    const version = { objectSceneEpoch: epoch, objectSceneRevision: revision }
    if (!frame.rows) return { ...frame.payload, ...version }
    const { objects: _, ...metadata } = frame.payload
    const reset = !state.base
    return { ...metadata, ...version, objectPatch: { reset, baseRevision: state.base?.revision ?? 0, revision,
      order: [...frame.rows.keys()], upserts: [...frame.rows].filter(([id, row]) => reset || state.base!.rows.get(id)?.json !== row.json)
        .map(([, row]) => row.payload) } }
  }
  private validReply(reply: unknown, request: Record<string, unknown>): boolean {
    return record(reply) && ['page', 'objectSceneEpoch', 'objectSceneRevision'].every(key => integer(reply[key]) && reply[key] === request[key])
  }

  private async drain(): Promise<void> {
    while (!this.disposed && this.active && this.ready && !this.isInk()) {
      const entry = [...this.pages].find(([, state]) => state.pending && !state.failed)
      if (!entry) return
      const [page, state] = entry, frame = state.pending!, epoch = this.epoch
      state.pending = undefined
      if (state.acknowledged === frame.json) continue
      try {
        const request = this.request(frame, state, epoch), reply = await this.send(request)
        if (this.disposed || epoch !== this.epoch || this.pages.get(page) !== state) continue
        if (this.supportsPatch && !this.validReply(reply, request)) throw new Error('PDF 개체 화면 응답이 일치하지 않습니다.')
        state.acknowledged = frame.json
        // A versioned legacy full scene does not establish a patch base.
        state.base = this.supportsPatch && frame.rows ? { revision: request.objectSceneRevision as number, rows: frame.rows } : undefined
        state.failures = 0
        state.pending = state.latest?.json === frame.json ? undefined : state.latest
      } catch (error) {
        if (this.disposed || epoch !== this.epoch || this.pages.get(page) !== state) continue
        // Lost/mismatched replies may already have applied. A strictly newer
        // reset handles either outcome, once automatically then explicit retry.
        state.acknowledged = undefined; state.base = undefined; state.pending = state.latest
        if (++state.failures >= 2) {
          state.error = error; state.failed = true
          try { this.report(error, () => this.retry()) } catch { /* Preserve terminal failure. */ }
        }
      } finally {
        if (epoch === this.epoch && this.pages.get(page) === state) { this.pages.delete(page); this.pages.set(page, state) }
      }
    }
  }
}
