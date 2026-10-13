import { env, native } from '../native'
import { existsSync, readFileSync, statSync } from '../shims/fs'
import { basename, extname } from '../shims/path'
import { resolveInsideReal } from '../../upstream/src/main/db/validate'
import { canonical, coordinateSpace, decodePage, digest, encodePage, transformBox, transformShape, type SharedRecord, type SharedAsset } from './format'

export function snapshotProjection(deps: any) {
  const db = deps.db, records: SharedRecord[] = [], assets: SharedAsset[] = [], sources = new Map<string, any>()
  const mapped = new Map<string, any>(db.prepare('SELECT * FROM ipad_sync_projection').all().map((row: any) => [row.id, { ...row, payload: JSON.parse(row.payload_json), source: JSON.parse(row.source_json) }]))
  const add = (id: string, kind: string, payload: any, source: any, deleted = false) => {
    const old = mapped.get(id), merged = { ...(old?.payload ?? {}), ...payload }
    records.push({ id, kind, payload: merged, deleted, formatVersion: 1 }); sources.set(id, source)
    return merged
  }
  const asset = (materialID: string, path: string) => {
    const sha256 = native<string>('fs.sha256', { path }), byteCount = statSync(path).size, originalName = basename(path)
    const extension = extname(path).toLowerCase(), contentType = extension === '.pdf' ? 'application/pdf' : extension === '.wav' ? 'audio/wav' : extension === '.png' ? 'image/png' : extension === '.jpg' || extension === '.jpeg' ? 'image/jpeg' : 'application/octet-stream'
    assets.push({ materialID, sha256, path, originalName, contentType, byteCount }); return { sha256, byteCount }
  }
  const allMaterials = db.prepare('SELECT * FROM materials_index').all(), byPath = new Map<string, any>(allMaterials.map((row: any) => [`${row.course_id}:${row.rel_path}`, row]))
  for (const group of db.prepare('SELECT * FROM course_groups').all()) add(`artifact:course-group:${group.id}`,'artifact',{recordType:'desktop-course-group',id:group.id,name:group.name,sortOrder:group.sort_order,createdAt:group.created_at},{},!!group.deleted_at)
  for (const course of db.prepare('SELECT * FROM courses ORDER BY created_at,id').all()) {
    add(`course:${course.id}`, 'course', { id: course.id, name: course.name, color: course.color,
      desktop: { archived: !!course.archived, sortOrder: course.sort_order, groupID: course.group_id, workspaceKind: course.workspace_kind, createdAt: course.created_at } }, { folder: course.folder_path }, !!course.deleted_at)
    if (course.deleted_at) continue
    if (!existsSync(course.folder_path)) throw new Error(`Sync course folder is unavailable: ${course.name}`)
    for (const item of allMaterials.filter((row: any) => row.course_id === course.id)) {
      const path = resolveInsideReal(course.folder_path, item.rel_path)
      if (item.deleted_at || !existsSync(path)) continue
      const mid = item.id, fileName = basename(item.rel_path), extension = extname(fileName).toLowerCase()
      const kind = extension === '.pdf' ? 'pdf' : ['.md', '.markdown'].includes(extension) ? 'note' : ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.heic'].includes(extension) ? 'image' : 'file'
      const revision = asset(mid, path), source = { courseID: course.id, relPath: item.rel_path, path, hash: revision.sha256 }
      add(`material:${mid}`, 'material', { id: mid, courseID: course.id, title: fileName.slice(0, fileName.length - extension.length), fileName, revision: revision.sha256, kind,
        byteCount: revision.byteCount, createdAt: item.created_at, desktop: { relPath: item.rel_path } }, source)
      if (kind === 'note') add(`note:${mid}`, 'note', { materialID: mid, markdown: readFileSync(path, 'utf8') }, source)
      if (kind !== 'pdf') continue
      const drawings = db.prepare('SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=?').all(course.id, item.rel_path)
      const annotations = db.prepare('SELECT * FROM annotations WHERE course_id=? AND rel_path=?').all(course.id, item.rel_path)
      const prefix = `drawing:${mid}:${revision.sha256}:`
      const pages = new Set<number>([...drawings, ...annotations].map((row: any) => row.page))
      for (const id of mapped.keys()) if (id.startsWith(prefix)) pages.add(Number(id.slice(prefix.length)))
      if (!pages.size) continue
      const geometries = native<any[]>('pdf.geometry', { path })
      for (const page of [...pages].sort((a, b) => a - b)) {
        const g = geometries.find(geometry => geometry.page === page)
        if (!g) throw new Error(`Sync ink page ${page} is missing from PDF`)
        const geometry = { cropX: g.cropBox.x, cropY: g.cropBox.y, width: g.cropBox.width, height: g.cropBox.height, rotation: g.rotation }
        const prior = mapped.get(prefix + page), previous = prior ? decodePage(prior) : undefined
        const objects = drawings.filter((row: any) => row.page === page && !row.deleted_at).map((row: any) => {
          const result = transformShape({ id: row.id, kind: row.kind, data: JSON.parse(row.data_json), style: JSON.parse(row.style_json), createdAt: row.created_at, updatedAt: row.updated_at }, geometry)
          if (result.data.image) { const image = byPath.get(`${course.id}:${result.data.image.relPath}`); if (!image) throw new Error('Sync ink image source is missing'); result.data.image.assetId = image.id }
          return result
        })
        const highlights = annotations.filter((row: any) => row.page === page && !row.deleted_at).map((row: any) => ({ id: row.id, ...JSON.parse(row.anchor_json), rects: JSON.parse(row.rects_json).map((rect: any) => transformBox(rect, g.rotation)), color: row.color, comment: row.comment, createdAt: row.created_at, updatedAt: row.updated_at }))
        const tombstones = (collection: string, deletedKey: string, rows: any[]) => [...new Set<string>([...(previous?.[deletedKey] ?? []), ...rows.filter(row => row.page === page && row.deleted_at).map(row => row.id), ...(previous?.[collection] ?? []).filter((old: any) => !(collection === 'objects' ? objects : highlights).some((current: any) => current.id === old.id)).map((old: any) => old.id)])].sort()
        const portable = { schemaVersion: 1, materialID: mid, documentRevision: revision.sha256, page, coordinateSpace, geometry, objects, highlights,
          deletedObjectIDs: tombstones('objects', 'deletedObjectIDs', drawings), deletedHighlightIDs: tombstones('highlights', 'deletedHighlightIDs', annotations) }
        add(prefix + page, 'drawing', encodePage(portable), { ...source, geometry })
      }
    }
  }
  for (const row of db.prepare('SELECT * FROM board_tasks').all()) add(`task:${row.id}`, 'task', { id: row.id, courseID: row.course_id, title: row.title, completed: row.status === 'done', due: row.due_at ?? null,
    desktop: { notes: row.notes, status: row.status, kind: row.kind, color: row.color, startAt: row.start_at, dueAt: row.due_at, allDay: !!row.all_day, sortOrder: row.sort_order, createdAt: row.created_at } }, {}, !!row.deleted_at)
  for (const board of db.prepare('SELECT * FROM whiteboards').all()) {
    const mid = board.id, revision = mapped.get(`material:${mid}`)?.payload.revision ?? `whiteboard-${mid}`
    add(`material:${mid}`,'material',{id:mid,courseID:board.course_id,title:board.title,fileName:'canvas.json',kind:'whiteboard',revision,createdAt:board.created_at,
      desktop:{background:board.background,surface:board.surface,pageCount:board.page_count,sortOrder:board.sort_order}},{courseID:board.course_id,whiteboard:true},!!board.deleted_at)
    if (board.deleted_at) continue
    const rows = db.prepare('SELECT * FROM whiteboard_local_shapes WHERE board_id=?').all(mid)
    const pages = new Set<number>(rows.map((r:any) => r.page)), prefix = `drawing:${mid}:${revision}:`
    for (const key of mapped.keys()) if (key.startsWith(prefix)) pages.add(Number(key.slice(prefix.length)))
    for (const page of pages) {
      const prior = mapped.get(prefix+page), previous = prior ? decodePage(prior) : undefined
      const geometry = previous?.geometry ?? {cropX:0,cropY:0,width:595.28,height:841.89,rotation:0}
      const objects = rows.filter((r:any) => r.page===page && !r.deleted_at).map((r:any) => {
        const object = transformShape({id:r.id,kind:r.kind,data:JSON.parse(r.data_json),style:JSON.parse(r.style_json),createdAt:r.created_at,updatedAt:r.updated_at},geometry)
        if (object.data.image) { const image = byPath.get(`${board.course_id}:${object.data.image.relPath}`); if (!image) throw new Error('Whiteboard image is missing'); object.data.image.assetId=image.id }
        return object
      })
      const active = new Set(objects.map((o:any)=>o.id)), removed = [...new Set([...(previous?.deletedObjectIDs??[]),...rows.filter((r:any)=>r.page===page&&r.deleted_at).map((r:any)=>r.id),...(previous?.objects??[]).filter((o:any)=>!active.has(o.id)).map((o:any)=>o.id)])].sort()
      add(prefix+page,'drawing',encodePage({schemaVersion:1,materialID:mid,documentRevision:revision,page,coordinateSpace,geometry,objects,highlights:[],deletedObjectIDs:removed,deletedHighlightIDs:[]}),{courseID:board.course_id,whiteboard:true,geometry})
    }
  }
  for (const row of db.prepare('SELECT * FROM recording_sessions').all()) {
    const session = JSON.parse(row.payload), id = session.id, c = db.prepare('SELECT * FROM courses WHERE id=?').get(session.courseId)
    if (!c || c.deleted_at || ['recording','paused','processing'].includes(session.status)) continue // Never publish a changing audio stream.
    const path = resolveInsideReal(c.folder_path,session.audioRelPath), revision = asset(`recording:${id}`,path)
    const prior = mapped.get(`recording:${id}`)?.payload
    const segments = db.prepare('SELECT * FROM recording_segments WHERE session_id=? ORDER BY start_sample,id').all(id).map((s:any) => {
      const hash=digest({recording:id,start:s.start_sample,end:s.end_sample,text:s.text})
      return {id:prior?.segments?.find((p:any)=>p.time===s.start_sample/16000&&p.text===s.text)?.id ?? `${hash.slice(0,8)}-${hash.slice(8,12)}-4${hash.slice(13,16)}-a${hash.slice(17,20)}-${hash.slice(20,32)}`,time:s.start_sample/16000,text:s.text,endSample:s.end_sample}
    })
    const anchors = db.prepare('SELECT * FROM recording_anchors WHERE session_id=? ORDER BY rowid').all(id).map((r:any)=>JSON.parse(r.payload)).map((a:any) => ({id:a.id,time:a.sample/16000,materialID:a.relPath ? byPath.get(`${session.courseId}:${a.relPath}`)?.id ?? null : null,page:a.page,desktop:{label:a.label,relPath:a.relPath}}))
    add(`recording:${id}`,'recording',{id,courseID:session.courseId,title:session.title,fileName:`Recordings/${id}.wav`,createdAt:session.createdAt,duration:session.samples/16000,state:session.status==='complete'?'completed':'interrupted',segments,anchors,assetRevision:revision.sha256,byteCount:revision.byteCount,desktop:{session}}, {courseID:session.courseId,path,hash:revision.sha256})
  }
  for (const row of db.prepare('SELECT * FROM favorites').all()) add(`favorite:${row.id}`,'favorite',{id:row.id,courseID:row.course_id,label:row.label,descriptor:JSON.parse(row.descriptor_json),sortOrder:row.sort_order,createdAt:row.created_at},{},!!row.deleted_at)
  for (const s of db.prepare('SELECT * FROM agent_sessions').all()) {
    add(`chat:${s.id}`,'chat',{recordType:'desktop-chat-session',id:s.id,courseID:s.course_id,title:s.title,provider:s.provider,model:s.model,surface:s.surface??'app',reasoningEffort:s.reasoning_effort??null,createdAt:s.created_at,lastUsedAt:s.last_used_at},{},!!s.deleted_at)
    for (const m of db.prepare('SELECT * FROM messages WHERE session_id=?').all(s.id)) {
      const blocks=db.prepare('SELECT * FROM message_blocks WHERE message_id=? ORDER BY ord').all(m.id).map((b:any)=>({id:b.id,order:b.ord,kind:b.kind,payload:JSON.parse(b.payload_json),createdAt:b.created_at,updatedAt:b.updated_at,deletedAt:b.deleted_at}))
      add(`chat:message:${m.id}`,'chat',{recordType:'desktop-chat-message',id:m.id,courseID:m.course_id,sessionID:m.session_id,role:m.role,turnSequence:m.turn_seq,createdAt:m.created_at,updatedAt:m.updated_at,blocks},{},!!m.deleted_at)
    }
  }
  // Preserve record kinds the current renderer does not project yet. They stay
  // available to a newer device and are never interpreted as deleted locally.
  const emitted = new Set(records.map(record => record.id))
  for (const old of mapped.values()) if (!emitted.has(old.id)) {
    const disappeared = ['material', 'note'].includes(old.kind) && old.source?.path && !existsSync(old.source.path)
    records.push({ id: old.id, kind: old.kind, payload: old.payload, deleted: disappeared || !!old.deleted, formatVersion: 1 }); sources.set(old.id, old.source)
  }
  return { records, assets, sources }
}
