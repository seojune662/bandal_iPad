import { env, native } from '../native'
import { existsSync, mkdirSync, statSync } from '../shims/fs'
import { basename, dirname, extname, join } from '../shims/path'
import { Buffer } from '../shims/buffer'
import { resolveInsideReal } from '../../upstream/src/main/db/validate'
import { assertDrawingData, assertDrawingKind, assertDrawingStyle } from '../../upstream/src/main/features/drawingValidation'
import { coordinateSpace, decodePage, transformBox, transformShape, type SharedRecord } from './format'
import type { FileChange } from './journal'
import { copyLegacyRecording } from '../legacy-recording'

export const kinds = new Set(['course','material','note','drawing','annotation','board','task','calendarEvent','recording','favorite','chat','learningEvent','vocabulary','flashcard','quiz','artifact'])
export function validate(record: SharedRecord) {
  if (!record || typeof record.id !== 'string' || !record.id || record.id.length > 512 || !kinds.has(record.kind) || record.formatVersion !== 1 || typeof record.deleted !== 'boolean' || !record.payload || typeof record.payload !== 'object' || Array.isArray(record.payload) || Buffer.byteLength(JSON.stringify(record.payload)) > 4 * 1024 * 1024) throw new Error('Invalid or oversized sync record')
}
const name = (value: any) => { if (typeof value !== 'string' || !value || /[/\\\x00]/.test(value) || ['.','..'].includes(value)) throw new Error('Unsafe sync filename'); return value }
const identity = (value: any) => { if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,128}$/.test(value)) throw new Error('Invalid sync identity'); return value }
export function planImport(record: SharedRecord, deps: any, assets: Map<string, string>) {
  const db = deps.db, p = record.payload, now = new Date().toISOString(), deleted = record.deleted ? now : null
  const files: FileChange[] = [], changes: (() => void)[] = []; let source: any = {}, courseID: string | undefined
  const row = (table: string, value: any) => { changes.push(() => {
    const keys = Object.keys(value), updates = keys.filter(k => k !== 'id').map(k => `${k}=excluded.${k}`).join(',')
    db.prepare(`INSERT INTO ${table}(${keys.join(',')}) VALUES(${keys.map(() => '?').join(',')}) ON CONFLICT(id) DO UPDATE SET ${updates}`).run(...keys.map(k => value[k]))
  }) }
  const course = (id: string) => { const result = db.prepare('SELECT * FROM courses WHERE id=?').get(id); if (!result || result.deleted_at && !record.deleted) throw new Error('Sync course is unavailable'); courseID = id; return result }
  const material = (id: string) => { const result = db.prepare('SELECT * FROM materials_index WHERE id=?').get(id); if (!result || result.deleted_at) throw new Error('Sync material is unavailable'); return { ...result, path: resolveInsideReal(course(result.course_id).folder_path, result.rel_path) } }
  const asset = (hash: string, bytes?: number) => { const path = assets.get(hash); if (!/^[a-f0-9]{64}$/.test(hash) || !path || !existsSync(path) || native('fs.sha256', { path }) !== hash || bytes !== undefined && statSync(path).size !== bytes) throw new Error('Verified sync asset is unavailable'); return path }
  if (record.kind === 'course') {
    const id = identity(p.id); if (record.id !== `course:${id}` || typeof p.name !== 'string' || !p.name) throw new Error('Invalid course payload')
    const old = db.prepare('SELECT * FROM courses WHERE id=?').get(id), folder = old?.folder_path ?? join(env().dataRoot, 'Synced', id)
    mkdirSync(folder, { recursive: true }); courseID = id; source = { folder }
    row('courses', { id, name: p.name, slug: old?.slug ?? `synced-${id}`, color: p.color ?? 'green', folder_path: folder,
      source: old?.source ?? 'managed', workspace_kind: p.desktop?.workspaceKind ?? old?.workspace_kind ?? 'course', group_id: p.desktop && 'groupID' in p.desktop ? p.desktop.groupID : old?.group_id ?? null,
      archived: p.desktop?.archived ? 1 : 0, sort_order: p.desktop?.sortOrder ?? old?.sort_order ?? 0, created_at: old?.created_at ?? p.desktop?.createdAt ?? now, updated_at: now, deleted_at: deleted })
  } else if (record.kind === 'material') {
    const id = identity(p.id), c = course(p.courseID), old = db.prepare('SELECT * FROM materials_index WHERE id=?').get(id)
    if (record.id !== `material:${id}` || old && old.course_id !== p.courseID) throw new Error('Material identity mismatch')
    if (old && /\.pdf$/i.test(old.rel_path) && p.kind !== 'pdf') throw new Error('A preserved PDF material cannot change its kind')
    const oldBoard = db.prepare('SELECT id FROM whiteboards WHERE id=?').get(id)
    if (p.kind === 'whiteboard' && old || p.kind !== 'whiteboard' && oldBoard) throw new Error('File and whiteboard identities cannot be reused for each other')
    if (p.kind === 'whiteboard') {
      row('whiteboards', { id, course_id: p.courseID, title: p.title, sort_order: p.desktop?.sortOrder ?? 0, created_at: p.createdAt ?? now, updated_at: now, deleted_at: deleted,
        background: p.desktop?.background ?? 'blank', surface: p.desktop?.surface ?? 'light', page_count: p.desktop?.pageCount ?? 1, added_at: null }); source = { courseID: p.courseID, whiteboard: true }
    } else {
      let relPath = old?.rel_path ?? p.desktop?.relPath ?? name(p.fileName)
      let target = resolveInsideReal(c.folder_path, relPath)
      if (!old && existsSync(target)) {
        const extension = extname(relPath), stem = basename(relPath).slice(0, -extension.length || undefined), directory = dirname(relPath)
        for (let i = 2; existsSync(target); i++) { if (i > 10000) throw new Error('Too many material name collisions'); relPath = join(directory, `${stem} (${i})${extension}`); target = resolveInsideReal(c.folder_path, relPath) }
      }
      source = { courseID: p.courseID, relPath, path: target, hash: p.revision }
      if (!record.deleted && old && /\.pdf$/i.test(old.rel_path) && existsSync(target)) {
        const binding = deps.pdfBindings.check({ courseId: p.courseID, relPath: old.rel_path })
        if (binding.documentRevision !== p.revision) throw new Error('PDF replacement conflicts with its preserved drawing revision; import as a separate material')
      }
      if (record.deleted) files.push({ target, remove: true })
      else if (!existsSync(target) || native('fs.sha256', { path: target }) !== p.revision) { const path = asset(p.revision, p.byteCount); files.push({ target, source: path }) }
      row('materials_index', { id, course_id: p.courseID, rel_path: relPath, kind: p.kind === 'file' ? 'other' : p.kind, size: p.byteCount ?? old?.size ?? 0,
        mtime: Date.now(), created_at: old?.created_at ?? p.createdAt ?? now, updated_at: now, deleted_at: deleted })
    }
  } else if (record.kind === 'note') {
    const m = material(identity(p.materialID)); if (typeof p.markdown !== 'string' || record.id !== `note:${p.materialID}`) throw new Error('Invalid note payload')
    if (m.kind !== 'note' || !/\.(md|markdown)$/i.test(m.rel_path)) throw new Error('A note record can only write to its Markdown material')
    source = { courseID: m.course_id, relPath: m.rel_path, path: m.path }
    files.push(record.deleted ? { target: m.path, remove: true } : { target: m.path, text: p.markdown })
  } else if (record.kind === 'drawing') {
    const page = decodePage(record), g = page.geometry
    if (page.schemaVersion !== 1 || page.coordinateSpace !== coordinateSpace || page.materialID !== p.materialID || page.page !== p.page || page.documentRevision !== p.documentRevision || !Number.isInteger(page.page) || page.page < 1 || !g || !(g.width > 0) || !(g.height > 0) || ![0,90,180,270].includes(g.rotation)) throw new Error('Unsupported ink page format')
    const board = db.prepare('SELECT * FROM whiteboards WHERE id=? AND deleted_at IS NULL').get(page.materialID)
    const m = board ? { course_id: board.course_id, rel_path: '', path: '', id: board.id } : material(page.materialID)
    courseID = m.course_id
    if (!board) {
      const binding = deps.pdfBindings.check({ courseId: m.course_id, relPath: m.rel_path, documentRevision: page.documentRevision })
      if (binding.materialID !== page.materialID) throw new Error('Ink belongs to a different material identity')
      const actual = native<any[]>('pdf.geometry', { path: m.path }).find(value => value.page === page.page)
      if (!actual || actual.rotation !== g.rotation || [actual.cropBox.x-g.cropX,actual.cropBox.y-g.cropY,actual.cropBox.width-g.width,actual.cropBox.height-g.height].some(delta => !Number.isFinite(delta) || Math.abs(delta) > .001)) throw new Error('Ink geometry does not match PDF')
    }
    source = { courseID, relPath: m.rel_path, path: m.path, geometry: g }
    const objectIDs = new Set<string>(), table = board ? 'whiteboard_local_shapes' : 'pdf_drawings', deletedIDs = new Set(page.deletedObjectIDs ?? [])
    if (record.deleted) changes.push(() => db.prepare(`UPDATE ${table} SET deleted_at=?,updated_at=? WHERE ${board?'board_id=?':'course_id=? AND rel_path=?'} AND page=?`).run(now,now,...(board?[board.id]:[courseID,m.rel_path]),page.page))
    for (const object of page.objects ?? []) {
      identity(object.id); if (objectIDs.has(object.id)) throw new Error('Duplicate ink object identity'); objectIDs.add(object.id)
      const value = transformShape(object, g, true)
      if (value.data.image?.assetId) { const image = material(value.data.image.assetId); if (image.course_id !== courseID) throw new Error('Ink image crosses course boundary'); value.data.image.relPath = image.rel_path; delete value.data.image.assetId; delete value.data.image.storage }
      assertDrawingKind(value.kind); assertDrawingData(value.data, value.kind, { allowClip: true }); assertDrawingStyle(value.style)
      const old = db.prepare(`SELECT * FROM ${table} WHERE id=?`).get(value.id)
      if (old && (board ? old.board_id !== board.id : old.course_id !== courseID || old.rel_path !== m.rel_path) || old && old.page !== page.page) throw new Error('Ink identity belongs to another page')
      row(table, { id: value.id, ...(board ? { board_id: board.id } : { course_id: courseID, rel_path: m.rel_path }), page: page.page, kind: value.kind,
        data_json: JSON.stringify(value.data), style_json: JSON.stringify(value.style), created_at: value.createdAt ?? now, updated_at: value.updatedAt ?? now, deleted_at: deleted || (deletedIDs.has(value.id) ? now : null) })
    }
    for (const id of deletedIDs) changes.push(() => db.prepare(`UPDATE ${table} SET deleted_at=?,updated_at=? WHERE id=? AND ${board ? 'board_id=?' : 'course_id=? AND rel_path=?'} AND page=?`).run(now, now, id, ...(board ? [board.id] : [courseID,m.rel_path]), page.page))
    if (board && page.highlights?.length) throw new Error('Text highlights are unsupported on whiteboards')
    for (const h of page.highlights ?? []) {
      identity(h.id); const old = db.prepare('SELECT * FROM annotations WHERE id=?').get(h.id)
      if (old && (old.course_id !== courseID || old.rel_path !== m.rel_path || old.page !== page.page)) throw new Error('Highlight identity belongs to another page')
      row('annotations', { id: h.id, course_id: courseID, rel_path: m.rel_path, page: page.page, color: h.color,
        rects_json: JSON.stringify(h.rects.map((r: any) => transformBox(r,g.rotation,true))), anchor_json: JSON.stringify({ quote: h.quote ?? '', prefix: h.prefix ?? '', suffix: h.suffix ?? '' }), comment: h.comment ?? null,
        created_at: h.createdAt ?? now, updated_at: h.updatedAt ?? now, deleted_at: deleted || (page.deletedHighlightIDs?.includes(h.id) ? now : null) })
    }
    for (const id of page.deletedHighlightIDs ?? []) changes.push(() => db.prepare('UPDATE annotations SET deleted_at=?,updated_at=? WHERE id=? AND course_id=? AND rel_path=? AND page=?').run(now,now,id,courseID,m.rel_path,page.page))
  } else if (record.kind === 'task') {
    const id = identity(p.id); if (p.courseID) course(p.courseID)
    if (typeof p.title !== 'string' || record.id !== `task:${id}`) throw new Error('Invalid task payload')
    row('board_tasks', { id, course_id: p.courseID ?? null, title: p.title, notes: p.desktop?.notes ?? '', status: p.completed ? 'done' : p.desktop?.status === 'in-progress' ? 'in-progress' : 'todo',
      kind: p.desktop?.kind ?? 'task', color: p.desktop?.color ?? null, start_at: p.desktop?.startAt ?? null, due_at: p.due ?? p.desktop?.dueAt ?? null, all_day: p.desktop?.allDay ? 1 : 0,
      sort_order: p.desktop?.sortOrder ?? 0, created_at: p.desktop?.createdAt ?? now, updated_at: now, deleted_at: deleted })
  } else if (record.kind === 'favorite') {
    const id = identity(p.id); if (p.courseID) course(p.courseID)
    if (typeof p.label !== 'string' || !p.descriptor || typeof p.descriptor !== 'object') throw new Error('Invalid favorite payload')
    row('favorites',{id,course_id:p.courseID??null,label:p.label,descriptor_json:JSON.stringify(p.descriptor),sort_order:p.sortOrder??0,created_at:p.createdAt??now,updated_at:now,deleted_at:deleted})
  } else if (record.kind === 'artifact' && p.recordType === 'desktop-course-group') {
    row('course_groups',{id:identity(p.id),name:p.name,sort_order:p.sortOrder??0,created_at:p.createdAt??now,updated_at:now,deleted_at:deleted})
  } else if (record.kind === 'chat' && p.recordType === 'desktop-chat-session') {
    const id=identity(p.id);course(p.courseID)
    if(!['claude-code','codex','gemini'].includes(p.provider)||!['app','desktop'].includes(p.surface))throw new Error('Unsupported chat provider or surface')
    const old=db.prepare('SELECT * FROM agent_sessions WHERE id=?').get(id)
    if(old&&old.course_id!==p.courseID)throw new Error('Chat identity belongs to another course')
    // Local CLI resume paths, launch configs, approval policies and grants are
    // intentionally never transferred between devices.
    row('agent_sessions',{id,course_id:p.courseID,title:p.title??null,provider:p.provider,model:p.model??null,surface:p.surface,reasoning_effort:p.reasoningEffort??null,status:old?.status??'idle',last_used_at:p.lastUsedAt??null,created_at:p.createdAt??now,updated_at:now,deleted_at:deleted})
  } else if(record.kind==='chat'&&p.recordType==='desktop-chat-message') {
    const id=identity(p.id);course(p.courseID)
    const session=db.prepare('SELECT * FROM agent_sessions WHERE id=?').get(p.sessionID)
    if(!session||session.course_id!==p.courseID||!['user','assistant'].includes(p.role)||!Number.isInteger(p.turnSequence)||!Array.isArray(p.blocks))throw new Error('Invalid chat message')
    const old=db.prepare('SELECT * FROM messages WHERE id=?').get(id)
    if(old&&(old.course_id!==p.courseID||old.session_id!==p.sessionID))throw new Error('Message identity belongs to another conversation')
    row('messages',{id,course_id:p.courseID,session_id:p.sessionID,role:p.role,turn_seq:p.turnSequence,created_at:p.createdAt??now,updated_at:p.updatedAt??now,deleted_at:deleted})
    const ids=new Set(),orders=new Set()
    for(const block of p.blocks){identity(block.id);if(ids.has(block.id)||orders.has(block.order)||!Number.isInteger(block.order)||block.order<0||typeof block.kind!=='string')throw new Error('Invalid chat block');ids.add(block.id);orders.add(block.order)
      const existing=db.prepare('SELECT message_id FROM message_blocks WHERE id=?').get(block.id);if(existing&&existing.message_id!==id)throw new Error('Chat block belongs to another message')}
    changes.push(()=>db.prepare('DELETE FROM message_blocks WHERE message_id=?').run(id))
    for(const block of p.blocks)row('message_blocks',{id:block.id,message_id:id,ord:block.order,kind:block.kind,payload_json:JSON.stringify(block.payload??null),created_at:block.createdAt??now,updated_at:block.updatedAt??now,deleted_at:block.deletedAt??null})
  } else if (record.kind === 'recording') {
    const id = identity(p.id), c = course(p.courseID), existing = db.prepare('SELECT payload FROM recording_sessions WHERE id=?').get(id), old = existing ? JSON.parse(existing.payload) : undefined
    if (record.id !== `recording:${id}` || old && old.courseId !== p.courseID || p.fileName !== `Recordings/${id}.wav`) throw new Error('Invalid recording identity')
    if (old && ['recording','paused','processing'].includes(old.status)) throw new Error('Recording is active on this device')
    if (record.deleted) throw new Error('Recording deletion requires explicit local removal; original audio retained')
    const input = asset(p.assetRevision,p.byteCount), converted = join(env().userDataPath,'SyncTranscode',`${p.assetRevision}.wav`)
    const samples = copyLegacyRecording(input,converted), relPath = old?.audioRelPath ?? p.desktop?.session?.audioRelPath ?? `녹음/${id}/audio.wav`, target = resolveInsideReal(c.folder_path,relPath)
    files.push({target,source:converted}); source={courseID:p.courseID,path:target,hash:p.assetRevision}
    const session = {...(p.desktop?.session??{}),id,courseId:p.courseID,title:p.title,modelId:p.desktop?.session?.modelId??'zipformer-ko',createdAt:p.createdAt??now,
      status:p.state==='completed'?'complete':'interrupted',audioRelPath:relPath,samples,transcribedSamples:p.segments?.length?samples:0,nextSequence:p.desktop?.session?.nextSequence??0,error:p.desktop?.session?.error??null}
    row('recording_sessions',{id,course_id:p.courseID,created_at:session.createdAt,payload:JSON.stringify(session)})
    changes.push(()=>{db.prepare('DELETE FROM recording_segments WHERE session_id=?').run(id);db.prepare('DELETE FROM recording_anchors WHERE session_id=?').run(id)})
    for (const [index,s] of (p.segments??[]).entries()) {
      if (typeof s.text!=='string'||!Number.isFinite(s.time)||s.time<0) throw new Error('Invalid recording transcript')
      const start=Math.min(samples,Math.round(s.time*16000)),end=Math.min(samples,s.endSample??Math.max(start,Math.round((p.segments[index+1]?.time??samples/16000)*16000)))
      changes.push(()=>db.prepare('INSERT INTO recording_segments(session_id,start_sample,end_sample,text) VALUES(?,?,?,?)').run(id,start,end,s.text))
    }
    for (const a of p.anchors??[]) {
      const m=a.materialID?material(a.materialID):undefined
      if (m&&m.course_id!==p.courseID||!Number.isFinite(a.time)||a.time<0) throw new Error('Invalid recording anchor')
      const anchor={id:identity(a.id),sample:Math.min(samples,Math.round(a.time*16000)),label:a.desktop?.label??'표시',relPath:m?.rel_path??null,page:a.page??null}
      row('recording_anchors',{id:anchor.id,session_id:id,payload:JSON.stringify(anchor)})
    }
  }
  // Unknown/newer payload kinds stay durably available in the projection store.
  return { files, source, courseID, apply: () => changes.forEach(change => change()) }
}
