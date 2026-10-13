import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as crypto from 'node:crypto'
import * as path from 'node:path'

export async function testSync({ backend, database, environment, runtime, course, note }) {
  const invoke = (name, request) => backend.invokePrivate(`nativeSync:${name}`,request)
  await assert.rejects(backend.invoke('nativeSync:export'), /not connected/)
  const snapshot = await invoke('export',{})
  assert.ok(snapshot.records.length > 0); assert.ok(snapshot.assets.length > 0)
  assert.ok(snapshot.records.every(r => r.kind !== 'workspace'))
  const material = snapshot.records.find(r => r.kind === 'material' && r.payload.courseID === course.id && r.payload.desktop.relPath === note.relPath)
  const original = snapshot.records.find(r => r.id === `note:${material.payload.id}`)
  assert.equal(original.payload.markdown,fs.readFileSync(path.join(course.folderPath,note.relPath),'utf8'))
  const assets = snapshot.assets.map(a => ({sha256:a.sha256,path:a.path}))
  const audio = snapshot.records.find(r=>r.kind==='recording')
  if (audio) {
    const remoteAudio={...audio,payload:{...audio.payload,title:'Remote recorded lecture',segments:audio.payload.segments.map(s=>({...s,text:'동기화된 자막'}))}}
    const audioResult=await invoke('import',{records:[remoteAudio],assets})
    assert.equal(audioResult.applied,1); assert.equal(audioResult.conflicts.length,0)
    const detail=await backend.invoke('recordings:read',{id:audio.payload.id})
    assert.equal(detail.session.title,'Remote recorded lecture'); assert.equal(detail.segments[0].text,'동기화된 자막'); assert.equal(detail.session.samples,16000)
    const afterAudio=await invoke('export',{})
    assert.equal(afterAudio.records.find(r=>r.id===audio.id).payload.segments[0].id,audio.payload.segments[0].id)
  }
  const whiteboard=snapshot.records.find(r=>r.kind==='material'&&r.payload.kind==='whiteboard')
  assert.ok(whiteboard)
  const object={id:crypto.randomUUID(),kind:'ink',data:{points:[{x:.1,y:.2,p:.4},{x:.2,y:.3,p:.8}]},style:{color:'ink',width:.003,opacity:1},createdAt:'2026-10-13T00:00:00Z',updatedAt:'2026-10-13T00:00:00Z'}
  const pageRecord={schemaVersion:1,materialID:whiteboard.payload.id,documentRevision:whiteboard.payload.revision,page:1,coordinateSpace:'unrotated-crop-box-top-left-normalized',geometry:{cropX:0,cropY:0,width:595.28,height:841.89,rotation:0},objects:[object],highlights:[],deletedObjectIDs:[],deletedHighlightIDs:[]}
  const boardInk={id:`drawing:${pageRecord.materialID}:${pageRecord.documentRevision}:1`,kind:'drawing',payload:{materialID:pageRecord.materialID,documentRevision:pageRecord.documentRevision,page:1,data:Buffer.from(JSON.stringify(pageRecord)).toString('base64')},deleted:false,formatVersion:1}
  assert.equal((await invoke('import',{records:[boardInk],assets})).applied,1)
  assert.equal(database.prepare('SELECT id FROM whiteboard_local_shapes WHERE id=?').get(object.id).id,object.id)
  const unchanged = await invoke('import',{records:[original],assets})
  assert.equal(unchanged.applied,1); assert.equal(unchanged.conflicts.length,0)
  const originalMtime=fs.statSync(path.join(course.folderPath,note.relPath)).mtimeMs
  await invoke('import',{records:[original],assets})
  assert.equal(fs.statSync(path.join(course.folderPath,note.relPath)).mtimeMs,originalMtime)
  const local = { ...original,payload:{...original.payload,markdown:'local concurrent note'} }
  const remote = { ...original,payload:{...original.payload,markdown:'remote concurrent note'} }
  fs.writeFileSync(path.join(course.folderPath,note.relPath),local.payload.markdown)
  const collision = await invoke('import',{records:[remote],assets})
  assert.equal(collision.applied,0); assert.equal(collision.conflicts.length,1)
  assert.equal(fs.readFileSync(path.join(course.folderPath,note.relPath),'utf8'),local.payload.markdown)
  const conflicts = await invoke('conflicts',{})
  assert.equal(conflicts[0].local.payload.markdown,local.payload.markdown); assert.equal(conflicts[0].remote.payload.markdown,remote.payload.markdown)
  assert.equal((await invoke('export',{})).records.some(r=>r.id===original.id),false,'unresolved local version must not be sent as a newer server edit')
  fs.writeFileSync(path.join(course.folderPath,note.relPath),'new edit while reviewing conflict')
  const restored = await invoke('restoreConflict',{conflictID:conflicts[0].id,variant:'remote',assets})
  assert.equal(restored.applied,1); assert.equal(fs.readFileSync(path.join(course.folderPath,note.relPath),'utf8'),remote.payload.markdown)
  const laterConflicts=await invoke('conflicts',{})
  assert.equal(laterConflicts.length,1);assert.equal(laterConflicts[0].local.payload.markdown,'new edit while reviewing conflict')
  await invoke('restoreConflict',{conflictID:laterConflicts[0].id,variant:'remote',assets})
  assert.equal((await invoke('conflicts',{})).length,0)
  // Core conflicts are durable history and get replayed on every exchange.
  const history={local,remote}
  await invoke('import',{records:[],assets,conflicts:[history]})
  const engineConflict=(await invoke('conflicts',{})).find(c=>c.reason==='Concurrent edits from another device')
  await invoke('restoreConflict',{conflictID:engineConflict.id,variant:'remote',assets})
  await invoke('import',{records:[],assets,conflicts:[history]})
  assert.equal((await invoke('conflicts',{})).length,0,'resolved engine history must stay resolved on replay')
  assert.equal((await invoke('export',{})).records.some(r=>r.id===original.id),true,'explicit resolution releases export')
  // Files restored when SQLite fails after a staged replacement.
  await invoke('export',{})
  database.exec("CREATE TRIGGER fail_sync_test BEFORE UPDATE ON ipad_sync_projection BEGIN SELECT RAISE(ABORT, 'simulated commit failure'); END")
  const failed = await invoke('import',{records:[{...remote,payload:{...remote.payload,markdown:'must rollback'}}],assets})
  assert.equal(failed.applied,0); assert.match(failed.conflicts[0].reason,/simulated commit failure/)
  assert.equal(fs.readFileSync(path.join(course.folderPath,note.relPath),'utf8'),remote.payload.markdown)
  database.exec('DROP TRIGGER fail_sync_test')
  // Malformed envelopes fail before any record in a batch is touched.
  const before = database.prepare('SELECT COUNT(*) n FROM ipad_sync_projection').get().n
  await assert.rejects(invoke('import',{records:[remote,{...remote,id:'bad',formatVersion:2}],assets}),/Invalid/)
  assert.equal(database.prepare('SELECT COUNT(*) n FROM ipad_sync_projection').get().n,before)
  // Ink merges new distinct IDs and retains erasures in normalized coordinates.
  const fresh = await invoke('export',{}), ink = fresh.records.find(r => r.kind === 'drawing' && r.payload.materialID !== undefined && r.id.includes(':') && r.payload.documentRevision === fresh.records.find(m => m.kind === 'material' && m.payload.courseID === course.id && m.payload.kind === 'pdf')?.payload.revision)
  assert.ok(ink)
  const page = JSON.parse(Buffer.from(ink.payload.data,'base64')), remoteObject = {...page.objects[0],id:crypto.randomUUID()}
  const target = database.prepare('SELECT course_id,rel_path FROM materials_index WHERE id=?').get(ink.payload.materialID)
  const localObject = await backend.invoke('drawings:create',{courseId:target.course_id,relPath:target.rel_path,page:1,kind:'ink',data:{points:[{x:.2,y:.3,p:.5},{x:.3,y:.4,p:.7}]},style:{color:'ink',width:.003,opacity:1}})
  const incomingInk = {...ink,payload:{...ink.payload,data:Buffer.from(JSON.stringify({...page,objects:[...page.objects,remoteObject]})).toString('base64')}}
  const merged = await invoke('import',{records:[incomingInk],assets})
  assert.equal(merged.applied,1); assert.equal(merged.conflicts.length,0)
  const shapes = await backend.invoke('drawings:listForFile',{courseId:target.course_id,relPath:target.rel_path})
  assert.ok(shapes.some(s => s.id === localObject.id)); assert.ok(shapes.some(s => s.id === remoteObject.id))
  // A crash after three-way merge but before native marker clearing replays
  // the unmerged accepted envelope. Existing local object edits must survive.
  const mergeBase=(await invoke('export',{})).records.find(r=>r.id===ink.id), mergePage=JSON.parse(Buffer.from(mergeBase.payload.data,'base64'))
  const [left,right]=mergePage.objects
  const leftShape=shapes.find(s=>s.id===left.id)
  await backend.invoke('drawings:update',{id:left.id,style:{...leftShape.style,opacity:.4}})
  const remoteEdited={...mergeBase,payload:{...mergeBase.payload,data:Buffer.from(JSON.stringify({...mergePage,objects:mergePage.objects.map(o=>o.id===right.id?{...o,style:{...o.style,opacity:.6}}:o)})).toString('base64')}}
  for(let retry=0;retry<2;retry++) {
    const result=await invoke('import',{records:[remoteEdited],assets})
    assert.equal(result.applied,1);assert.equal(result.conflicts.length,0)
    const current=await backend.invoke('drawings:listForFile',{courseId:target.course_id,relPath:target.rel_path})
    assert.equal(current.find(s=>s.id===left.id).style.opacity,.4,'accepted replay must retain merged local X edit')
    assert.equal(current.find(s=>s.id===right.id).style.opacity,.6,'accepted replay must retain remote Y edit')
  }
  // Native service identities stay stable; assets verified before new material.
  const cid = crypto.randomUUID(), mid = crypto.randomUUID(), bytes = Buffer.from('# imported'), sha256 = crypto.createHash('sha256').update(bytes).digest('hex'), staged = path.join(environment.tempPath,sha256)
  fs.writeFileSync(staged,bytes)
  const records = [{id:`course:${cid}`,kind:'course',payload:{id:cid,name:'Synced',color:'blue'},deleted:false,formatVersion:1},
    {id:`material:${mid}`,kind:'material',payload:{id:mid,courseID:cid,title:'Imported',fileName:'Imported.md',kind:'note',revision:sha256,byteCount:bytes.length},deleted:false,formatVersion:1},
    {id:`note:${mid}`,kind:'note',payload:{materialID:mid,markdown:bytes.toString()},deleted:false,formatVersion:1}]
  const imported = await invoke('import',{records:records.reverse(),assets:[{sha256,path:staged}]})
  assert.equal(imported.applied,3); assert.equal(imported.conflicts.length,0)
  const persisted = runtime(); persisted.initialize()
  const roundtrip = await persisted.invokePrivate('nativeSync:export',{})
  assert.equal(roundtrip.records.find(r => r.id === `note:${mid}`).payload.markdown,bytes.toString())
  assert.equal(roundtrip.records.find(r => r.id === `material:${mid}`).payload.id,mid)
  const materialRecord=roundtrip.records.find(r=>r.id===`material:${mid}`),materialRow=database.prepare('SELECT m.rel_path,c.folder_path FROM materials_index m JOIN courses c ON c.id=m.course_id WHERE m.id=?').get(mid),materialPath=path.join(materialRow.folder_path,materialRow.rel_path)
  fs.writeFileSync(materialPath,'local file before review')
  const remoteBytes=Buffer.from('remote file chosen'),remoteHash=crypto.createHash('sha256').update(remoteBytes).digest('hex'),remotePath=path.join(environment.tempPath,remoteHash);fs.writeFileSync(remotePath,remoteBytes)
  const remoteMaterial={...materialRecord,payload:{...materialRecord.payload,revision:remoteHash,byteCount:remoteBytes.length}}
  await invoke('import',{records:[remoteMaterial],assets:[{sha256:remoteHash,path:remotePath}]})
  const materialConflict=(await invoke('conflicts',{})).find(c=>c.recordID===materialRecord.id)
  fs.writeFileSync(materialPath,'latest unsynced file during review')
  await invoke('restoreConflict',{conflictID:materialConflict.id,variant:'remote',assets:[]})
  assert.equal(fs.readFileSync(materialPath,'utf8'),remoteBytes.toString())
  const latestFileConflict=(await invoke('conflicts',{})).find(c=>c.recordID===materialRecord.id&&c.reason.includes('reviewing'))
  assert.ok(latestFileConflict.assets.length>=2)
  await invoke('restoreConflict',{conflictID:latestFileConflict.id,variant:'local',assets:[]})
  assert.equal(fs.readFileSync(materialPath,'utf8'),'latest unsynced file during review')
  const learning=roundtrip.records.find(r=>r.payload.recordType==='desktop-learning-project')
  assert.ok(learning)
  const stateRef=learning.payload.files.find(f=>f.relPath==='state.json'),stateAsset=roundtrip.assets.find(a=>a.sha256===stateRef.assetRevision)
  const state=JSON.parse(fs.readFileSync(stateAsset.path,'utf8'));state.name='Synced learning words and review';state.revision++
  const stateBytes=Buffer.from(JSON.stringify(state)),stateHash=crypto.createHash('sha256').update(stateBytes).digest('hex'),statePath=path.join(environment.tempPath,stateHash);fs.writeFileSync(statePath,stateBytes)
  const remoteLearning={...learning,payload:{...learning.payload,stateRevision:state.revision,files:learning.payload.files.map(f=>f.relPath==='state.json'?{...f,assetRevision:stateHash,byteCount:stateBytes.length}:f)}}
  const learningAssets=[...roundtrip.assets.map(a=>({sha256:a.sha256,path:a.path})),{sha256:stateHash,path:statePath}]
  const learningImport=await invoke('import',{records:[remoteLearning],assets:learningAssets})
  assert.equal(learningImport.applied,1);assert.equal(learningImport.conflicts.length,0)
  const learningRead=await backend.invoke('learning:get',{binding:{courseId:learning.payload.courseID,rootRelPath:learning.payload.rootRelPath}})
  assert.equal(learningRead.name,state.name);assert.equal(learningRead.projectId,state.projectId)
  // Simulate process termination after a file replacement but before SQL commit.
  const interrupted=path.join(environment.userDataPath,'SyncRecovery','crash-fixture'); fs.mkdirSync(interrupted,{recursive:true})
  const targetPath=path.join(course.folderPath,note.relPath),backup=path.join(interrupted,'0.original'),originalBytes=fs.readFileSync(targetPath)
  fs.writeFileSync(backup,originalBytes); fs.writeFileSync(path.join(interrupted,'intent.json'),JSON.stringify({id:'uncommitted-test',entries:[{target:targetPath,backup,existed:true}]}));fs.writeFileSync(targetPath,'interrupted replacement')
  runtime().initialize();assert.deepEqual(fs.readFileSync(targetPath),originalBytes)
  console.log('PASS: sync projection stable IDs/assets, private surface, note conflicts/restore, ink union, SQL/file rollback, malformed preflight, persistent roundtrip')
}
