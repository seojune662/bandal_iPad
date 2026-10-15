export interface NativePDFDrawingPatch {
  reset: boolean
  baseRevision: number
  revision: number
  order: string[]
  upserts: Record<string, unknown>[]
}
interface Row { json: string; payload: Record<string, unknown> }
interface Snapshot { state: Record<string, unknown>; order: string[]; rows: Map<string, Row> }

/** One ordered snapshot RPC at a time. Intermediate states coalesce, while
 * unchanged drawing rows never cross the bridge again. Failed/unknown replies
 * recover with a complete reset, including all rows and the latest UI state. */
export class NativePDFDrawingSnapshotPublisher {
  private acknowledged = new Map<string, Row>()
  private prepared = new Map<string, Row>()
  private pending: Snapshot | null = null
  private running: Promise<void> | null = null
  private issuedRevision = 0
  private acknowledgedRevision = 0
  private needsReset = true
  private disposed = false
  constructor(private readonly send: (payload: Record<string, unknown>) => Promise<unknown>,
    private readonly supportsPatch = true) {}

  publish(state: Record<string, unknown>, drawings: readonly Record<string, unknown>[]): Promise<void> {
    if (this.disposed) return Promise.resolve()
    try {
      const rows = new Map<string, Row>(), order: string[] = []
      for (const drawing of drawings) {
        const id = drawing.id
        if (typeof id !== 'string' || !id || rows.has(id)) throw new Error('PDF 필기 식별자가 없거나 중복되었습니다.')
        const json = JSON.stringify(drawing), previous = this.prepared.get(id)
        // Freeze the queued payload; callers may edit their dictionaries while
        // the previous RPC is still in flight. JSON also strips native markers.
        const row = previous?.json === json ? previous : { json, payload: JSON.parse(json) as Record<string, unknown> }
        rows.set(id, row); order.push(id)
      }
      this.prepared = rows
      const frozen = JSON.parse(JSON.stringify(state)) as Record<string, unknown>
      delete frozen.drawings; delete frozen.drawingPatch
      this.pending = { state: frozen, order, rows }
      return this.running ?? this.start()
    } catch (error) { return Promise.reject(error) }
  }

  dispose(): void { this.disposed = true; this.pending = null }
  async flush(): Promise<void> { await this.running }

  private start(): Promise<void> {
    // Deferring the drain also coalesces same-turn React updates. Recheck when
    // its promise settles: another microtask may publish just after its loop.
    this.running = Promise.resolve().then(() => this.drain()).then(() => {
      this.running = null
      if (this.pending && !this.disposed) return this.start()
    }, error => { this.running = null; throw error })
    return this.running
  }

  private async drain(): Promise<void> {
    let failures = 0
    while (this.pending && !this.disposed) {
      const snapshot = this.pending; this.pending = null
      const revision = ++this.issuedRevision
      const reset = this.needsReset
      const patch: NativePDFDrawingPatch = { reset, baseRevision: reset ? 0 : this.acknowledgedRevision,
        revision, order: snapshot.order,
        upserts: [...snapshot.rows].filter(([id, row]) => reset || this.acknowledged.get(id)?.json !== row.json).map(([, row]) => row.payload) }
      try {
        await this.send({ ...snapshot.state, ...(this.supportsPatch ? { drawingPatch: patch } :
          { drawings: snapshot.order.map(id => snapshot.rows.get(id)!.payload) }) })
        this.acknowledged = snapshot.rows; this.acknowledgedRevision = revision; this.needsReset = false; failures = 0
      } catch (error) {
        // A lost response may already have applied this revision. Never retry
        // its incremental base; a newer reset is valid in either native state.
        this.needsReset = true
        if (!this.pending) this.pending = snapshot
        if (++failures >= 2) throw error
      }
    }
  }
}
