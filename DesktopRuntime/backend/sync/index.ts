import { emit, env, native } from '../native'
import { join } from '../shims/path'
import { canonical, decodePage, digest, encodePage, type SharedRecord } from './format'
import { snapshotProjection } from './export'
import { createFileJournal } from './journal'
import { planImport, validate } from './import'
import { createLearningProjection } from './learning'
import { preserveConflictAssets } from './conflict-assets'

const comparable = (record: SharedRecord) => canonical({ kind: record.kind, payload: record.payload, deleted: record.deleted })
function mergeInk(base: SharedRecord, local: SharedRecord, remote: SharedRecord): SharedRecord | undefined {
  if (base.deleted || local.deleted || remote.deleted) return undefined
  const a = decodePage(base), b = decodePage(local), c = decodePage(remote)
  if (canonical(a.geometry) !== canonical(b.geometry) || canonical(a.geometry) !== canonical(c.geometry) || a.documentRevision !== c.documentRevision || a.documentRevision !== b.documentRevision) return undefined
  const result = { ...c }; delete result.nativeCache
  for (const [collection, tombstones] of [['objects','deletedObjectIDs'],['highlights','deletedHighlightIDs']]) {
    const original = new Map((a[collection] ?? []).map((v: any) => [v.id,v])), left = new Map((b[collection] ?? []).map((v: any) => [v.id,v])), right = new Map((c[collection] ?? []).map((v: any) => [v.id,v]))
    const removed = new Set([...(a[tombstones] ?? []), ...(b[tombstones] ?? []), ...(c[tombstones] ?? [])]), merged = []
    for (const id of new Set([...left.keys(), ...right.keys()])) {
      const before = original.get(id), l = left.get(id), r = right.get(id)
      if (removed.has(id)) {
        // A concurrent edit and explicit erase require user choice.
        if (before && (l && canonical(l) !== canonical(before) || r && canonical(r) !== canonical(before))) return undefined
        continue
      }
      if (l && r && canonical(l) !== canonical(r) && canonical(l) !== canonical(before) && canonical(r) !== canonical(before)) return undefined
      merged.push(canonical(l) !== canonical(before) ? l ?? r : r ?? l)
    }
    result[collection] = merged.sort((x: any,y: any) => x.id.localeCompare(y.id)); result[tombstones] = [...removed].sort()
  }
  const record = { ...remote, payload: encodePage(result) }; validate(record); return record
}
export function installSync(deps: any) {
  const { db, handlePrivate, materials } = deps
  db.exec(`CREATE TABLE IF NOT EXISTS ipad_sync_projection(id TEXT PRIMARY KEY,kind TEXT NOT NULL,payload_json TEXT NOT NULL,deleted INTEGER NOT NULL,source_json TEXT NOT NULL,baseline_json TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS ipad_sync_conflicts(id TEXT PRIMARY KEY,record_id TEXT NOT NULL,reason TEXT NOT NULL,local_json TEXT,remote_json TEXT NOT NULL,created_at TEXT NOT NULL,resolved_at TEXT);
    CREATE TABLE IF NOT EXISTS ipad_sync_commits(id TEXT PRIMARY KEY);`)
  if(!db.prepare('PRAGMA table_info(ipad_sync_conflicts)').all().some((c:any)=>c.name==='assets_json'))db.exec("ALTER TABLE ipad_sync_conflicts ADD COLUMN assets_json TEXT NOT NULL DEFAULT '[]'")
  const journal = createFileJournal(db)
  const snapshot = async (learning: ReturnType<typeof createLearningProjection>) => { const base=snapshotProjection(deps),extra=await learning.snapshot();const ids=new Set(extra.records.map(r=>r.id));return {records:[...base.records.filter(r=>!ids.has(r.id)),...extra.records],assets:[...base.assets,...extra.assets],sources:new Map([...base.sources,...extra.sources])} }
  const save = (record: SharedRecord, source: any, accepted: SharedRecord = record) => db.prepare(`INSERT INTO ipad_sync_projection(id,kind,payload_json,deleted,source_json,baseline_json) VALUES(?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET kind=excluded.kind,payload_json=excluded.payload_json,deleted=excluded.deleted,source_json=excluded.source_json,baseline_json=excluded.baseline_json`).run(record.id,record.kind,canonical(record.payload),record.deleted?1:0,canonical(source),comparable(accepted))
  const conflict = (local: SharedRecord | undefined, remote: SharedRecord, reason: string,provided=new Map<string,string>()) => {
    const id = digest({ local: local ?? null, remote, reason })
    const assets=[...preserveConflictAssets(db,local,provided),...preserveConflictAssets(db,remote,provided)]
    // The engine retains conflict history permanently. Replaying the same
    // envelopes must not undo a user's resolution; a genuinely new edit has a
    // different digest and therefore creates a new, unresolved conflict.
    db.prepare('INSERT INTO ipad_sync_conflicts(id,record_id,reason,local_json,remote_json,created_at,assets_json) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET assets_json=excluded.assets_json').run(id,remote.id,reason,local ? canonical(local) : null,canonical(remote),new Date().toISOString(),canonical(assets))
    return { id, recordID: remote.id, reason }
  }
  const refresh = async () => {
    for (const c of db.prepare('SELECT id,folder_path FROM courses WHERE deleted_at IS NULL').all()) { materials.invalidateTree(c.id); await materials.tree(c.id) }
    // The desktop file index is rebuildable. Reuse canonical identities after a
    // cache rebuild instead of duplicating every annotation/material remotely.
    db.transaction(() => { for (const mapped of db.prepare("SELECT id,source_json FROM ipad_sync_projection WHERE kind='material'").all()) {
      const source=JSON.parse(mapped.source_json); if (!source.courseID||!source.relPath) continue
      const id=mapped.id.slice('material:'.length), item=db.prepare('SELECT id FROM materials_index WHERE course_id=? AND rel_path=?').get(source.courseID,source.relPath)
      if (item&&item.id!==id&&!db.prepare('SELECT id FROM materials_index WHERE id=?').get(id)) db.prepare('UPDATE materials_index SET id=? WHERE id=?').run(id,item.id)
    } })()
    deps.pdfBindings.reconcileIndex()
  }
  let running = false
  const preflightPause = (request: any): any[] => {
    if (!Array.isArray(request?.records) || !Array.isArray(request.assets ?? [])) throw new Error('Invalid sync import')
    const seen = new Set<string>()
    for (const record of request.records) {
      validate(record)
      if (seen.has(record.id)) throw new Error('Duplicate sync record')
      seen.add(record.id)
      const prior = db.prepare('SELECT kind FROM ipad_sync_projection WHERE id=?').get(record.id)
      if (prior && prior.kind !== record.kind) throw new Error('Sync record kind changed')
    }
    for (const item of request.conflicts ?? []) { validate(item.local); validate(item.remote) }
    return request.records
  }
  const exclusive = (callback: (request: any, learning: ReturnType<typeof createLearningProjection>) => Promise<any>,
    affectedProjects: (request: any) => any[] = () => []) => async (request: any) => {
    if (running) throw new Error('A sync projection operation is already running')
    running = true
    try {
      if (deps.learning?.repo.withExclusivePathAccess) {
        // Stop and settle active AI writes before acquiring the OS lock. Inside
        // the lease, only this scoped repo is allowed to read/write learning JSON.
        const projects = new Map<string, any>()
        for (const record of affectedProjects(request)) {
          const p = record?.payload
          if (record?.kind !== 'artifact' || p?.recordType !== 'desktop-learning-project' || typeof p.courseID !== 'string' || typeof p.rootRelPath !== 'string') continue
          const binding = { courseId: p.courseID, rootRelPath: p.rootRelPath }
          projects.set(JSON.stringify(binding), binding)
        }
        const bindings = [...projects.values()]
        const run = () => deps.learning.repo.withExclusivePathAccess((scopedRepo: any) => callback(request,
          createLearningProjection({ ...deps, learning: { ...deps.learning, repo: scopedRepo, pauseProject: (_binding: any, work: () => Promise<any>) => work() } })))
        const pause = async (index: number): Promise<any> => {
          if (index >= bindings.length) return run()
          const binding = bindings[index]
          if (!db.prepare('SELECT 1 FROM courses WHERE id=?').get(binding.courseId)) return pause(index + 1)
          const existing = await deps.learning.repo.discover(binding.courseId, { includeDeleted: true })
          const project = existing.find((project: any) => project.binding.rootRelPath === binding.rootRelPath)
          if (!project) return pause(index + 1)
          if (project.warning) throw new Error(`학습 원본을 확인한 뒤 동기화를 다시 시도해 주세요: ${project.warning}`)
          return deps.learning.pauseProject(binding, () => pause(index + 1))
        }
        return await pause(0)
      }
      // Fixtures without learning and older host integrations still need the
      // same interprocess material-path lock around the entire projection.
      const token = native<number | null>('fs.lockAcquire', { path: join(env().userDataPath, 'material-path-lock.db') })
      if (token === null) throw new Error('자료 경로 변경 중에는 동기화를 시작할 수 없습니다. 잠시 후 다시 시도합니다.')
      try { return await callback(request, createLearningProjection(deps)) }
      finally { native('fs.lockRelease', { token }) }
    } finally { running = false }
  }
  handlePrivate('nativeSync:export', exclusive(async (_request, learning) => {
    await refresh(); const projected = await snapshot(learning)
    for (const record of projected.records) validate(record)
    // A local document which could not accept a remote version remains visible
    // for review. Do not turn it into a new server edit on the next timer tick:
    // only an explicit resolution releases that record for export again.
    const blocked = new Set(db.prepare('SELECT DISTINCT record_id FROM ipad_sync_conflicts WHERE resolved_at IS NULL').all().map((row:any)=>row.record_id))
    const records = projected.records.filter(record=>!blocked.has(record.id))
    db.transaction(() => { for (const record of records) save(record,projected.sources.get(record.id) ?? {}) })()
    return { records, assets: projected.assets }
  }))
  const importRecords = async (request: any, force: boolean, learning: ReturnType<typeof createLearningProjection>) => {
    if (!Array.isArray(request.records) || !Array.isArray(request.assets ?? [])) throw new Error('Invalid sync import')
    const seen = new Set<string>()
    const assets = new Map<string,string>((request.assets ?? []).map((a: any) => [a.sha256,a.path]))
    for (const record of request.records) { validate(record); if (seen.has(record.id)) throw new Error('Duplicate sync record'); seen.add(record.id)
      const prior = db.prepare('SELECT kind FROM ipad_sync_projection WHERE id=?').get(record.id); if (prior && prior.kind !== record.kind) throw new Error('Sync record kind changed') }
    // Engine conflicts preserve both complete envelopes before projection can
    // materialize the accepted server version over current desktop files.
    for (const item of request.conflicts ?? []) { validate(item.local); validate(item.remote); conflict(item.local,item.remote,'Concurrent edits from another device',assets) }
    await refresh(); const current = new Map((await snapshot(learning)).records.map(record => [record.id, record]))
    const order: Record<string,number> = { course:0,material:1,note:2,drawing:3,task:4,recording:5 }, priority = (r:any) => r.kind==='artifact'&&r.payload.recordType==='desktop-course-group'?-1:r.payload.recordType==='desktop-chat-session'?6:r.payload.recordType==='desktop-chat-message'?7:order[r.kind]??9
    const conflicts: any[] = [], changed = new Set<string>(); let applied = 0
    for (let incoming of [...request.records].sort((a,b) => priority(a)-priority(b))) {
      const accepted = incoming
      const local = current.get(incoming.id), mapped = db.prepare('SELECT * FROM ipad_sync_projection WHERE id=?').get(incoming.id)
      if (force && local && (request.reviewedVariants ?? []).every((reviewed: SharedRecord) => comparable(reviewed) !== comparable(local)))
        conflicts.push(conflict(local,incoming,'Local content changed while reviewing the earlier conflict',assets))
      if (local && comparable(local) === comparable(incoming)) { save(incoming,mapped?JSON.parse(mapped.source_json):{}); applied++; continue }
      if (!force && local && comparable(local) !== comparable(incoming) && (!mapped || comparable(local) !== mapped.baseline_json)) {
        const base = mapped ? { id: incoming.id, formatVersion: 1, ...JSON.parse(mapped.baseline_json) } : undefined
        const merged = incoming.kind === 'drawing' && base ? mergeInk(base,local,incoming) : undefined
        if (!merged) { conflicts.push(conflict(local,incoming,'Local content changed after sync export',assets)); continue }
        incoming = merged
      }
      try {
        if (incoming.kind==='artifact'&&incoming.payload.recordType==='desktop-learning-project') {
          await learning.apply(incoming,assets,local,(files,source)=>journal(files,()=>save(incoming,source)))
          changed.add(incoming.payload.courseID);emit('learning:changed',{binding:{courseId:incoming.payload.courseID,rootRelPath:incoming.payload.rootRelPath}});applied++;continue
        }
        const plan = planImport(incoming,deps,assets)
        // CommonSync still contains the accepted remote envelope until the
        // merged result is queued by the next export. Retain that remote base
        // so replay after a crash re-merges local edits instead of erasing them.
        journal(plan.files,() => { plan.apply(); save(incoming,plan.source,accepted) })
        if (plan.courseID) changed.add(plan.courseID); applied++
      } catch (error) { conflicts.push(conflict(local,incoming,String(error instanceof Error ? error.message : error),assets)) }
    }
    for (const courseID of changed) { materials.invalidateTree(courseID); emit('materials:changed',{ courseId:courseID }) }
    if (changed.size) { emit('courses:changed',{}); emit('board:changed',{courseId:null}) }
    if (conflicts.length) emit('sync:conflictsChanged',{count:conflicts.length})
    return { applied, changedCourseIDs:[...changed],conflicts }
  }
  handlePrivate('nativeSync:import',exclusive((request, learning) => importRecords(request, false, learning), preflightPause))
  handlePrivate('nativeSync:conflicts',() => db.prepare('SELECT * FROM ipad_sync_conflicts WHERE resolved_at IS NULL ORDER BY created_at DESC').all().map((r: any) => {
    const local=r.local_json?JSON.parse(r.local_json):null,remote=JSON.parse(r.remote_json),p=(local??remote).payload,mapped=db.prepare('SELECT source_json FROM ipad_sync_projection WHERE id=?').get(r.record_id),source=mapped?JSON.parse(mapped.source_json):{}
    const material=p.materialID?db.prepare('SELECT course_id,rel_path FROM materials_index WHERE id=?').get(p.materialID):undefined
    const board=p.materialID&&!material?db.prepare('SELECT course_id,title FROM whiteboards WHERE id=?').get(p.materialID):undefined
    const courseID=p.courseID??source.courseID??material?.course_id??board?.course_id,course=courseID?db.prepare('SELECT name FROM courses WHERE id=?').get(courseID):undefined
    const title=p.title??p.name??material?.rel_path??board?.title??source.relPath??p.rootRelPath??r.record_id,label=course?`${course.name} · ${title}`:title
    return{id:r.id,recordID:r.record_id,label,reason:r.reason,local,remote,assets:JSON.parse(r.assets_json),createdAt:r.created_at}
  }))
  handlePrivate('nativeSync:restoreConflict',exclusive(async (request, learning) => {
    const item = db.prepare('SELECT * FROM ipad_sync_conflicts WHERE id=? AND resolved_at IS NULL').get(request.conflictID)
    if (!item || !['local','remote'].includes(request.variant)) throw new Error('Conflict or selected variant is unavailable')
    const value = request.variant === 'local' ? item.local_json : item.remote_json
    if (!value) throw new Error('Selected conflict version is unavailable')
    const reviewedVariants=[item.local_json,item.remote_json].filter(Boolean).map(value=>JSON.parse(value))
    const result = await importRecords({ records:[JSON.parse(value)],assets:[...(request.assets ?? []),...JSON.parse(item.assets_json)],reviewedVariants },true,learning)
    if (result.applied === 1) db.prepare('UPDATE ipad_sync_conflicts SET resolved_at=? WHERE id=?').run(new Date().toISOString(),item.id)
    return result
  }, request => {
    const item = db.prepare('SELECT local_json,remote_json FROM ipad_sync_conflicts WHERE id=? AND resolved_at IS NULL').get(request.conflictID)
    if (!item || !['local','remote'].includes(request.variant)) return []
    const selected = request.variant === 'local' ? item.local_json : item.remote_json
    return selected ? preflightPause({ records: [JSON.parse(selected)] }) : []
  }))
}
