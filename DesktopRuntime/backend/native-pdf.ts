import { ValidationError } from '../upstream/src/main/db/errors'
import { requireId, requireInt, requireNonEmptyString } from '../upstream/src/main/db/validate'
import { assertDrawingData, assertDrawingKind, assertDrawingStyle } from '../upstream/src/main/features/drawingValidation'
export { createPDFDocumentBindings, createBoundPDFRepositories } from '../upstream/src/main/features/pdf/pdfDocumentBinding'

interface ReceiptDatabase { prepare(sql: string): { get(...values: unknown[]): unknown } }
export type NativePDFMutationStatus = { status: 'missing' } | { status: 'live' | 'deleted'; drawingId: string }
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Read-only recovery. An immutable receipt proves that this exact operation
 * committed, even when Undo subsequently tombstoned or moved its drawing.
 * Never call create here: recovery must not resurrect data or add undo items. */
export function nativePDFMutationStatus(db: ReceiptDatabase, value: unknown): NativePDFMutationStatus {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new ValidationError('Invalid native PDF mutation')
  const input = value as Record<string, unknown>
  const operationID = input.clientMutationId
  if (typeof operationID !== 'string' || !uuid.test(operationID)) throw new ValidationError('clientMutationId must be a UUID')
  const courseId = requireId(input.courseId, 'courseId')
  const relPath = requireNonEmptyString(input.relPath, 'relPath')
  if (relPath.startsWith('/') || relPath.includes('\\') || relPath.split('/').some(part => part === '..' || part === '.') || /[\u0000-\u001f]/.test(relPath)) throw new ValidationError('Invalid native PDF relative path')
  const page = requireInt(input.page, 'page', 1)
  const kind = assertDrawingKind(input.kind, ['ink', 'highlighter'])
  const data = assertDrawingData(input.data, kind), style = assertDrawingStyle(input.style)
  if (data.inkVersion !== 2 && data.inkVersion !== 3) throw new ValidationError('Native PDF mutation requires ink version 2 or 3')
  const documentRevision = input.documentRevision
  if (typeof documentRevision !== 'string' || !/^[0-9a-f]{64}$/.test(documentRevision)) throw new ValidationError('documentRevision must be a SHA-256 digest')
  // This exact canonical field order is shared with createDrawingsRepo. Raw
  // JSON order/extra fields never alter identity; validators normalize both.
  const fingerprint = JSON.stringify({ courseId, relPath, page, kind, data, style, documentRevision })
  const receipt = db.prepare(`SELECT r.request_json, r.drawing_id, d.id AS current_id, d.deleted_at
    FROM drawing_create_receipts r LEFT JOIN pdf_drawings d ON d.id = r.drawing_id
    WHERE r.operation_id = ?`).get(operationID) as { request_json: string; drawing_id: string; current_id: string | null; deleted_at: string | null } | undefined
  if (!receipt) return { status: 'missing' }
  if (receipt.request_json !== fingerprint) throw new ValidationError('A drawing operation cannot be reused for different content')
  if (!uuid.test(receipt.drawing_id) || receipt.current_id !== receipt.drawing_id) throw new ValidationError('Committed native PDF drawing is missing; preserve its recovery journal')
  if (receipt.deleted_at === null) return { status: 'live', drawingId: receipt.drawing_id }
  if (typeof receipt.deleted_at === 'string' && receipt.deleted_at.length > 0) return { status: 'deleted', drawingId: receipt.drawing_id }
  throw new ValidationError('Invalid native PDF deletion receipt')
}
