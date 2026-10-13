import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { randomUUID, createHash } from 'node:crypto'
import * as fs from 'node:fs'
import * as path from 'node:path'
import * as os from 'node:os'
import vm from 'node:vm'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild'), SQLite = require('better-sqlite3-node')
const built = await build({stdin:{resolveDir:runtime,loader:'ts',contents:"export {createPDFDocumentBindings} from './backend/native-pdf';"},bundle:true,write:false,format:'cjs',platform:'node'})
const exports = {}, context = vm.createContext({exports,module:{exports},require,console})
vm.runInContext(built.outputFiles[0].text,context)
const {createPDFDocumentBindings} = context.module.exports, directory=fs.mkdtempSync(path.join(os.tmpdir(),'bandal-pdf-binding-')), db=new SQLite(path.join(directory,'test.db'))
const hash = bytes=>createHash('sha256').update(bytes).digest('hex'), courseId=randomUUID(), original=Buffer.from('%PDF original'), revision=hash(original), replacement=Buffer.from('%PDF replacement')
const open = ()=>createPDFDocumentBindings(db,(_course,relPath)=>hash(fs.readFileSync(path.join(directory,relPath))))
try {
  db.exec(`PRAGMA foreign_keys=ON; CREATE TABLE courses(id TEXT PRIMARY KEY,deleted_at TEXT);
    CREATE TABLE materials_index(id TEXT PRIMARY KEY,course_id TEXT,rel_path TEXT,UNIQUE(course_id,rel_path));
    CREATE TABLE pdf_drawings(id TEXT PRIMARY KEY,course_id TEXT,rel_path TEXT,deleted_at TEXT);
    CREATE TABLE annotations(id TEXT PRIMARY KEY,course_id TEXT,rel_path TEXT);
    CREATE TABLE drawing_create_receipts(operation_id TEXT PRIMARY KEY,request_json TEXT,drawing_id TEXT);
    CREATE TABLE ipad_sync_projection(kind TEXT,payload_json TEXT,source_json TEXT)`)
  db.prepare('INSERT INTO courses(id) VALUES(?)').run(courseId)
  const put = (relPath, receipt=false) => {
    fs.mkdirSync(path.dirname(path.join(directory,relPath)),{recursive:true});fs.writeFileSync(path.join(directory,relPath),original)
    const id=randomUUID(),drawingId=randomUUID()
    db.prepare('INSERT INTO materials_index VALUES(?,?,?)').run(id,courseId,relPath)
    db.prepare('INSERT INTO pdf_drawings VALUES(?,?,?,NULL)').run(drawingId,courseId,relPath)
    if(receipt)db.prepare('INSERT INTO drawing_create_receipts VALUES(?,?,?)').run(randomUUID(),JSON.stringify({courseId,relPath,documentRevision:revision}),drawingId)
    return {id,drawingId}
  }
  const legacy=put('legacy.pdf'), bindings=open()
  const bound=bindings.check({courseId,relPath:'legacy.pdf',documentRevision:revision})
  assert.equal(bound.materialID,legacy.id);assert.equal(bound.evidence,'first-observed');assert.equal(bound.legacyUnverified,true)
  fs.writeFileSync(path.join(directory,'legacy.pdf'),replacement)
  assert.throws(()=>open().check({courseId,relPath:'legacy.pdf'}),/기존 필기/,'Reopen must not relabel old rows')
  assert.equal(db.prepare('SELECT bound_sha FROM pdf_document_bindings WHERE material_id=?').get(legacy.id).bound_sha,revision)
  assert.equal(db.prepare('SELECT rel_path FROM pdf_drawings WHERE id=?').get(legacy.drawingId).rel_path,'legacy.pdf')
  fs.writeFileSync(path.join(directory,'legacy.pdf'),original)
  const measured=put('receipt.pdf',true)
  // The first run of the migration already sees replacement bytes. Its old
  // committed receipt is sufficient to reject and retain the original SHA.
  fs.writeFileSync(path.join(directory,'receipt.pdf'),replacement)
  assert.throws(()=>bindings.check({courseId,relPath:'receipt.pdf',documentRevision:hash(replacement)}),/기존 필기/)
  assert.equal(db.prepare('SELECT bound_sha,evidence FROM pdf_document_bindings WHERE material_id=?').get(measured.id).evidence,'receipt')
  fs.writeFileSync(path.join(directory,'receipt.pdf'),original)
  assert.equal(open().check({courseId,relPath:'receipt.pdf'}).legacyUnverified,false)
  // Stable identity survives the destructive rebuild of the search cache.
  db.prepare('DELETE FROM materials_index WHERE id=?').run(measured.id)
  db.prepare('INSERT INTO materials_index VALUES(?,?,?)').run(randomUUID(),courseId,'receipt.pdf')
  bindings.reconcileIndex()
  assert.equal(db.prepare('SELECT id FROM materials_index WHERE rel_path=?').get('receipt.pdf').id,measured.id)
  fs.renameSync(path.join(directory,'receipt.pdf'),path.join(directory,'renamed.pdf'))
  bindings.repoint({courseId,fromRelPath:'receipt.pdf',toRelPath:'renamed.pdf',isDirectory:false})
  db.prepare('UPDATE pdf_drawings SET rel_path=? WHERE id=?').run('renamed.pdf',measured.drawingId)
  assert.equal(open().check({courseId,relPath:'renamed.pdf'}).materialID,measured.id)
  assert.equal(db.prepare('SELECT rel_path FROM materials_index WHERE id=?').get(measured.id).rel_path,'renamed.pdf')
  assert.equal(JSON.parse(db.prepare('SELECT request_json FROM drawing_create_receipts WHERE drawing_id=?').get(measured.drawingId).request_json).relPath,'receipt.pdf','Receipt fingerprint remains immutable on rename')
  const nested=put('old/sub/lecture.pdf',true)
  bindings.check({courseId,relPath:'old/sub/lecture.pdf'})
  fs.renameSync(path.join(directory,'old'),path.join(directory,'new'))
  bindings.repoint({courseId,fromRelPath:'old',toRelPath:'new',isDirectory:true})
  db.prepare('UPDATE pdf_drawings SET rel_path=? WHERE id=?').run('new/sub/lecture.pdf',nested.drawingId)
  assert.equal(open().check({courseId,relPath:'new/sub/lecture.pdf'}).materialID,nested.id)
  const synced=put('synced.pdf')
  db.prepare('INSERT INTO ipad_sync_projection VALUES(?,?,?)').run('drawing',JSON.stringify({materialID:synced.id,documentRevision:revision}),JSON.stringify({courseID:courseId,relPath:'synced.pdf'}))
  fs.writeFileSync(path.join(directory,'synced.pdf'),replacement)
  assert.throws(()=>bindings.check({courseId,relPath:'synced.pdf'}),/기존 필기/)
  assert.equal(db.prepare('SELECT evidence FROM pdf_document_bindings WHERE material_id=?').get(synced.id).evidence,'sync')
  const ambiguous=put('ambiguous.pdf',true)
  db.prepare('INSERT INTO ipad_sync_projection VALUES(?,?,?)').run('drawing',JSON.stringify({materialID:ambiguous.id,documentRevision:hash(replacement)}),JSON.stringify({courseID:courseId,relPath:'ambiguous.pdf'}))
  assert.throws(()=>bindings.check({courseId,relPath:'ambiguous.pdf'}),/서로 다른/)
  assert.equal(db.prepare('SELECT COUNT(*) n FROM pdf_document_bindings WHERE material_id=?').get(ambiguous.id).n,0)
  for(const input of [{courseId,relPath:'../legacy.pdf'},{courseId,relPath:'legacy.pdf',documentRevision:'bad'},{courseId,relPath:'legacy.pdf',documentRevision:hash(replacement)},{courseId:randomUUID(),relPath:'legacy.pdf'}])assert.throws(()=>bindings.check(input))
  console.log('PDF durable binding: legacy limitation, prior receipt/sync migration, replacement rejection, restart, cache rebuild, file/folder rename, immutable receipts, ambiguous revision rejection PASS')
} finally { db.close();fs.rmSync(directory,{recursive:true,force:true}) }
