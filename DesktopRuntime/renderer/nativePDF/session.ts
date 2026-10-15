import { isJournaledDrawing, isNativePDFErase, type NativePDFIdentity, type NativePDFTransport, type NativePDFDrawingWriter, type JournaledDrawingInput, type NativePDFOperation, type NativePDFEraseInput, type NativePDFEraseResult } from './types'
import { sha256UTF8 } from './operationDigest'

type NativeMutationFlight = { fingerprint: string; promise: Promise<string> }
// One document can be open in two split panes. Native journals belong to the
// document, so independent surfaces must not both insert one completion into
// their canonical hook/history while its receipt is still being committed.
const mutationFlights = new WeakMap<NativePDFTransport, Map<string, NativeMutationFlight>>()
type OrderedOperation = { input: NativePDFOperation; fingerprint: string; promise: Promise<void>; resolve(): void; reject(error: unknown): void; failed: boolean }
type EraseReceipt = { fingerprint: string; result?: NativePDFEraseResult; failure?: Error }
function fingerprint(input: JournaledDrawingInput): string {
  const { courseId, relPath, page, kind, documentRevision, data, style } = input
  return JSON.stringify({ courseId, relPath, page, kind, documentRevision,
    data: { inkVersion: data.inkVersion, points: (data.points ?? []).map(({ x, y, p, t, tiltX, tiltY }) => ({ x, y, p, t, tiltX, tiltY })) },
    style: { color: style.color, width: style.width, opacity: style.opacity } })
}

function operationFingerprint(input: NativePDFOperation): string {
  let value: unknown = input
  if (input.type === 'stroke') {
    const { operationSequence, clientMutationId, courseId, relPath, page, kind, documentRevision, data, style } = input
    // Push and flush dictionary insertion order is not a receipt identity.
    value = { type: 'stroke', operationSequence, clientMutationId, courseId, relPath, page, kind, documentRevision,
      data: { inkVersion: data.inkVersion, points: data.points!.map(({ x, y, p, t, tiltX, tiltY }) => ({ x, y, p, t, tiltX, tiltY })) },
      style: { color: style.color, width: style.width, opacity: style.opacity } }
  }
  return sha256UTF8(JSON.stringify(value, (_key, item) => typeof item === 'number' && Object.is(item, -0) ? { nativeNegativeZero: true } : item))
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
  private flushing: Promise<void> | null = null
  private eraseRevision: string | null = null
  private operations = new Map<number, OrderedOperation>()
  private operationMutations = new Map<string, number>()
  private eraseReceipts = new Map<string, EraseReceipt>()
  private operationFailures = new Map<number, unknown>()
  private completedOperationSequence = 0
  // Keep compact receipt comparisons for late duplicates. Only 64 hex digits
  // per operation survive completion; raw points and normalized JSON do not.
  private completedOperationFingerprints = new Map<number, string>()
  private operationDrain: Promise<void> | null = null
  constructor(readonly identity: NativePDFIdentity, private transport: NativePDFTransport, private writer: NativePDFDrawingWriter) {}
  configureNativeErase(enabled: boolean, documentRevision?: string): void {
    if (this.eraseRevision !== null || this.operations.size || this.completedOperationSequence) throw new Error('PDF 지우개 저장 연결이 이미 설정되었습니다.')
    if (!enabled) return
    if (!documentRevision || !/^[0-9a-f]{64}$/i.test(documentRevision) || !this.writer.remove) throw new Error('PDF 지우개 저장 연결을 확인하지 못했습니다.')
    this.eraseRevision = documentRevision
  }
  get nativeInkErase(): boolean { return this.eraseRevision !== null }
  invoke(channel: string, payload: Record<string, unknown> = {}): Promise<unknown> {
    return this.transport.invoke(`pdfNative:${channel}`, { ...this.identity, ...payload })
  }
  /** Presentation-only association. Canonical rows omit the native receipt ID;
   * preserve it here so a pending preview and its saved row paint only once. */
  mutationIdForDrawing(drawingId: string): string | undefined { return this.mutationIdsByDrawing.get(drawingId) }
  accept(value: unknown): Promise<void> {
    if (this.nativeInkErase && value && typeof value === 'object' && 'operationSequence' in value) {
      return this.acceptOperation({ ...value, type: 'stroke' })
    }
    if (!isJournaledDrawing(value, this.identity)) return Promise.reject(new Error('다른 자료이거나 잘못된 PDF 필기 작업입니다.'))
    if (this.closed) return Promise.reject(new Error('닫힌 PDF 표면에는 필기를 저장할 수 없습니다.'))
    const input = value
    const operation = this.queue.then(() => this.commit(input))
    this.queue = operation.catch(error => { this.failure = error })
    return operation
  }
  /** Both push events and flush replies enter here. Native flush returns the
   * sealed payloads without waiting for JS, so late WK delivery cannot let undo
   * overtake a deletion. Only this owner's original writer is ever used. */
  acceptOperation(value: unknown): Promise<void> {
    try { return this.registerOperation(this.freezeOperation(value)) }
    catch (error) { return Promise.reject(error) }
  }
  private freezeOperation(value: unknown): NativePDFOperation {
    if (this.closed) throw new Error('닫힌 PDF 표면에는 필기를 저장할 수 없습니다.')
    if (!this.eraseRevision || !value || typeof value !== 'object') throw new Error('PDF 지우개 작업 연결이 올바르지 않습니다.')
    const operation = value as NativePDFOperation
    if (!Number.isSafeInteger(operation.operationSequence) || operation.operationSequence <= 0) throw new Error('PDF 작업 순서가 올바르지 않습니다.')
    if (operation.type === 'stroke' && isJournaledDrawing(operation, this.identity) && operation.documentRevision === this.eraseRevision) {
      // Preserve measured IEEE values, including -0. JSON is only a comparison
      // representation; it must never round-trip the canonical writer input.
      return { ...operation, data: { ...operation.data, points: operation.data.points!.map(point => ({ ...point })) }, style: { ...operation.style } }
    }
    if (operation.type === 'eraseCommit' && isNativePDFErase(operation, this.eraseRevision)) {
      const { operationId, operationSequence, originToolEpoch, page, documentRevision, targets } = operation
      return { type: 'eraseCommit', operationId, operationSequence, originToolEpoch, page, documentRevision,
        targets: targets.map(({ drawingId, clientMutationId }) => ({ ...(drawingId === undefined ? {} : { drawingId }), ...(clientMutationId === undefined ? {} : { clientMutationId }) })) }
    }
    throw new Error('다른 자료이거나 잘못된 PDF 지우개 작업입니다.')
  }
  private registerOperation(input: NativePDFOperation): Promise<void> {
    const sequence = input.operationSequence
    const signature = operationFingerprint(input)
    if (sequence <= this.completedOperationSequence && this.completedOperationFingerprints.get(sequence) !== signature) {
      return Promise.reject(new Error('완료된 PDF 작업 순서가 다른 내용에 재사용되었습니다.'))
    }
    let entry = this.operations.get(sequence)
    if (entry && entry.fingerprint !== signature) return Promise.reject(new Error('같은 PDF 작업 순서에 서로 다른 내용이 있습니다.'))
    if (input.type === 'eraseCommit') {
      const receipt = this.eraseReceipts.get(input.operationId)
      if (receipt && receipt.fingerprint !== signature) return Promise.reject(new Error('같은 PDF 삭제 작업에 서로 다른 내용이 있습니다.'))
      if (!receipt) this.eraseReceipts.set(input.operationId, { fingerprint: signature })
    } else {
      const previous = this.operationMutations.get(input.clientMutationId)
      if (previous !== undefined && previous !== sequence) return Promise.reject(new Error('PDF 필기 작업 순서가 변경되었습니다.'))
      this.operationMutations.set(input.clientMutationId, sequence)
    }
    if (sequence <= this.completedOperationSequence) {
      const failure = this.operationFailures.get(sequence)
      return failure ? Promise.reject(failure) : Promise.resolve()
    }
    if (!entry || entry.failed) {
      let resolve!: () => void, reject!: (error: unknown) => void
      const promise = new Promise<void>((yes, no) => { resolve = yes; reject = no })
      // A flush replay can register several jobs before waiting on the drain.
      // The caller still receives the rejecting original promise.
      void promise.catch(() => {})
      entry = { input, fingerprint: signature, promise, resolve, reject, failed: false }
      this.operations.set(sequence, entry)
    }
    this.startOperations()
    return entry.promise
  }
  private startOperations(): void {
    if (this.operationDrain || !this.operations.has(this.completedOperationSequence + 1)) return
    const drain = Promise.resolve().then(async () => {
      while (true) {
        const sequence = this.completedOperationSequence + 1, entry = this.operations.get(sequence)
        if (!entry || entry.failed) return
        try {
          let terminalFailure: Error | undefined
          const operation = this.queue.then(async () => {
            if (entry.input.type === 'stroke') {
              const { type: _, operationSequence: __, ...input } = entry.input
              await this.commit(input)
            } else terminalFailure = await this.commitErase(entry.input)
          })
          this.queue = operation.catch(error => { this.failure = error })
          await operation
          this.operations.delete(sequence); this.completedOperationSequence = sequence
          this.completedOperationFingerprints.set(sequence, entry.fingerprint)
          if (terminalFailure) { this.operationFailures.set(sequence, terminalFailure); entry.reject(terminalFailure) }
          else entry.resolve()
        } catch (error) { entry.failed = true; entry.reject(error); throw error }
      }
    })
    this.operationDrain = drain
    void drain.then(() => {
      if (this.operationDrain === drain) this.operationDrain = null
      if (this.operations.get(this.completedOperationSequence + 1)?.failed === false) this.startOperations()
    }, () => {
      if (this.operationDrain === drain) this.operationDrain = null
      if (this.operations.get(this.completedOperationSequence + 1)?.failed === false) this.startOperations()
    })
  }
  private async commitErase(input: NativePDFEraseInput): Promise<Error | undefined> {
    const receipt = this.eraseReceipts.get(input.operationId)!
    if (!receipt.result) {
      const { targets, operationId, operationSequence, originToolEpoch, page, documentRevision } = input
      const resolvedTargets = targets.map(target => {
        const known = target.clientMutationId === undefined ? undefined : [...this.mutationIdsByDrawing].find(([, mutation]) => mutation === target.clientMutationId)?.[0]
        if (target.clientMutationId !== undefined && known === undefined) throw new Error('먼저 작성한 PDF 필기의 저장 완료를 기다려 주세요.')
        if (target.drawingId && known && target.drawingId !== known) throw new Error('PDF 삭제 대상과 필기 저장 기록이 일치하지 않습니다.')
        const drawingId = target.drawingId ?? known
        if (!drawingId) throw new Error('먼저 작성한 PDF 필기의 저장 완료를 기다려 주세요.')
        return { ...target, drawingId }
      })
      const ids = [...new Set(resolvedTargets.map(target => target.drawingId))]
      let committed = false
      try { committed = await this.writer.remove!(ids) === true }
      catch { /* An IPC failure may have committed. Never repeat the delete. */ }
      receipt.result = { operationId, operationSequence, originToolEpoch, page, documentRevision,
        outcome: committed ? 'committed' : 'unknown', resolvedTargets }
      if (!committed) receipt.failure = new Error('PDF 지우기 저장 결과를 확인하지 못했습니다. 삭제 작업을 다시 실행하지 않고 보존했습니다.')
    }
    const reply = await this.invoke('eraseResult', receipt.result as unknown as Record<string, unknown>) as Partial<NativePDFEraseResult> | null
    if (!reply || reply.operationId !== input.operationId || reply.operationSequence !== input.operationSequence || reply.outcome !== receipt.result.outcome) {
      throw new Error('PDF 지우기 저장 응답이 일치하지 않습니다.')
    }
    // Lost ACK retries need the exact target list; confirmed completion only
    // needs its compact receipt and (for unknown outcomes) terminal failure.
    delete receipt.result
    this.failure = undefined
    return receipt.failure
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
    if (this.flushing) return this.flushing
    const operation = this.flushOnce()
    this.flushing = operation
    try { await operation } finally { if (this.flushing === operation) this.flushing = null }
  }
  private async flushOnce(): Promise<void> {
    const response = await this.invoke('flush') as { pending?: unknown[]; pendingOperations?: unknown[]; throughOperationSequence?: number }
    const pendingOperations = this.nativeInkErase ? (response.pendingOperations ?? []).map(value => this.freezeOperation(value)) : []
    const liveMutations = new Set([...this.operationMutations.keys(), ...pendingOperations.flatMap(operation => operation.type === 'stroke' ? [operation.clientMutationId] : [])])
    await this.replay((response.pending ?? []).filter(value => !value || typeof value !== 'object' || !('clientMutationId' in value) || !liveMutations.has(value.clientMutationId as string)))
    if (this.nativeInkErase) {
      const through = response.throughOperationSequence
      if (!Number.isSafeInteger(through) || through! < 0 || pendingOperations.some(operation => operation.operationSequence > through!)) throw new Error('PDF 저장 완료 작업 순서를 확인하지 못했습니다.')
      for (const operation of pendingOperations) void this.registerOperation(operation).catch(() => {})
      // ACK retry may still be owned by a prior event even when native no
      // longer returns it (its reply was lost after applying the ACK).
      for (const entry of [...this.operations.values()]) if (entry.failed) void this.registerOperation(entry.input).catch(() => {})
      let running: Promise<void> | null
      do { running = this.operationDrain; await running } while (running !== this.operationDrain)
      if (this.completedOperationSequence < through!) throw new Error('PDF 저장 작업 일부가 아직 도착하지 않았습니다. 기록을 보존했습니다.')
      if (this.operationFailures.size) throw this.operationFailures.values().next().value
    }
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
