import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import { createHash } from 'node:crypto'

export async function testPDFBinding({backend,database,environment,runtime,course}) {
  const invoke=(channel,request)=>backend.invoke(channel,request), privateCall=(channel,request)=>backend.invokePrivate(channel,request)
  const relPath='renamed.pdf', original=fs.readFileSync(path.join(course.folderPath,relPath)), revision=createHash('sha256').update(original).digest('hex')
  const binding=await privateCall('nativePDF:binding',{courseId:course.id,relPath,documentRevision:revision})
  const preserved=path.join(environment.userDataPath,'PDFOriginals',revision+'.pdf')
  assert.deepEqual(fs.readFileSync(preserved),original)
  let originalRows=database.prepare('SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=? ORDER BY id').all(course.id,relPath)
  assert.ok(originalRows.length)
  const snapshot=await privateCall('nativeSync:export',{}), material=snapshot.records.find(r=>r.id===`material:${binding.materialID}`), ink=snapshot.records.find(r=>r.kind==='drawing'&&r.payload.materialID===binding.materialID)
  assert.equal(material.payload.revision,revision);assert.equal(ink.payload.documentRevision,revision)
  const unsafeNote={id:`note:${binding.materialID}`,kind:'note',formatVersion:1,deleted:false,payload:{materialID:binding.materialID,markdown:'# must not overwrite PDF'}}
  const wrongNote=await privateCall('nativeSync:import',{records:[unsafeNote],assets:[]})
  assert.equal(wrongNote.applied,0,'A note envelope must never overwrite PDF bytes')
  assert.equal(wrongNote.conflicts.length,1);assert.deepEqual(fs.readFileSync(path.join(course.folderPath,relPath)),original)
  for(const kind of ['note','whiteboard']) {
    const wrongKind=await privateCall('nativeSync:import',{records:[{...material,payload:{...material.payload,kind}}],assets:[]})
    assert.equal(wrongKind.applied,0,'A PDF material ID cannot be retyped as '+kind)
    assert.equal(database.prepare('SELECT kind FROM materials_index WHERE id=?').get(binding.materialID).kind,'pdf')
    assert.equal(database.prepare('SELECT id FROM whiteboards WHERE id=?').get(binding.materialID),undefined)
  }
  database.exec("CREATE TRIGGER fail_binding_runtime_repoint BEFORE UPDATE OF rel_path ON pdf_drawings BEGIN SELECT RAISE(ABORT,'runtime repoint failure'); END")
  await assert.rejects(invoke('materials:rename',{courseId:course.id,relPath,newName:'pending-completion.pdf'}),/runtime repoint failure/)
  database.exec('DROP TRIGGER fail_binding_runtime_repoint')
  assert.equal(fs.existsSync(path.join(course.folderPath,relPath)),false)
  assert.deepEqual(fs.readFileSync(path.join(course.folderPath,'pending-completion.pdf')),original)
  await assert.rejects(privateCall('nativePDF:binding',{courseId:course.id,relPath:'pending-completion.pdf'}),/복구/)
  await assert.rejects(privateCall('nativeSync:export',{}),/복구/)
  const restarted=runtime();restarted.initialize()
  // initialize recovers canonical paths synchronously, then schedules learning
  // JSON replay under the same OS path lock. Await that real startup work
  // rather than racing a rename against it (these VM "restarts" coexist).
  await restarted.repositories.learning.withExclusivePathAccess(async()=>{})
  assert.equal(database.prepare('SELECT COUNT(*) n FROM learning_path_outbox').get().n,0)
  assert.equal((await restarted.invokePrivate('nativePDF:binding',{courseId:course.id,relPath:'pending-completion.pdf'})).materialID,binding.materialID)
  assert.deepEqual(database.prepare('SELECT id FROM pdf_drawings WHERE course_id=? AND rel_path=? ORDER BY id').all(course.id,'pending-completion.pdf').map(r=>r.id),originalRows.map(r=>r.id))
  await restarted.invoke('materials:rename',{courseId:course.id,relPath:'pending-completion.pdf',newName:relPath})
  // Finish this VM's scheduled replay before resuming the original VM below.
  await restarted.repositories.learning.withExclusivePathAccess(async()=>{})
  originalRows=database.prepare('SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=? ORDER BY id').all(course.id,relPath)
  assert.deepEqual(fs.readFileSync(path.join(course.folderPath,relPath)),original)
  assert.equal((await privateCall('nativePDF:binding',{courseId:course.id,relPath})).materialID,binding.materialID)
  assert.deepEqual(database.prepare('SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=? ORDER BY id').all(course.id,relPath),originalRows)
  const beforeProjection=database.prepare('SELECT * FROM ipad_sync_projection ORDER BY id').all()
  const replacement=Buffer.concat([original,Buffer.from('\n% replacement revision\n')]), newRevision=createHash('sha256').update(replacement).digest('hex'), target=path.join(course.folderPath,relPath)
  fs.writeFileSync(target,replacement)
  for(const channel of ['drawings:listForFile','annotations:listForFile','pdf:exportAnnotated'])await assert.rejects(invoke(channel,{courseId:course.id,relPath}),/기존 필기/)
  await assert.rejects(privateCall('nativePDF:binding',{courseId:course.id,relPath,documentRevision:newRevision}),/기존 필기/)
  await assert.rejects(privateCall('nativeSync:export',{}),/기존 필기/,'Sync must not create a new-SHA envelope with old ink')
  const reopened=runtime();reopened.initialize()
  await assert.rejects(reopened.invoke('drawings:listForFile',{courseId:course.id,relPath}),/기존 필기/)
  await assert.rejects(invoke('drawings:update',{id:originalRows[0].id,style:{color:'blue',width:.003,opacity:1}}),/기존 필기/)
  assert.deepEqual(database.prepare('SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=? ORDER BY id').all(course.id,relPath),originalRows)
  assert.deepEqual(database.prepare('SELECT * FROM ipad_sync_projection ORDER BY id').all(),beforeProjection)
  assert.deepEqual(fs.readFileSync(target),replacement,'Guard never silently overwrites the replacement or source file')
  assert.deepEqual(fs.readFileSync(preserved),original,'Original revision remains recoverable outside disposable caches')
  fs.writeFileSync(target,original)
  const staged=path.join(environment.tempPath,newRevision+'.pdf');fs.writeFileSync(staged,replacement)
  const remote={...material,payload:{...material.payload,revision:newRevision,byteCount:replacement.length}}
  const imported=await privateCall('nativeSync:import',{records:[remote],assets:[{sha256:newRevision,path:staged}]})
  assert.equal(imported.applied,0);assert.equal(imported.conflicts.length,1);assert.match(imported.conflicts[0].reason,/preserved drawing revision/)
  assert.deepEqual(fs.readFileSync(target),original);assert.deepEqual(database.prepare('SELECT * FROM pdf_drawings WHERE course_id=? AND rel_path=? ORDER BY id').all(course.id,relPath),originalRows)
  await invoke('materials:rename',{courseId:course.id,relPath,newName:'binding-renamed.pdf'})
  const after=await privateCall('nativePDF:binding',{courseId:course.id,relPath:'binding-renamed.pdf',documentRevision:revision})
  assert.equal(after.materialID,binding.materialID)
  const renamed=await privateCall('nativeSync:export',{}), renamedInk=renamed.records.find(r=>r.id===ink.id)
  assert.equal(renamedInk.payload.documentRevision,revision)
  assert.deepEqual(JSON.parse(Buffer.from(renamedInk.payload.data,'base64')).objects.map(o=>o.id).sort(),JSON.parse(Buffer.from(ink.payload.data,'base64')).objects.map(o=>o.id).sort())
  assert.equal(database.prepare('SELECT rel_path FROM materials_index WHERE id=?').get(binding.materialID).rel_path,'binding-renamed.pdf')
  console.log('Actual backend PDF binding: replacement blocks reopen/list/edit/export/sync without row or projection loss; remote replacement conflict retained; rename preserves ink and material IDs PASS')
}
