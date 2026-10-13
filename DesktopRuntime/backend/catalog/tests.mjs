import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
const official='https://bandal.io/plugins/index.json',custom='https://catalog.example.test/index.json'
const downloads=new Map(),bodies=new Map(),requests=[],cancelled=[]
let entries=[],failRead=false
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex')
export async function catalogPlatform(channel,input={}){
  if(channel==='native:cloudState')return{supabase:null,marketplaceURL:null,signedIn:false,accountID:null}
  if(channel==='native:catalogCancel'){cancelled.push(input.id);bodies.delete(input.id);return{ok:true}}
  if(channel==='native:catalogRead'){
    const body=bodies.get(input.bodyID);if(!body)throw new Error('Missing catalog body')
    if(failRead&&body.artifact)throw new Error('Fixture cancelled read')
    if(body.offset>=body.bytes.length){bodies.delete(input.bodyID);return{done:true,data:''}}
    const bytes=body.bytes.subarray(body.offset,body.offset+32768);body.offset+=bytes.length
    return{done:false,data:bytes.toString('base64')}
  }
  if(channel!=='native:catalogRequest')throw new Error('Unexpected catalog seam '+channel)
  requests.push(input);assert.equal(input.method,'GET');assert.equal(Object.keys(input.headers).length,0);assert.equal(input.accountID,null)
  let bytes
  if(input.kind==='index')bytes=Buffer.from(JSON.stringify({format:'bandal-plugin-catalog',version:1,name:'검증 카탈로그',entries:input.url===official?entries:[]}))
  else{
    assert.equal(input.sourceUrl,official);assert.equal(typeof input.entryID,'string');assert.match(input.sha256,/^[a-f0-9]{64}$/)
    bytes=downloads.get(input.url);assert.ok(bytes)
  }
  bodies.set(input.id,{bytes,offset:0,artifact:input.kind==='artifact'})
  return{status:200,headers:{'content-length':String(bytes.length)},bodyID:input.id,byteCount:bytes.length}
}
export async function runCatalogTests({invoke,environment,require}){
  const install=id=>invoke('plugins:installFromCatalog',{sourceUrl:official,id})
  const add=(id,kind,bytes,version='1.0.0',minAppVersion='0.1.0')=>{
    const url=`https://artifacts.example.test/${id}`;downloads.set(url,bytes)
    const entry={id,kind,name:id,publisher:'fixture',description:'원본 검증',tags:[],version,minAppVersion,url,sha256:hash(bytes)}
    entries=entries.filter(v=>v.id!==id);entries.push(entry);return entry
  }
  await assert.rejects(install('fixture.pack'),/새로고침/)
  const builtin=(await invoke('packs:list')).packs.find(v=>v.pack.id==='summary').pack
  const pack={...builtin,id:'fixture.pack',name:'카탈로그 학습 팩',version:'1.0.0'}
  add('fixture.pack','pack',Buffer.from(JSON.stringify(pack)))
  await invoke('settings:set',{pluginSources:[custom]})
  let catalog=await invoke('plugins:catalog',{refresh:true})
  assert.equal(catalog.sources.length,2);assert.equal(catalog.entries.length,1,JSON.stringify(catalog));assert.equal(catalog.entries[0].verified,true)
  const count=requests.length;await invoke('plugins:catalog',{refresh:false});assert.equal(requests.length,count,'Original catalog cache must avoid network')
  const imported=await install('fixture.pack');assert.equal(imported.kind,'pack');assert.equal(imported.pack.name,pack.name)
  add('fixture.pack','pack',Buffer.from(JSON.stringify({...pack,version:'1.1.0'})),'1.1.0')
  await invoke('plugins:catalog',{refresh:true});const upgraded=await install('fixture.pack');assert.equal(upgraded.pack.id,imported.pack.id);assert.equal(upgraded.pack.version,'1.1.0')
  const Zip=require('jszip'),zip=new Zip(),manifest={manifestVersion:2,id:'fixture.plugin',name:'Fixture plugin',version:'1.0.0',minAppVersion:'0.1.0',main:'main.js',permissions:[],contributes:{}}
  zip.file('manifest.json',JSON.stringify(manifest));zip.file('main.js','throw new Error("must never execute catalog code")')
  const safeZip=await zip.generateAsync({type:'nodebuffer',compression:'DEFLATE'}),extension=add('fixture.plugin','extension',safeZip)
  await invoke('plugins:catalog',{refresh:true});const plugin=await install('fixture.plugin')
  assert.equal(plugin.kind,'extension');assert.equal(plugin.plugin.enabled,false);assert.ok(plugin.warnings.some(v=>v.includes('실행할 수 없습니다')))
  assert.match(fs.readFileSync(path.join(environment.userDataPath,'plugins','fixture.plugin','main.js'),'utf8'),/never execute/)
  const registry=fs.readFileSync(path.join(environment.userDataPath,'plugins.json'),'utf8')
  downloads.set(extension.url,Buffer.from('tampered'))
  await assert.rejects(install('fixture.plugin'),/카탈로그와 달라/)
  assert.equal(fs.readFileSync(path.join(environment.userDataPath,'plugins.json'),'utf8'),registry)
  add('fixture.newer','pack',Buffer.from(JSON.stringify(pack)),'1.0.0','99.0.0');await invoke('plugins:catalog',{refresh:true})
  const beforeNewer=requests.length;await assert.rejects(install('fixture.newer'),/99.0.0/);assert.equal(requests.length,beforeNewer)
  const mismatch=new Zip();mismatch.file('manifest.json',JSON.stringify({...manifest,id:'other.plugin'}));mismatch.file('main.js','export{}')
  add('fixture.mismatch','extension',await mismatch.generateAsync({type:'nodebuffer'}));await invoke('plugins:catalog',{refresh:true});await assert.rejects(install('fixture.mismatch'),/id가/)
  const unsafe=new Zip();unsafe.file('../outside.js','unsafe');add('fixture.unsafe','extension',await unsafe.generateAsync({type:'nodebuffer'}));await invoke('plugins:catalog',{refresh:true});await assert.rejects(install('fixture.unsafe'),/안전하지 않은 경로/)
  const expanded=new Zip();expanded.file('main.js','x'.repeat(8*1024*1024+1));add('fixture.bomb','extension',await expanded.generateAsync({type:'nodebuffer',compression:'DEFLATE'}));await invoke('plugins:catalog',{refresh:true});await assert.rejects(install('fixture.bomb'),/size limit/)
  downloads.set(extension.url,safeZip);failRead=true
  await assert.rejects(install('fixture.plugin'),/cancelled read/);failRead=false
  assert.ok(cancelled.length);assert.equal(bodies.size,0)
  assert.ok(!fs.readdirSync(environment.tempPath).some(file=>file.startsWith('bandal-catalog-')),'Failed/successful installs must remove extraction staging')
  await invoke('plugins:uninstall',{id:'fixture.plugin'});await invoke('packs:remove',{id:imported.pack.id})
  console.log('PASS: original catalog cache/sources, pack import/upgrade stable ID, disabled verified extension install, SHA/id/version/path/expanded ZIP refusal, cancellation cleanup; no network/code execution')
}
