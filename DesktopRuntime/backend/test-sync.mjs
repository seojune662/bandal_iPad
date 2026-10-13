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
  const object={id:crypto.randomUUID(),kind:'ink',data:{inkVersion:2,points:[{x:.1,y:.2,p:.4,t:0,tiltX:-30,tiltY:15},{x:.2,y:.3,p:.8,t:12,tiltX:25,tiltY:-12}]},style:{color:'ink',width:.003,opacity:1},createdAt:'2026-10-13T00:00:00Z',updatedAt:'2026-10-13T00:00:00Z'}
  const pageRecord={schemaVersion:1,materialID:whiteboard.payload.id,documentRevision:whiteboard.payload.revision,page:1,coordinateSpace:'unrotated-crop-box-top-left-normalized',geometry:{cropX:0,cropY:0,width:595.28,height:841.89,rotation:0},objects:[object],highlights:[],deletedObjectIDs:[],deletedHighlightIDs:[]}
  const boardInk={id:`drawing:${pageRecord.materialID}:${pageRecord.documentRevision}:1`,kind:'drawing',payload:{materialID:pageRecord.materialID,documentRevision:pageRecord.documentRevision,page:1,data:Buffer.from(JSON.stringify(pageRecord)).toString('base64')},deleted:false,formatVersion:1}
  assert.equal((await invoke('import',{records:[boardInk],assets})).applied,1)
  assert.equal(database.prepare('SELECT id FROM whiteboard_local_shapes WHERE id=?').get(object.id).id,object.id)
  assert.deepEqual(JSON.parse(database.prepare('SELECT data_json FROM whiteboard_local_shapes WHERE id=?').get(object.id).data_json),object.data,'Whiteboard import preserves v2 measured metadata')
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
  await testV2InkSync({ backend, invoke, runtime, course })
  console.log('PASS: sync projection stable IDs/assets, private surface, note conflicts/restore, ink union, SQL/file rollback, malformed preflight, persistent roundtrip')
}

async function testV2InkSync({ backend, invoke, runtime, course }) {
  const plain = value => JSON.parse(JSON.stringify(value))
  const decode = record => JSON.parse(Buffer.from(record.payload.data,'base64'))
  const encode = (record, page) => ({...record,payload:{...record.payload,data:Buffer.from(JSON.stringify(page)).toString('base64')}})
  const exported = await invoke('export',{})
  const material = exported.records.find(record=>record.kind==='material'&&record.payload.courseID===course.id&&record.payload.kind==='pdf')
  assert.ok(material)
  const relPath=material.payload.desktop.relPath, pageCount=process.argv.includes('--pdf')?4:1
  const points=[{x:.125,y:.25,p:0,t:0,tiltX:-45,tiltY:20},{x:.125,y:.25,p:1,t:8,tiltX:35,tiltY:-40},{x:.75,y:.875,p:.6,t:32,tiltX:5,tiltY:70}]
  const shapes=[]
  for(let page=1;page<=pageCount;page++)shapes.push(plain(await backend.invoke('drawings:create',{courseId:course.id,relPath,page,kind:page%2?'ink':'highlighter',data:{inkVersion:2,points},style:{color:'violet',width:.006,opacity:.3}})))
  let snapshot=await invoke('export',{}), assets=snapshot.assets.map(asset=>({sha256:asset.sha256,path:asset.path}))
  const pages=shapes.map(shape=>snapshot.records.find(record=>record.kind==='drawing'&&record.payload.materialID===material.payload.id&&record.payload.page===shape.page))
  if(pageCount===4)assert.deepEqual(pages.map(record=>decode(record).geometry.rotation),[0,90,180,270])
  const expectedFirst={0:[.125,.25],90:[.25,.875],180:[.875,.75],270:[.75,.125]}
  for(let index=0;index<shapes.length;index++){
    const shape=shapes[index], record=pages[index], page=decode(record), object=page.objects.find(object=>object.id===shape.id)
    assert.equal(page.coordinateSpace,'unrotated-crop-box-top-left-normalized')
    assert.equal(page.documentRevision,material.payload.revision)
    assert.ok(page.geometry.cropX>0&&page.geometry.cropY>0,'Use actual cropped PDF geometry instead of a zero-origin fixture')
    assert.equal(object.data.inkVersion,2)
    assert.deepEqual([object.data.points[0].x,object.data.points[0].y],expectedFirst[page.geometry.rotation])
    assert.deepEqual(object.data.points.map(({p,t,tiltX,tiltY})=>({p,t,tiltX,tiltY})),points.map(({p,t,tiltX,tiltY})=>({p,t,tiltX,tiltY})))
    const width=shape.style.width*([90,270].includes(page.geometry.rotation)?page.geometry.height/page.geometry.width:1)
    assert.ok(Math.abs(object.style.width-width)<1e-12)
    const edited={...object,data:{...object.data,points:object.data.points.map((point,index)=>({...point,t:point.t+64,tiltX:index===2?-55:point.tiltX}))},style:{...object.style,color:'red'}}
    const incoming=encode(record,{...page,objects:page.objects.map(object=>object.id===shape.id?edited:object)})
    for(let retry=0;retry<2;retry++){
      const result=await invoke('import',{records:[incoming],assets})
      assert.equal(result.applied,1);assert.equal(result.conflicts.length,0)
    }
    const current=plain(await backend.invoke('drawings:listForFile',{courseId:course.id,relPath})).find(object=>object.id===shape.id)
    assert.equal(current.data.inkVersion,2);assert.equal(current.kind,shape.kind);assert.equal(current.style.color,'red')
    for(let i=0;i<points.length;i++){
      assert.ok(Math.abs(current.data.points[i].x-points[i].x)<1e-12)
      assert.ok(Math.abs(current.data.points[i].y-points[i].y)<1e-12)
      assert.equal(current.data.points[i].p,points[i].p);assert.equal(current.data.points[i].t,points[i].t+64)
      assert.equal(current.data.points[i].tiltX,i===2?-55:points[i].tiltX);assert.equal(current.data.points[i].tiltY,points[i].tiltY)
    }
    assert.ok(Math.abs(current.style.width-shape.style.width)<1e-12)
  }
  const reopened=runtime();reopened.initialize()
  snapshot=await reopened.invokePrivate('nativeSync:export',{})
  const target=shapes[0], base=snapshot.records.find(record=>record.id===pages[0].id), page=decode(base), original=page.objects.find(object=>object.id===target.id)
  assert.equal(original.data.inkVersion,2);assert.equal(original.data.points[2].tiltX,-55)
  // Matching concurrent changes to the SAME ID converge without dropping any
  // measured metadata or manufacturing another object.
  const local=plain(await backend.invoke('drawings:update',{id:target.id,style:{...target.style,color:'blue'}}))
  const matching={...original,style:{...original.style,color:'blue'},updatedAt:local.updatedAt}
  const same=encode(base,{...page,objects:page.objects.map(object=>object.id===target.id?matching:object)})
  const sameResult=await invoke('import',{records:[same],assets})
  assert.equal(sameResult.applied,1);assert.equal(sameResult.conflicts.length,0)
  const afterSame=plain(await backend.invoke('drawings:listForFile',{courseId:course.id,relPath})).filter(object=>object.id===target.id)
  assert.equal(afterSame.length,1);assert.deepEqual(afterSame[0].data,local.data)
  // Incompatible changes to one ID must preserve BOTH complete v2 variants,
  // not quietly merge style while losing pressure/time/tilt data.
  snapshot=await invoke('export',{});const conflictBase=snapshot.records.find(record=>record.id===base.id), conflictPage=decode(conflictBase)
  const remoteObject=conflictPage.objects.find(object=>object.id===target.id)
  const localPoints=local.data.points.map(point=>({...point,t:point.t+10,tiltY:-25}))
  await backend.invoke('drawings:update',{id:target.id,data:{inkVersion:2,points:localPoints}})
  const remotePoints=remoteObject.data.points.map(point=>({...point,t:point.t+20,tiltY:50}))
  const remote=encode(conflictBase,{...conflictPage,objects:conflictPage.objects.map(object=>object.id===target.id?{...object,data:{inkVersion:2,points:remotePoints}}:object)})
  const conflicted=await invoke('import',{records:[remote],assets})
  assert.equal(conflicted.applied,0);assert.equal(conflicted.conflicts.length,1)
  const current=plain(await backend.invoke('drawings:listForFile',{courseId:course.id,relPath})).find(object=>object.id===target.id)
  assert.deepEqual(current.data,{inkVersion:2,points:localPoints})
  const conflict=(await invoke('conflicts',{})).find(conflict=>conflict.id===conflicted.conflicts[0].id)
  const localVariant=decode(conflict.local).objects.find(object=>object.id===target.id), remoteVariant=decode(conflict.remote).objects.find(object=>object.id===target.id)
  assert.equal(localVariant.data.inkVersion,2);assert.equal(localVariant.data.points[0].tiltY,-25)
  assert.deepEqual(remoteVariant.data,{inkVersion:2,points:remotePoints})
  const restored=await invoke('restoreConflict',{conflictID:conflict.id,variant:'remote',assets})
  assert.equal(restored.applied,1)
  const resolved=plain(await backend.invoke('drawings:listForFile',{courseId:course.id,relPath})).find(object=>object.id===target.id)
  assert.equal(resolved.data.inkVersion,2);assert.equal(resolved.data.points[0].tiltY,50);assert.equal(resolved.data.points[0].t,remotePoints[0].t)
  assert.equal(resolved.data.points[0].p,points[0].p)
  console.log(`PASS: v2 sync metadata/portable coordinate roundtrip (${pageCount} rotated cropped page(s)), same-ID convergence, incompatible-edit copies and explicit v2 recovery`)
}
