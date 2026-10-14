import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import * as crypto from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export async function testProjector({backend,database,environment,course,note}) {
  // Derive the known saved desktop dependency root, not the iPad executable's
  // Node ABI. The child loads better-sqlite3 with Electron's own loader.
  const desktopRoot=fileURLToPath(new URL('../../../bandal/',import.meta.url))
  const {createRequire}=await import('node:module'),desktopRequire=createRequire(path.join(desktopRoot,'package.json')),electron=desktopRequire('electron')
  const recording=await backend.invokePrivate('nativeRecording:create',{courseId:course.id,title:'Projector recorded lecture',modelId:'zipformer-ko'})
  await backend.invokePrivate('nativeRecording:status',{id:recording.id,status:'recording'})
  await backend.invokePrivate('nativeRecording:append',{id:recording.id,sequence:0,pcm:{__bandalBytes:Buffer.alloc(32000).toString('base64')}})
  await backend.invokePrivate('nativeRecording:replaceTranscript',{id:recording.id,segments:[{startSample:0,endSample:16000,text:'원본 전사 유지'}],transcribedSamples:16000})
  const inkV3=await backend.invoke('drawings:create',{courseId:course.id,relPath:'renamed.pdf',page:1,kind:'ink',data:{inkVersion:3,points:[{x:.1,y:.2,p:.1,t:0},{x:.2,y:.3,p:.2,t:4}]},style:{color:'blue',width:.004,opacity:1}})
  const fixture=path.join(environment.tempPath,'electron-projector'),profile=path.join(fixture,'Profile'),exchange=path.join(fixture,'Exchange')
  fs.mkdirSync(profile,{recursive:true});fs.mkdirSync(exchange,{recursive:true})
  const dbPath=path.join(profile,'bandal.db');await database.backup(dbPath)
  const root=fileURLToPath(new URL('../..',import.meta.url)),helper=path.join(root,'Tools/desktop-bridge/projector-host.cjs'),bundle=path.join(root,'DesktopRuntime/backend/dist/backend.js'),bridge=path.join(root,'Tools/desktop-bridge/bridge.py')
  const value={action:'export',database:dbPath,exchange,courseRoot:path.join(fixture,'Courses'),moduleRoot:desktopRoot,bundle}
  const call=input=>{const child=spawnSync(electron,[helper],{input:JSON.stringify({...value,...input}),encoding:'utf8',env:{...process.env,ELECTRON_RUN_AS_NODE:'1'},maxBuffer:64*1024*1024});assert.equal(child.status,0,child.stderr);return JSON.parse(child.stdout)}
  const exported=call({});assert.ok(exported.records.find(r=>r.kind==='recording'));assert.ok(exported.records.find(r=>r.payload.recordType==='desktop-learning-project'))
  const portable=exported.records.filter(r=>r.kind==='drawing').flatMap(r=>JSON.parse(Buffer.from(r.payload.data,'base64')).objects).find(object=>object.id===inkV3.id)
  assert.equal(portable.data.inkVersion,3);assert.deepEqual(portable.data.points.map(p=>p.p),[.1,.2])
  const driver=String.raw`
import importlib.util,json,os,sqlite3,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('bridge',sys.argv[1]);b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
desktop=Path(sys.argv[2]);x=b.Exchange(Path(sys.argv[3]))
# Simulate the already shipped Python mapper and queued unsent edits.
with sqlite3.connect(desktop) as d:d.execute('DELETE FROM ipad_sync_projection')
b.export_desktop(desktop,x,use_projector=False)
x.db.execute("INSERT INTO metadata VALUES('cursor','kept-cursor')");x.db.commit()
operations={r[0] for r in x.db.execute('SELECT id FROM outbox')}
ids={r['id'] for r in x.records()}
with sqlite3.connect(desktop) as d:
    migrations=list(d.execute('SELECT * FROM migrations'))
    d.execute('CREATE TABLE IF NOT EXISTS _bandal_bridge_commits(id TEXT PRIMARY KEY)')
    d.execute("INSERT OR IGNORE INTO _bandal_bridge_commits VALUES('old-recovery-receipt')")
b.projector_export(desktop,x)
assert operations <= {r[0] for r in x.db.execute('SELECT id FROM outbox')}
assert ids <= {r['id'] for r in x.records()}
assert x.db.execute("SELECT value FROM metadata WHERE key='cursor'").fetchone()[0]=='kept-cursor'
with sqlite3.connect(desktop) as d:
    assert list(d.execute('SELECT * FROM migrations'))==migrations
    assert d.execute("SELECT id FROM _bandal_bridge_commits WHERE id='old-recovery-receipt'").fetchone()
note=next(r for r in x.records('note') if '아이패드' in json.loads(r['payload'])['markdown'])
payload=json.loads(note['payload']);payload['markdown']='Desktop Electron projector roundtrip'
source,_=x.mapping(note['id']);x.export_record(note['id'],'note',payload,source or {})
result=b.projector_import(desktop,x);assert result['applied']>0
assert Path(sys.argv[4]).read_text()=='Desktop Electron projector roundtrip'
b.projector_export(desktop,x)
payload['markdown']='pending remote after cursor commit';current=x.get(note['id']);current['payload']=b.encoded(payload)
with x.db:x.begin_projection();x.set_record(b.envelope(current))
try:b.projector_export(desktop,x);raise AssertionError('Export must wait for interrupted import')
except ValueError as e:assert 'Recover pending' in str(e)
b.recover_projection(desktop,x)
assert Path(sys.argv[4]).read_text()=='pending remote after cursor commit'
assert not x.projection_pending()
b.projector_export(desktop,x)
Path(sys.argv[4]).write_text('local edit during sync')
payload['markdown']='conflicting remote';source,_=x.mapping(note['id']);x.export_record(note['id'],'note',payload,source or {})
with x.db:x.begin_projection()
try:b.recover_projection(desktop,x);raise AssertionError('Expected conflict')
except ValueError as e:assert 'conflicts are preserved' in str(e)
assert not x.projection_pending()
assert Path(sys.argv[4]).read_text()=='local edit during sync'
conflicts=b.projector_call(desktop,x,'conflicts');assert any(c['local'] and c['local']['payload'].get('markdown')=='local edit during sync' for c in conflicts)
b.projector_export(desktop,x)
assert json.loads(x.get(note['id'])['payload'])['markdown']=='conflicting remote','unresolved local copy must not become a newer remote operation'
assert any(r['kind']=='artifact' and json.loads(r['payload']).get('recordType')=='desktop-learning-file' for r in x.records())
x.db.close();print('PASS: Electron ABI projector + existing Python outbox/IDs/cursor/receipts + learning/audio assets + note roundtrip/conflict')
`
  const child=spawnSync('python3',['-c',driver,bridge,dbPath,exchange,path.join(course.folderPath,note.relPath)],{encoding:'utf8',env:{...process.env,BANDAL_DESKTOP_PROJECTOR:helper,BANDAL_DESKTOP_RUNTIME:electron,BANDAL_DESKTOP_MODULE_ROOT:desktopRoot,BANDAL_DESKTOP_BACKEND:bundle},maxBuffer:64*1024*1024})
  assert.equal(child.status,0,child.stderr);console.log(child.stdout.trim())
}
