import type { CreateDrawingInput, Drawing } from '../../upstream/src/shared/types/drawing'

export interface NativePDFIdentity { surfaceId: string; generation: string; courseId: string; relPath: string }
export interface NativePDFViewport { page: number; zoom: number; progress: number; horizontalProgress?: number }
export interface NativePDFEvent { surfaceId: string; generation: string; type: string; payload: Record<string, unknown> }
export interface NativePDFTransport {
  invoke(channel: string, request: Record<string, unknown>): Promise<unknown>
  on(channel: string, listener: (event: NativePDFEvent) => void): () => void
}
export type JournaledDrawingInput = CreateDrawingInput & { clientMutationId: string }
export interface NativePDFDrawingWriter {
  create(input: CreateDrawingInput): Promise<Drawing | null>
  remove?(ids: string[]): Promise<boolean>
  flush?(): Promise<void>
}

export interface NativePDFEraseTarget { drawingId?: string; clientMutationId?: string }
export interface NativePDFEraseInput {
  operationId: string
  operationSequence: number
  originToolEpoch: number
  page: number
  documentRevision: string
  targets: NativePDFEraseTarget[]
}
export type NativePDFOperation = (JournaledDrawingInput & { type: 'stroke'; operationSequence: number }) |
  (NativePDFEraseInput & { type: 'eraseCommit' })
export interface NativePDFEraseResult extends Omit<NativePDFEraseInput, 'targets'> {
  outcome: 'committed' | 'unknown'
  resolvedTargets: NativePDFEraseTarget[]
}

export function isNativePDFErase(value: unknown, revision: string): value is NativePDFEraseInput {
  if (!value || typeof value !== 'object') return false
  const input = value as Partial<NativePDFEraseInput>
  const integer = (number: unknown): number is number => typeof number === 'number' && Number.isSafeInteger(number) && number > 0
  const uuid = (id: unknown): id is string => typeof id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)
  const savedId = (id: unknown): id is string => {
    if (typeof id !== 'string' || !id) return false
    for (let index = 0; index < id.length; index++) {
      const unit = id.charCodeAt(index)
      if (unit >= 0xd800 && unit <= 0xdbff) {
        const next = id.charCodeAt(++index)
        if (!(next >= 0xdc00 && next <= 0xdfff)) return false
      } else if (unit >= 0xdc00 && unit <= 0xdfff) return false
    }
    return true
  }
  const ids = new Set<string>(), mutations = new Set<string>()
  return uuid(input.operationId) && integer(input.operationSequence) && typeof input.originToolEpoch === 'number'
    && Number.isSafeInteger(input.originToolEpoch) && input.originToolEpoch >= 0 && integer(input.page)
    && input.documentRevision === revision && /^[0-9a-f]{64}$/i.test(revision)
    && Array.isArray(input.targets) && input.targets.length > 0 && input.targets.length <= 100_000
    && input.targets.every(target => {
      if (!target || typeof target !== 'object' || Array.isArray(target)) return false
      const { drawingId, clientMutationId } = target
      if (drawingId === undefined && clientMutationId === undefined) return false
      if (drawingId !== undefined) {
        if (!savedId(drawingId) || ids.has(drawingId)) return false
        ids.add(drawingId)
      }
      if (clientMutationId !== undefined) {
        if (!uuid(clientMutationId) || mutations.has(clientMutationId)) return false
        mutations.add(clientMutationId)
      }
      return true
    })
}

export function isJournaledDrawing(value: unknown, identity: Pick<NativePDFIdentity, 'courseId' | 'relPath'>): value is JournaledDrawingInput {
  if (!value || typeof value !== 'object') return false
  const input = value as Partial<JournaledDrawingInput>
  return input.courseId === identity.courseId && input.relPath === identity.relPath
    && typeof input.clientMutationId === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input.clientMutationId)
    && Number.isInteger(input.page) && input.page! > 0 && ['ink', 'highlighter'].includes(input.kind ?? '')
    && (input.documentRevision === undefined || typeof input.documentRevision === 'string' && /^[0-9a-f]{64}$/i.test(input.documentRevision))
    && (input.data?.inkVersion === 2 || input.data?.inkVersion === 3 || input.data?.inkVersion === 4 || input.data?.inkVersion === 5) && Array.isArray(input.data.points) && input.data.points.length > 0
    && input.data.points.length <= 250_000 && input.data.points.every(point => !!point && typeof point === 'object'
      && [point.x, point.y, point.p].every(n => Number.isFinite(n) && n >= 0 && n <= 1)
      && [point.t, point.tiltX, point.tiltY].every(n => n === undefined || Number.isFinite(n))
      && (point.t === undefined || point.t >= 0))
    && !!input.style && typeof input.style.color === 'string' && Number.isFinite(input.style.width) && input.style.width > 0
    && Number.isFinite(input.style.opacity) && input.style.opacity >= 0 && input.style.opacity <= 1
}
