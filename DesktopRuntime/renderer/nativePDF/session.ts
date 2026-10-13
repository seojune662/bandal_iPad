import { isJournaledDrawing, type NativePDFIdentity, type NativePDFTransport, type NativePDFDrawingWriter, type JournaledDrawingInput } from './types'

type NativeMutationFlight = { fingerprint: string; promise: Promise<string> }
// One document can be open in two split panes. Native journals belong to the
// document, so independent surfaces must not both insert one completion into
// their canonical hook/history while its receipt is still being committed.
const mutationFlights = new WeakMap<NativePDFTransport, Map<string, NativeMutationFlight>>()
function fingerprint(input: JournaledDrawingInput): string {
  const { courseId, relPath, page, kind, documentRevision, data, style } = input
  return JSON.stringify({ courseId, relPath, page, kind, documentRevision,
    data: { inkVersion: data.inkVersion, points: (data.points ?? []).map(({ x, y, p, t, tiltX, tiltY }) => ({ x, y, p, t, tiltX, tiltY })) },
    style: { color: style.color, width: style.width, opacity: style.opacity } })
}

/** Native completion journal -> the original drawing queue/history -> durable
 * backend receipt -> native ACK. In-flight and acknowledged creates are kept
 * separately, so an ACK retry does not push duplicate undo history. */
export class NativePDFSession {
  private creates = new Map<string, Promise<string>>()
  private acknowledgements = new Set<string>()
  private mutationIdsByDrawing = new Map<string, string>()
  private queue: Promise<void> = Promise.resolve()
  private failure: unknown
  private closed = false
  private closing: Promise<void> | null = null
  constructor(readonly identity: NativePDFIdentity, private transport: NativePDFTransport, private writer: NativePDFDrawingWriter) {}
  invoke(channel: string, payload: Record<string, unknown> = {}): Promise<unknown> {
    return this.transport.invoke(`pdfNative:${channel}`, { ...this.identity, ...payload })
  }
  /** Presentation-only association. Canonical rows omit the native receipt ID;
   * preserve it here so a pending preview and its saved row paint only once. */
  mutationIdForDrawing(drawingId: string): string | undefined { return this.mutationIdsByDrawing.get(drawingId) }
  accept(value: unknown): Promise<void> {
    if (!isJournaledDrawing(value, this.identity)) return Promise.reject(new Error('다른 자료이거나 잘못된 PDF 필기 작업입니다.'))
    if (this.closed) return Promise.reject(new Error('닫힌 PDF 표면에는 필기를 저장할 수 없습니다.'))
    const input = value
    const operation = this.queue.then(() => this.commit(input))
    this.queue = operation.catch(error => { this.failure = error })
    return operation
  }
  private async commit(input: JournaledDrawingInput): Promise<void> {
    const key = input.clientMutationId
    if (this.acknowledgements.has(key)) return
    let create = this.creates.get(key)
    if (!create) {
      create = this.recoverOrCreate(input)
      this.creates.set(key, create)
      create.catch(() => { if (this.creates.get(key) === create) this.creates.delete(key) })
    }
    const drawingId = await create
    this.mutationIdsByDrawing.set(drawingId, key)
    await this.invoke('ack', { clientMutationId: key, drawingId })
    this.acknowledgements.add(key)
    this.failure = undefined
  }
  private async recoverOrCreate(input: JournaledDrawingInput): Promise<string> {
    let flights = mutationFlights.get(this.transport)
    if (!flights) { flights = new Map(); mutationFlights.set(this.transport, flights) }
    const key = input.clientMutationId, expected = fingerprint(input), existing = flights.get(key)
    if (existing) {
      if (existing.fingerprint !== expected) throw new Error('같은 필기 작업에 서로 다른 내용이 있어 복구 기록을 보존했습니다.')
      return existing.promise
    }
    const operation = this.resolveReceiptOrCreate(input)
    const flight = { fingerprint: expected, promise: operation }
    flights.set(key, flight)
    const remove = (): void => { if (flights.get(key) === flight) flights.delete(key) }
    void operation.then(remove, remove)
    return operation
  }
  private async resolveReceiptOrCreate(input: JournaledDrawingInput): Promise<string> {
    const receipt = await this.invoke('mutationStatus', { input }) as { status?: unknown; drawingId?: unknown }
    if (receipt?.status === 'live' || receipt?.status === 'deleted') {
      if (typeof receipt.drawingId !== 'string' || !receipt.drawingId) throw new Error('필기 완료 기록이 올바르지 않습니다. 복구 기록을 보존했습니다.')
      // The operation committed before a lost reply. Undo may already have
      // deleted it; neither replay case is a new user edit or undo entry.
      return receipt.drawingId
    }
    if (receipt?.status !== 'missing') throw new Error('필기 완료 상태를 확인하지 못했습니다. 복구 기록을 보존했습니다.')
    const drawing = await this.writer.create(input)
    if (!drawing?.id) throw new Error('PDF 필기가 저장되지 않았습니다. 복구 기록을 보존했습니다.')
    return drawing.id
  }
  async replay(values: unknown[]): Promise<void> { for (const input of values) await this.accept(input) }
  async flush(): Promise<void> {
    if (this.closed) return
    const response = await this.invoke('flush') as { pending?: unknown[] }
    await this.replay(response.pending ?? [])
    let current: Promise<void>
    do { current = this.queue; await current } while (current !== this.queue)
    if (this.failure) throw this.failure
    await this.writer.flush?.()
  }
  async close(): Promise<void> {
    if (this.closed) return
    if (this.closing) return this.closing
    const operation = (async () => {
      await this.flush()
      await this.invoke('close'); this.closed = true
    })()
    this.closing = operation
    try { await operation }
    finally { if (this.closing === operation) this.closing = null }
  }
}
