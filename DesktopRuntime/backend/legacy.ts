import { native, env } from './native'
import { Buffer } from './shims/buffer'
import { createHash } from './shims/crypto'
import { existsSync, mkdirSync, readFileSync, copyFileSync, statSync } from './shims/fs'
import { join, dirname, extname } from './shims/path'
import { writeFileAtomic } from './shims/atomic-write'
import { assertDrawingData, assertDrawingKind, assertDrawingStyle } from '../upstream/src/main/features/drawingValidation'
import { copyLegacyRecording } from './legacy-recording'

const version = 'native-to-desktop-v1'
const coordinateSpace = 'unrotated-crop-box-top-left-normalized'
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const hash = (bytes: string | Uint8Array) => createHash('sha256').update(bytes).digest('hex') as string
function id(value: unknown): string { if (typeof value !== 'string' || !uuid.test(value)) throw new Error('Legacy record UUID is invalid'); return value }
function name(value: unknown): string { if (typeof value !== 'string' || !value || value === '.' || value === '..' || /[/\\\x00]/.test(value)) throw new Error('Legacy file name is unsafe'); return value }
function point(x: number, y: number, rotation: number) {
  switch ((360 - rotation) % 360) { case 0: return { x, y }; case 90: return { x: y, y: 1 - x }; case 180: return { x: 1 - x, y: 1 - y }; case 270: return { x: 1 - y, y: x }; default: throw new Error('Legacy PDF rotation is unsupported') }
}
function box(value: any, rotation: number) {
  const a = point(value.x, value.y, rotation), b = point(value.x + value.width, value.y + value.height, rotation)
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) }
}
function shape(source: any, geometry: any, materialPaths: Map<string, any>) {
  const result = structuredClone(source), rotation = geometry.rotation
  for (const p of result.data.points ?? []) Object.assign(p, point(p.x, p.y, rotation))
  if (result.data.box) result.data.box = box(result.data.box, rotation)
  if (rotation === 90 || rotation === 270) result.style.width *= geometry.width / geometry.height
  if (result.data.image?.assetId) {
    const image = materialPaths.get(result.data.image.assetId)
    if (!image) throw new Error('Legacy drawing image asset is missing')
    result.data.image.relPath = image.relPath; delete result.data.image.assetId; delete result.data.image.storage
  }
  // Validate with the exact desktop domain rules. No unsupported object is
  // silently omitted, simplified or converted to a raster image.
  assertDrawingKind(result.kind); assertDrawingData(result.data, result.kind, { allowClip: true }); assertDrawingStyle(result.style)
  return result
}
export function migrateLegacy(db: any) {
  db.exec(`CREATE TABLE IF NOT EXISTS ipad_legacy_archive(record_id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL, envelope_json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS ipad_legacy_migrations(version TEXT PRIMARY KEY, report_json TEXT NOT NULL);`)
  const previous = db.prepare('SELECT report_json FROM ipad_legacy_migrations WHERE version=?').get(version)
  if (previous) return JSON.parse(previous.report_json)
  const snapshot = native<{ records: any[]; pending: any[] }>('legacy.snapshot')
  const selected = new Map<string, any>()
  for (const record of snapshot.records) {
    if (selected.has(record.id)) throw new Error('Duplicate legacy identity')
    selected.set(record.id, record)
  }
  // The read-only native provider excludes already-receipted journal entries.
  for (const record of snapshot.pending) selected.set(record.id, { ...record, formatVersion: 1, revision: 0, deleted: false })
  const records = [...selected.values()]
  if (!records.length) return { version, records: 0, courses: 0, materials: 0, objects: 0, highlights: 0, archivedKinds: [] }
  for (const record of records) if (record.formatVersion !== 1 || !record.payload || typeof record.payload !== 'object') throw new Error(`Unsupported legacy envelope: ${record.id}`)
  const now = new Date().toISOString(), archiveBytes = JSON.stringify(snapshot), sourceHash = hash(archiveBytes)
  const recovery = join(env().userDataPath, 'MigrationRecovery', sourceHash)
  mkdirSync(recovery, { recursive: true }); writeFileAtomic(join(recovery, 'legacy-snapshot.json'), archiveBytes)
  const live = records.filter(record => !record.deleted), ofKind = (kind: string) => live.filter(record => record.kind === kind)
  const courses = new Map<string, any>(), materials = new Map<string, any>(), files: any[] = [], rows: { table: string; value: any }[] = []
  const add = (table: string, value: any) => rows.push({ table, value })
  for (const record of ofKind('course')) {
    const p = record.payload, courseID = id(p.id), folder = join(env().dataRoot, 'iPad', courseID)
    if (db.prepare('SELECT id FROM courses WHERE id=?').get(courseID)) throw new Error('Legacy course ID already exists without a migration receipt')
    courses.set(courseID, { ...p, folder }); mkdirSync(folder, { recursive: true })
    add('courses', { id: courseID, name: p.name, slug: `ipad-${courseID}`, color: p.color ?? 'green', folder_path: folder,
      source: 'managed', workspace_kind: 'course', archived: 0, group_id: null, sort_order: courses.size - 1, created_at: now, updated_at: now, deleted_at: null })
  }
  const folders = new Map<string, string>()
  const occupied = new Set<string>()
  const available = (courseID: string, directory: string, proposed: string) => {
    const extension = extname(proposed), stem = proposed.slice(0, proposed.length - extension.length)
    for (let index = 1; index <= 10000; index++) {
      const file = index === 1 ? proposed : `${stem} (${index})${extension}`, rel = directory ? `${directory}/${file}` : file
      const key = `${courseID}/${rel.normalize('NFC').toLowerCase()}`
      if (!occupied.has(key)) { occupied.add(key); return rel }
    }
    throw new Error('Legacy file name collisions exceed the supported limit')
  }
  for (const record of ofKind('artifact')) if (record.payload.recordType === 'material-folder') {
    const p = record.payload, course = courses.get(p.courseID)
    if (!course) throw new Error('Legacy folder course is missing')
    id(p.id)
    const rel = available(p.courseID, '', name(p.title)); folders.set(p.id, rel); mkdirSync(join(course.folder, rel), { recursive: true })
  }
  for (const record of ofKind('material')) {
    const p = record.payload, mid = id(p.id), course = courses.get(p.courseID)
    if (!course) throw new Error('Legacy material course is missing')
    const fileName = name(p.fileName), folder = p.folderID ? folders.get(p.folderID) : ''
    if (p.folderID && !folder) throw new Error('Legacy material folder is missing')
    // Native notes use the internal filename "note.md"; retain their actual
    // visible title. Other materials retain the user's imported filename.
    const visibleName = p.kind === 'note' ? `${name(p.title).replace(/\.md$/i, '')}.md` : fileName
    const relPath = available(p.courseID, folder ?? '', visibleName), target = join(course.folder, relPath)
    materials.set(mid, { ...p, relPath, target })
    if (p.kind === 'whiteboard') {
      add('whiteboards', { id: mid, course_id: p.courseID, title: p.title, sort_order: materials.size - 1, created_at: p.createdAt ?? now,
        updated_at: now, deleted_at: null, background: 'blank', surface: 'light', page_count: 1, added_at: Date.now() })
      continue
    }
    let bytes: Uint8Array | undefined, source: string | undefined, byteCount: number, expectedHash: string
    if (p.kind === 'note') {
      const record = selected.get(`note:${mid}`)
      if (!record || record.deleted || typeof record.payload.markdown !== 'string') throw new Error('Legacy note content is missing')
      bytes = Buffer.from(record.payload.markdown); byteCount = bytes.length; expectedHash = hash(bytes)
    } else {
      if (typeof p.revision !== 'string' || !/^[0-9a-f]{64}$/.test(p.revision)) throw new Error('Legacy asset revision is invalid')
      const versioned = join(env().legacyDataPath, 'Materials', mid, hash(p.revision), fileName)
      const older = join(env().legacyDataPath, 'Materials', mid, fileName); source = existsSync(versioned) ? versioned : older
      byteCount = statSync(source).size; expectedHash = p.revision
      if (p.byteCount !== undefined && byteCount !== p.byteCount || native('fs.sha256', { path: source }) !== expectedHash) throw new Error(`Legacy asset hash mismatch: ${mid}`)
    }
    files.push({ target, bytes, source, expectedHash })
    add('materials_index', { id: mid, course_id: p.courseID, rel_path: relPath, kind: p.kind === 'file' ? 'other' : p.kind,
      size: byteCount, mtime: Date.now(), created_at: p.createdAt ?? now, updated_at: now, deleted_at: null })
  }
  // Publish copies only after every asset was read and verified. An interrupted
  // copy can be retried; differing pre-existing targets are never overwritten.
  for (const file of files) {
    mkdirSync(dirname(file.target), { recursive: true })
    if (existsSync(file.target)) { if (native('fs.sha256', { path: file.target }) !== file.expectedHash) throw new Error('Migration target changed; preserved both versions') }
    else if (file.source) copyFileSync(file.source, file.target, 1)
    else writeFileAtomic(file.target, file.bytes)
    if (native('fs.sha256', { path: file.target }) !== file.expectedHash) throw new Error('Migration copied asset verification failed')
  }
  let recordingCount = 0
  for (const record of ofKind('recording')) {
    const p = record.payload, rid = id(p.id), course = courses.get(p.courseID)
    if (!course || p.fileName !== `Recordings/${rid}.wav`) throw new Error('Legacy recording course or path is invalid')
    const source = join(env().legacyDataPath, p.fileName), sourceHash = native('fs.sha256', { path: source })
    if (p.assetRevision && p.assetRevision !== sourceHash || p.byteCount !== undefined && p.byteCount !== statSync(source).size) throw new Error('Legacy recording revision does not match the audio')
    const relative = available(p.courseID, '녹음', name(p.title)), audioRelPath = `${relative}/audio.wav`
    const samples = copyLegacyRecording(source, join(course.folder, audioRelPath))
    const segments = [...(p.segments ?? [])].sort((a, b) => a.time - b.time)
    const session = { id: rid, courseId: p.courseID, title: p.title, modelId: 'zipformer-ko', createdAt: p.createdAt ?? now,
      status: p.state === 'completed' ? 'complete' : 'interrupted', audioRelPath, samples,
      transcribedSamples: segments.length ? samples : 0, nextSequence: 0, error: null }
    add('recording_sessions', { id: rid, course_id: p.courseID, created_at: session.createdAt, payload: JSON.stringify(session) })
    for (let index = 0; index < segments.length; index++) {
      const segment = segments[index], start = Math.min(samples, Math.max(0, Math.round(segment.time * 16000)))
      const end = Math.min(samples, Math.max(start, Math.round((segments[index + 1]?.time ?? samples / 16000) * 16000)))
      add('recording_segments', { session_id: rid, start_sample: start, end_sample: end, text: segment.text })
    }
    for (const anchor of p.anchors ?? []) {
      const target = materials.get(anchor.materialID)
      if (!target || target.courseID !== p.courseID) throw new Error('Legacy recording anchor material is missing')
      const value = { id: id(anchor.id), sample: Math.min(samples, Math.max(0, Math.round(anchor.time * 16000))), label: target.title,
        relPath: target.relPath, page: anchor.page ?? null }
      add('recording_anchors', { id: value.id, session_id: rid, payload: JSON.stringify(value) })
    }
    recordingCount++
  }
  let objects = 0, highlights = 0, historicalPages = 0
  const usedObjectIDs = new Set<string>()
  for (const record of ofKind('drawing')) {
    const wrapper = record.payload, page = JSON.parse(Buffer.from(wrapper.data, 'base64').toString()), material = materials.get(page.materialID)
    if (!material || page.schemaVersion !== 1 || page.coordinateSpace !== coordinateSpace) throw new Error('Legacy drawing format or material is unavailable')
    if (page.materialID !== wrapper.materialID || page.documentRevision !== wrapper.documentRevision || page.page !== wrapper.page) throw new Error('Legacy drawing wrapper mismatch')
    if (material.revision !== page.documentRevision) { historicalPages++; continue } // Retained in snapshot/archive, never attached to another revision.
    const geometry = page.geometry
    if (!(geometry.width > 0 && geometry.height > 0) || ![0, 90, 180, 270].includes(geometry.rotation) || !Number.isInteger(page.page) || page.page < 1) throw new Error('Legacy page geometry is invalid')
    if (material.kind !== 'whiteboard') {
      const actual = native<any[]>('pdf.geometry', { path: material.target }).find(p => p.page === page.page)
      if (!actual || actual.rotation !== geometry.rotation || ['x', 'y', 'width', 'height'].some((key, index) => Math.abs(actual.cropBox[key] - [geometry.cropX, geometry.cropY, geometry.width, geometry.height][index]) > 0.001)) throw new Error('Legacy ink PDF geometry does not match its document')
    }
    const deleted = new Set(page.deletedObjectIDs ?? []), deletedHighlights = new Set(page.deletedHighlightIDs ?? [])
    for (const original of page.objects) {
      if (deleted.has(original.id)) continue
      const converted = shape(original, geometry, materials)
      if (usedObjectIDs.has(converted.id)) throw new Error('Duplicate legacy drawing object ID')
      usedObjectIDs.add(converted.id)
      const value = { id: converted.id, kind: converted.kind, data_json: JSON.stringify(converted.data), style_json: JSON.stringify(converted.style),
        created_at: converted.createdAt, updated_at: converted.updatedAt, deleted_at: null, page: page.page }
      if (material.kind === 'whiteboard') add('whiteboard_local_shapes', { ...value, board_id: material.id })
      else add('pdf_drawings', { ...value, course_id: material.courseID, rel_path: material.relPath })
      objects++
    }
    for (const highlight of page.highlights ?? []) {
      if (deletedHighlights.has(highlight.id)) continue
      if (material.kind === 'whiteboard') throw new Error('Whiteboard text highlights need an explicit migration adapter')
      add('annotations', { id: highlight.id, course_id: material.courseID, rel_path: material.relPath, page: page.page, color: highlight.color,
        rects_json: JSON.stringify(highlight.rects.map((rect: any) => box(rect, geometry.rotation))),
        anchor_json: JSON.stringify({ quote: highlight.quote, prefix: highlight.prefix ?? '', suffix: highlight.suffix ?? '' }), comment: highlight.comment ?? null,
        created_at: highlight.createdAt, updated_at: highlight.updatedAt ?? highlight.createdAt, deleted_at: null }); highlights++
    }
  }
  for (const record of ofKind('task')) {
    const p = record.payload
    if (!courses.has(p.courseID)) throw new Error('Legacy task course is missing')
    add('board_tasks', { id: id(p.id), course_id: p.courseID, title: p.title, notes: '', status: p.completed ? 'done' : 'todo', due_at: p.due ?? null,
      start_at: null, all_day: 0, kind: 'task', color: 'none', sort_order: 0, created_at: now, updated_at: now, deleted_at: null })
  }
  const projected = new Set(['course', 'material', 'note', 'drawing', 'task', 'workspace', 'recording'])
  const archivedKinds = [...new Set(live.filter(record => !projected.has(record.kind) && !(record.kind === 'artifact' && record.payload.recordType === 'material-folder')).map(record => record.kind))]
  const report = { version, sourceHash, recoveryPath: recovery, records: records.length, courses: courses.size, materials: materials.size, objects, highlights, recordings: recordingCount, historicalPages, archivedKinds }
  db.transaction(() => {
    for (const record of records) db.prepare('INSERT INTO ipad_legacy_archive VALUES(?,?,?,?)').run(record.id, record.kind, JSON.stringify(record.payload), JSON.stringify(record))
    for (const { table, value } of rows) {
      const keys = Object.keys(value)
      const result = db.prepare(`INSERT INTO ${table} (${keys.join(',')}) VALUES (${keys.map(() => '?').join(',')})`).run(...keys.map(key => value[key]))
      if (value.id === undefined) value.id = result.lastInsertRowid
    }
    for (const { table, value } of rows) if (!db.prepare(`SELECT id FROM ${table} WHERE id=?`).get(value.id)) throw new Error('Legacy row verification failed')
    if (db.prepare('SELECT COUNT(*) n FROM ipad_legacy_archive').get().n !== records.length) throw new Error('Legacy archive count verification failed')
    db.prepare('INSERT INTO ipad_legacy_migrations VALUES(?,?)').run(version, JSON.stringify(report))
  })()
  return report
}
