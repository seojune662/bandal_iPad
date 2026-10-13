import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import vm from 'node:vm'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild')
const SQLite = require('better-sqlite3-node')
const built = await build({stdin:{resolveDir:runtime,loader:'ts',contents:"export {nativePDFMutationStatus} from './backend/native-pdf'; export {createDrawingsRepo} from './upstream/src/main/features/pdf/drawingsRepo'; export {NativePDFSession} from './renderer/nativePDF/session';"},bundle:true,write:false,format:'cjs',platform:'node'})
const exports = {}, context = vm.createContext({exports,module:{exports},require,console})
vm.runInContext(built.outputFiles[0].text,context)
const {nativePDFMutationStatus,createDrawingsRepo,NativePDFSession} = context.module.exports
const plain = value=>JSON.parse(JSON.stringify(value)), db = new SQLite(':memory:')
try {
  db.exec(`CREATE TABLE courses(id TEXT PRIMARY KEY,deleted_at TEXT);
    CREATE TABLE pdf_drawings(id TEXT PRIMARY KEY,course_id TEXT,rel_path TEXT,page INTEGER,kind TEXT,data_json TEXT,style_json TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT)`)
  const courseId='00000000-0000-4000-8000-000000000001', revision='a'.repeat(64)
  db.prepare('INSERT INTO courses(id) VALUES(?)').run(courseId)
  const repo=createDrawingsRepo(db,{documentRevision:()=>revision})
  const input={courseId,relPath:'lesson.pdf',page:1,kind:'ink',documentRevision:revision,clientMutationId:'00000000-0000-4000-8000-000000000002',data:{inkVersion:2,points:[{x:.2,y:.4,p:.6,t:0,tiltX:0,tiltY:0}]},style:{color:'ink',width:.003,opacity:1}}
  assert.deepEqual(plain(nativePDFMutationStatus(db,input)),{status:'missing'})
  let creates=0,history=0,acknowledgements=0,failAck=true,pending=[input]
  const writer={async create(value){creates++;const result=repo.create(value);history++;return result},async flush(){}}
  const bridge={async invoke(channel,request){
    if(channel==='pdfNative:mutationStatus')return nativePDFMutationStatus(db,request.input)
    if(channel==='pdfNative:flush')return {pending}
    if(channel==='pdfNative:close')return {}
    if(channel==='pdfNative:ack'){
      if(failAck){failAck=false;throw new Error('ACK transport lost')}
      assert.equal(request.drawingId,db.prepare('SELECT drawing_id FROM drawing_create_receipts WHERE operation_id=?').get(request.clientMutationId).drawing_id)
      acknowledgements++;pending=[];return {}
    }
    throw new Error(channel)
  },on(){return()=>{}}}
  const identity={surfaceId:'panel',generation:'first',courseId,relPath:'lesson.pdf'}
  const first=new NativePDFSession(identity,bridge,writer)
  await assert.rejects(first.accept(input),/ACK transport lost/)
  assert.equal(creates,1);assert.equal(history,1)
  const created=repo.listForFile(courseId,'lesson.pdf')[0]
  repo.update({id:created.id,style:{...input.style,color:'red'}})
  assert.deepEqual(plain(nativePDFMutationStatus(db,input)),{status:'live',drawingId:created.id})
  repo.softDelete([created.id]) // The user undoes the completed stroke before the failed ACK recovers.
  assert.deepEqual(plain(nativePDFMutationStatus(db,input)),{status:'deleted',drawingId:created.id})
  assert.throws(()=>repo.create(input),/not-found/,'The existing create-only recovery path cannot resolve this tombstone')
  const restarted=new NativePDFSession({...identity,generation:'restarted'},bridge,writer)
  await restarted.flush();await restarted.close()
  assert.equal(acknowledgements,1);assert.equal(creates,1);assert.equal(history,1)
  assert.equal(repo.listForFile(courseId,'lesson.pdf').length,0,'Replay must not undo the user deletion')
  assert.equal(db.prepare('SELECT COUNT(*) count FROM pdf_drawings').get().count,1,'No replacement row may be created')
  // Recovery identity is canonicalized just as the original repository does.
  assert.equal(nativePDFMutationStatus(db,{...input,data:{extra:'ignored',points:input.data.points,inkVersion:2},style:{opacity:1,width:.003,color:'ink'}}).status,'deleted')
  for(const patch of [{clientMutationId:'bad'},{courseId:'other'},{relPath:'different.pdf'},{relPath:'../lesson.pdf'},{documentRevision:'b'.repeat(64)},{documentRevision:undefined},{page:2},{data:{...input.data,points:[{x:NaN,y:0,p:1}]}},{style:{...input.style,width:.004}}])assert.throws(()=>nativePDFMutationStatus(db,{...input,...patch}))
  // A missing canonical row is not a confirmed delete and cannot retire the journal.
  db.prepare('DELETE FROM pdf_drawings WHERE id=?').run(created.id)
  assert.throws(()=>nativePDFMutationStatus(db,input),/missing/)
  const failedSession=new NativePDFSession({...identity,generation:'corrupt'},bridge,writer)
  pending=[input];await assert.rejects(failedSession.flush(),/missing/)
  assert.equal(pending.length,1);assert.equal(creates,1);assert.equal(acknowledgements,1)
  console.log('Actual receipt repository + native session: lost ACK → undo → restart retires journal without resurrection/history; fingerprint/revision/path mismatch and missing-row recovery stay blocked')
} finally { db.close() }
