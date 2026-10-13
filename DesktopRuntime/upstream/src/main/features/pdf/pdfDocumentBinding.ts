import { randomUUID } from 'node:crypto'
import { assertMaterialPathAvailable } from '../materials/materialPathJournal'
import { ValidationError } from '../../db/errors'
import { requireId, requireNonEmptyString } from '../../db/validate'
import { createDrawingsRepo } from './drawingsRepo'
import { createAnnotationsRepo } from '../annotations/annotationsRepo'

export interface PDFDocumentBinding {
  materialID: string
  documentRevision: string
  evidence: 'receipt' | 'sync' | 'first-observed'
  /** Old path-only drawings cannot prove which bytes preceded this migration. */
  legacyUnverified: boolean
}

/** Every consumer (IPC, exports and tools) shares these guarded repositories.
 * The native revision callback runs only for a genuinely new create receipt;
 * retrying a committed operation retains its original idempotent semantics. */
export function createBoundPDFRepositories(db: any, bindings: ReturnType<typeof createPDFDocumentBindings>) {
  const rawAnnotations = createAnnotationsRepo(db), rawDrawings = createDrawingsRepo(db, {
    documentRevision: (courseId, relPath) => bindings.check({ courseId, relPath }).documentRevision
  })
  const checkRow = (table: 'annotations' | 'pdf_drawings', id: string) => {
    const row = db.prepare(`SELECT course_id,rel_path FROM ${table} WHERE id=?`).get(id)
    if (row) bindings.checkPDF(row.course_id, row.rel_path)
  }
  return {
    annotations: { ...rawAnnotations,
      listForFile: (req: Parameters<typeof rawAnnotations.listForFile>[0]) => { bindings.checkPDF(req.courseId, req.relPath); return rawAnnotations.listForFile(req) },
      create: (req: Parameters<typeof rawAnnotations.create>[0]) => { bindings.checkPDF(req.courseId, req.relPath); return rawAnnotations.create(req) },
      update: (req: Parameters<typeof rawAnnotations.update>[0]) => { checkRow('annotations', req.id); return rawAnnotations.update(req) },
      softDelete: (req: Parameters<typeof rawAnnotations.softDelete>[0]) => { checkRow('annotations', req.id); return rawAnnotations.softDelete(req) }
    },
    drawings: { ...rawDrawings,
      listForFile: (courseId: string, relPath: string) => { bindings.checkPDF(courseId, relPath); return rawDrawings.listForFile(courseId, relPath) },
      create: (req: Parameters<typeof rawDrawings.create>[0]) => { if (req.documentRevision === undefined) bindings.checkPDF(req.courseId, req.relPath); return rawDrawings.create(req) },
      update: (req: Parameters<typeof rawDrawings.update>[0]) => { checkRow('pdf_drawings', req.id); return rawDrawings.update(req) },
      softDelete: (ids: string[]) => { for (const id of ids) checkRow('pdf_drawings', id); return rawDrawings.softDelete(ids) }
    }
  }
}
const sha = /^[0-9a-f]{64}$/
function relativePath(value: unknown): string {
  const path = requireNonEmptyString(value, 'relPath')
  if (path.startsWith('/') || path.includes('\\') || path.split('/').some(part => !part || part === '..' || part === '.') || /[\u0000-\u001f]/.test(path)) throw new ValidationError('Invalid PDF relative path')
  return path
}
const mismatch = () => new ValidationError('PDF 원본이 기존 필기와 다릅니다. 원래 PDF·필기·복구 기록을 보존했으며 새 원본에는 적용하지 않았습니다.')

/** Durable identity is deliberately independent of materials_index, which is a
 * rebuildable search cache. No operation here rewrites a PDF, drawing, receipt,
 * or snapshot. The desktop can use the same service with its file hash reader. */
export function createPDFDocumentBindings(db: any, revisionFor: (courseId: string, relPath: string) => string,
  preserveOriginal?: (courseId: string, relPath: string, revision: string) => void) {
  db.exec(`CREATE TABLE IF NOT EXISTS pdf_document_bindings (
    material_id TEXT PRIMARY KEY, bound_sha TEXT NOT NULL, evidence TEXT NOT NULL,
    legacy_unverified INTEGER NOT NULL, created_at TEXT NOT NULL
  ); CREATE TABLE IF NOT EXISTS pdf_document_aliases (
    course_id TEXT NOT NULL, rel_path TEXT NOT NULL, material_id TEXT NOT NULL UNIQUE,
    PRIMARY KEY(course_id,rel_path), FOREIGN KEY(material_id) REFERENCES pdf_document_bindings(material_id)
  )`)
  const table = (name: string) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name)
  const atPath = (courseId: string, relPath: string) => db.prepare(`SELECT b.* FROM pdf_document_aliases a
    JOIN pdf_document_bindings b ON b.material_id=a.material_id WHERE a.course_id=? AND a.rel_path=?`).get(courseId, relPath)
  const result = (row: any): PDFDocumentBinding => ({ materialID: row.material_id, documentRevision: row.bound_sha, evidence: row.evidence, legacyUnverified: !!row.legacy_unverified })
  const reconcile = (courseId: string, relPath: string, materialID: string) => {
    const item = db.prepare('SELECT id FROM materials_index WHERE course_id=? AND rel_path=?').get(courseId, relPath)
    if (!item || item.id === materialID) return
    const occupied = db.prepare('SELECT course_id,rel_path FROM materials_index WHERE id=?').get(materialID)
    if (occupied) throw new ValidationError('PDF material identity is already assigned to another path')
    db.prepare('UPDATE materials_index SET id=? WHERE id=?').run(materialID, item.id)
  }
  function checkAt(input: { courseId: string; relPath: string; documentRevision?: string }, movedTo?: string): PDFDocumentBinding {
    const courseId = requireId(input.courseId, 'courseId'), relPath = relativePath(input.relPath)
    if (movedTo === undefined) assertMaterialPathAvailable(db, courseId, relPath)
    if (!db.prepare('SELECT id FROM courses WHERE id=? AND deleted_at IS NULL').get(courseId)) throw new ValidationError('PDF course is unavailable')
    if (input.documentRevision !== undefined && (typeof input.documentRevision !== 'string' || !sha.test(input.documentRevision))) throw new ValidationError('documentRevision must be a SHA-256 digest')
    const readablePath = movedTo ?? relPath, current = revisionFor(courseId, readablePath)
    if (!sha.test(current)) throw new ValidationError('PDF revision could not be verified')
    if (input.documentRevision !== undefined && current !== input.documentRevision) throw mismatch()
    // Persist verified historical evidence even on a mismatch. A later launch
    // must not forget the original binding simply because the file was replaced.
    const row = db.transaction(() => {
      let bound = atPath(courseId, relPath)
      if (!bound) {
        const item = db.prepare('SELECT id FROM materials_index WHERE course_id=? AND rel_path=?').get(courseId, relPath)
        const revisions = new Map<string, 'receipt' | 'sync'>()
        if (table('drawing_create_receipts')) for (const receipt of db.prepare(`SELECT r.request_json FROM drawing_create_receipts r
          JOIN pdf_drawings d ON d.id=r.drawing_id WHERE d.course_id=? AND d.rel_path=?`).all(courseId, relPath)) {
          let request: any
          try { request = JSON.parse(receipt.request_json) } catch { throw new ValidationError('Invalid PDF drawing receipt; recovery data was preserved') }
          if (request.documentRevision === undefined) continue
          if (typeof request.documentRevision !== 'string' || !sha.test(request.documentRevision)) throw new ValidationError('Invalid PDF revision in drawing receipt')
          revisions.set(request.documentRevision, 'receipt')
        }
        if (table('ipad_sync_projection')) for (const projection of db.prepare("SELECT payload_json,source_json FROM ipad_sync_projection WHERE kind='drawing'").all()) {
          const payload = JSON.parse(projection.payload_json), source = JSON.parse(projection.source_json)
          if (!(item && payload.materialID === item.id) && !(source.courseID === courseId && source.relPath === relPath)) continue
          if (typeof payload.documentRevision !== 'string' || !sha.test(payload.documentRevision)) throw new ValidationError('Invalid PDF revision in sync history')
          if (!revisions.has(payload.documentRevision)) revisions.set(payload.documentRevision, 'sync')
        }
        if (revisions.size > 1) throw new ValidationError('서로 다른 PDF 원본의 필기 기록이 있습니다. 자료와 필기를 보존했으며 자동으로 합치지 않았습니다.')
        const prior = [...revisions.entries()][0], materialID = item?.id ?? randomUUID()
        if (db.prepare('SELECT material_id FROM pdf_document_bindings WHERE material_id=?').get(materialID)) throw new ValidationError('PDF identity has no matching path alias')
        const hasRows = !!db.prepare('SELECT 1 FROM pdf_drawings WHERE course_id=? AND rel_path=? LIMIT 1').get(courseId, relPath) ||
          !!db.prepare('SELECT 1 FROM annotations WHERE course_id=? AND rel_path=? LIMIT 1').get(courseId, relPath)
        db.prepare('INSERT INTO pdf_document_bindings(material_id,bound_sha,evidence,legacy_unverified,created_at) VALUES(?,?,?,?,?)')
          .run(materialID, prior?.[0] ?? current, prior?.[1] ?? 'first-observed', !prior && hasRows ? 1 : 0, new Date().toISOString())
        db.prepare('INSERT INTO pdf_document_aliases(course_id,rel_path,material_id) VALUES(?,?,?)').run(courseId, relPath, materialID)
        bound = atPath(courseId, relPath)
      }
      reconcile(courseId, relPath, bound.material_id)
      return bound
    })()
    if (row.bound_sha !== current) throw mismatch()
    preserveOriginal?.(courseId, readablePath, current)
    return result(row)
  }
  function repoint(change: { courseId: string; fromRelPath: string; toRelPath: string; isDirectory: boolean }): void {
    const courseId = requireId(change.courseId, 'courseId'), from = relativePath(change.fromRelPath), to = relativePath(change.toRelPath)
    const key = (value: string) => value.normalize('NFC').toLowerCase(), prefix = from.split('/')
    db.transaction(() => {
      const destination = (path: string): string | undefined => {
        const parts = path.split('/'), exact = key(path) === key(from)
        if (exact) return to
        if (change.isDirectory && parts.length > prefix.length && key(parts.slice(0, prefix.length).join('/')) === key(from)) return `${to}/${parts.slice(prefix.length).join('/')}`
        return undefined
      }
      // The first action after an upgrade can be a rename, before any viewer
      // opens. Recover evidence under the old path while reading the already
      // renamed bytes; otherwise sync-only history would become untraceable.
      const existing = db.prepare(`SELECT rel_path FROM pdf_drawings WHERE course_id=?
        UNION SELECT rel_path FROM annotations WHERE course_id=?`).all(courseId, courseId)
      for (const row of existing) {
        const next = destination(row.rel_path)
        if (next && /\.pdf$/i.test(row.rel_path) && !atPath(courseId, row.rel_path)) checkAt({ courseId, relPath: row.rel_path }, next)
      }
      for (const alias of db.prepare('SELECT * FROM pdf_document_aliases WHERE course_id=?').all(courseId)) {
        const next = destination(alias.rel_path)
        if (!next) continue
        const collision = atPath(courseId, next)
        if (collision && collision.material_id !== alias.material_id) throw new ValidationError('PDF rename collides with a preserved document binding')
        // Repoint the rebuildable index as well, so the next scan keeps the
        // identity even before sync has emitted the new source path.
        const target = db.prepare('SELECT id FROM materials_index WHERE course_id=? AND rel_path=?').get(courseId, next)
        if (target && target.id !== alias.material_id) throw new ValidationError('PDF rename collides with another material')
        db.prepare('UPDATE materials_index SET rel_path=? WHERE course_id=? AND rel_path=?').run(next, courseId, alias.rel_path)
        db.prepare('UPDATE pdf_document_aliases SET rel_path=? WHERE course_id=? AND rel_path=?').run(next, courseId, alias.rel_path)
      }
    })()
  }
  return {
    check: (input: { courseId: string; relPath: string; documentRevision?: string }) => checkAt(input), repoint,
    checkPDF(courseId: string, relPath: string): PDFDocumentBinding | undefined {
      if (typeof relPath === 'string' && /\.pdf$/i.test(relPath)) return checkAt({ courseId, relPath })
      return undefined
    },
    reconcileIndex() { db.transaction(() => { for (const row of db.prepare('SELECT * FROM pdf_document_aliases').all()) reconcile(row.course_id, row.rel_path, row.material_id) })() }
  }
}
