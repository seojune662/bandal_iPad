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
  flush?(): Promise<void>
}

export function isJournaledDrawing(value: unknown, identity: Pick<NativePDFIdentity, 'courseId' | 'relPath'>): value is JournaledDrawingInput {
  if (!value || typeof value !== 'object') return false
  const input = value as Partial<JournaledDrawingInput>
  return input.courseId === identity.courseId && input.relPath === identity.relPath
    && typeof input.clientMutationId === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(input.clientMutationId)
    && Number.isInteger(input.page) && input.page! > 0 && ['ink', 'highlighter'].includes(input.kind ?? '')
    && (input.documentRevision === undefined || typeof input.documentRevision === 'string' && /^[0-9a-f]{64}$/i.test(input.documentRevision))
    && input.data?.inkVersion === 2 && Array.isArray(input.data.points) && input.data.points.length > 0
    && input.data.points.length <= 250_000 && input.data.points.every(point => !!point && typeof point === 'object'
      && [point.x, point.y, point.p].every(n => Number.isFinite(n) && n >= 0 && n <= 1)
      && [point.t, point.tiltX, point.tiltY].every(n => n === undefined || Number.isFinite(n))
      && (point.t === undefined || point.t >= 0))
    && !!input.style && typeof input.style.color === 'string' && Number.isFinite(input.style.width) && input.style.width > 0
    && Number.isFinite(input.style.opacity) && input.style.opacity >= 0 && input.style.opacity <= 1
}
