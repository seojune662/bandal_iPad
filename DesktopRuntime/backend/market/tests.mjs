import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
let state={supabase:null,marketplaceURL:null,signedIn:false,accountID:null},pickedArchive=null,pickedPreview=null
const bodies=new Map(),requests=[],cancelled=[],uploads=new Map(),downloads=new Map()
let manifest,failDownload=false,wrongChecksum=false,switchDuringRead=false
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex')
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVioAAAAASUVORK5CYII=','base64')
const configured={supabase:{url:'https://fixture.supabase.co',publishableKey:'fixture-public-key'},marketplaceURL:'https://market.fixture.test',signedIn:true,accountID:'fixture-user-a'}
function response(id,value,status=200,headers={}){
  const bytes=Buffer.isBuffer(value)?value:Buffer.from(JSON.stringify(value)),bodyID=crypto.randomUUID()
  bodies.set(bodyID,{bytes,offset:0,id});return{status,headers:{'content-length':String(bytes.length),...headers},bodyID,byteCount:bytes.length}
}
export async function marketPlatform(channel,input={}){
  if(channel==='native:cloudState')return structuredClone(state)
  if(channel==='native:marketPickPreview')return pickedPreview
  if(channel==='native:marketSanitizePreview')return input.dataUrl.split(',')[1]
  if(channel==='native:marketPickPluginArchive')return pickedArchive
  if(channel==='native:saveFile')return{saved:false}
  if(channel==='shell:openExternal')throw new Error('External checkout must not open during fixtures')
  if(channel==='native:cloudCancel'){cancelled.push(input.id);for(const[id,body]of bodies)if(body.id===input.id)bodies.delete(id);return{ok:true}}
  if(channel==='native:cloudRead'){
    const body=bodies.get(input.bodyID);if(!body)throw new Error('Unknown mock body')
    if(failDownload&&body.download)throw Object.assign(new Error('Fixture cancellation'),{name:'AbortError'})
    if(switchDuringRead&&body.download){switchDuringRead=false;state={...state,accountID:'fixture-user-b'}}
    if(body.offset>=body.bytes.length){bodies.delete(input.bodyID);return{done:true,data:''}}
    const data=body.bytes.subarray(body.offset,body.offset+32768);body.offset+=data.length;return{done:false,data:data.toString('base64')}
  }
  if(channel!=='native:cloudRequest')throw new Error('Unmocked market native channel '+channel)
  requests.push(structuredClone(input))
  assert.equal(input.accountID,state.accountID,'Every continuation must retain and validate the initial account binding')
  const url=new URL(input.url),body=input.bodyBase64?Buffer.from(input.bodyBase64,'base64'):Buffer.alloc(0)
  if(url.pathname==='/rest/v1/rpc/submit_feedback')return response(input.id,null)
  if(url.pathname==='/functions/v1/study-market'){
    const {action,input:request}=JSON.parse(body)
    if(action==='dashboard')return response(input.id,{configured:true,signedIn:true,listings:[{id:'listing',versionId:'version',status:'draft'}],purchases:[]})
    if(action==='uploadGrant')return response(input.id,{token:'fixture-signature',bucket:'market',objectPath:request.fileId,resumableUrl:'https://fixture.supabase.co/storage/v1/upload/resumable'})
    if(action==='finalizeFile')return response(input.id,{ok:true})
    if(action==='download')return response(input.id,{orderId:request.orderId,title:'검증 자료',courseName:'구매 과목',files:manifest})
    if(action==='downloadComplete')return response(input.id,{ok:true})
    if(action==='orderStatus')return response(input.id,{status:'pending',checkoutUrl:'https://evil.example/checkout'})
    throw new Error('Unexpected study market fixture action '+action)
  }
  if(url.pathname==='/storage/v1/upload/resumable'){
    const id=crypto.randomUUID();uploads.set(id,Buffer.alloc(0));return response(input.id,Buffer.alloc(0),201,{location:`/storage/v1/upload/resumable/${id}`})
  }
  if(url.pathname.startsWith('/storage/v1/upload/resumable/')){
    const id=url.pathname.split('/').at(-1),stored=uploads.get(id)
    if(input.method==='HEAD')return response(input.id,Buffer.alloc(0),200,{'upload-offset':String(stored.length)})
    assert.equal(Number(input.headers['Upload-Offset']),stored.length);assert.ok(body.length<=6*1024*1024)
    uploads.set(id,Buffer.concat([stored,body]));return response(input.id,Buffer.alloc(0),204,{'upload-offset':String(stored.length+body.length)})
  }
  if(downloads.has(url.href)){
    const original=downloads.get(url.href),data=wrongChecksum?Buffer.alloc(original.length,63):original,result=response(input.id,data)
    bodies.get(result.bodyID).download=true;return result
  }
  if(url.origin==='https://market.fixture.test'){
    if(url.pathname==='/dashboard')return response(input.id,{configured:true,signedIn:true,publisher:null,reviewer:false,releases:[]})
    if(url.pathname==='/releases'&&input.method==='POST'){assert.equal(typeof JSON.parse(body).artifactBase64,'string');return response(input.id,{id:crypto.randomUUID()})}
    if(url.pathname.endsWith('/review-bundle'))return response(input.id,Buffer.from(pickedArchive.data,'base64'))
  }
  throw new Error('Unexpected fixture request '+input.method+' '+url.href)
}

export async function runMarketTests({invoke,backend,environment,require}){
  assert.equal((await invoke('studyMarket:request',{action:'dashboard',input:{}})).configured,false)
  assert.equal((await invoke('marketplace:dashboard',{})).configured,false)
  assert.deepEqual(await invoke('feedback:send',{kind:'bug',body:'unconfigured',includeAppInfo:false}),{ok:false,reason:'unavailable'})
  assert.equal(requests.length,0)
  state=structuredClone(configured)
  assert.equal((await invoke('studyMarket:request',{action:'dashboard',input:{}})).signedIn,true)
  assert.equal((await invoke('marketplace:dashboard',{})).configured,true)
  const course=await invoke('courses:create',{name:'마켓 원본',color:'blue'}),material=await invoke('materials:writeFile',{courseId:course.id,dirRelPath:'',fileName:'요약.md',encoding:'utf8',data:'# 보존할 원문\n\n![첨부](image.png)'})
  await invoke('materials:writeFile',{courseId:course.id,dirRelPath:'',fileName:'image.png',encoding:'base64',data:png.toString('base64')})
  const {PDFDocument,degrees}=require('pdf-lib'),pdf=await PDFDocument.create(),page=pdf.addPage([700,900]);page.setCropBox(50,50,600,800);page.setRotation(degrees(90))
  await invoke('materials:writeFile',{courseId:course.id,dirRelPath:'',fileName:'강의.pdf',encoding:'base64',data:Buffer.from(await pdf.save()).toString('base64')})
  await invoke('drawings:create',{courseId:course.id,relPath:'강의.pdf',page:1,kind:'ink',data:{points:[{x:.1,y:.1,p:.5},{x:.4,y:.2,p:1}]},style:{color:'blue',width:.006,opacity:1}})
  const bundle=await invoke('studyMarket:prepare',{courseId:course.id,relPaths:[material.relPath,'강의.pdf']})
  assert.equal(bundle.files.length,3,'Original Markdown image dependencies must join the snapshot')
  const note=bundle.files.find(file=>file.path===material.relPath),doc=bundle.files.find(file=>file.path==='강의.pdf')
  const previewSource=await invoke('studyMarket:previewSource',{bundleId:bundle.id,fileId:doc.id,page:1}),copy=await PDFDocument.load(Buffer.from(previewSource.base64,'base64'))
  assert.equal(copy.getPageCount(),1);assert.equal(copy.getPage(0).getRotation().angle,90);assert.equal(copy.getPage(0).getCropBox().x,50)
  fs.writeFileSync(path.join(course.folderPath,material.relPath),'원본 이후 변경')
  assert.match((await invoke('studyMarket:previewSource',{bundleId:bundle.id,fileId:note.id})).text,/보존할 원문/)
  pickedPreview={dataUrl:`data:image/png;base64,${png.toString('base64')}`}
  assert.deepEqual(await invoke('studyMarket:pickPreviewImage',{}),pickedPreview)
  const preview=await invoke('studyMarket:preview',{bundleId:bundle.id,fileId:note.id,...pickedPreview});assert.equal(preview.file.preview,true)
  await invoke('studyMarket:discardPreview',{bundleId:bundle.id,fileId:preview.file.id})
  await assert.rejects(invoke('studyMarket:previewSource',{bundleId:bundle.id,fileId:note.id,text:'없던 원문'}),/문장/)
  fs.symlinkSync(path.join(course.folderPath,material.relPath),path.join(course.folderPath,'링크.md'))
  await assert.rejects(invoke('studyMarket:prepare',{courseId:course.id,relPaths:['링크.md']}),/심볼릭/)
  await assert.rejects(invoke('studyMarket:prepare',{courseId:course.id,relPaths:['../secret.txt']}),/경로/)
  await invoke('studyMarket:upload',{bundleId:bundle.id,versionId:'version',fileIds:[note.id],publish:false})
  assert.ok([...uploads.values()].some(bytes=>bytes.toString().includes('보존할 원문')))
  const large=Buffer.alloc(6*1024*1024+17,81)
  fs.writeFileSync(path.join(course.folderPath,'large.txt'),large)
  const largeBundle=await invoke('studyMarket:prepare',{courseId:course.id,relPaths:['large.txt']})
  await invoke('studyMarket:upload',{bundleId:largeBundle.id,versionId:'version',fileIds:[largeBundle.files[0].id],publish:false})
  assert.ok([...uploads.values()].some(bytes=>bytes.length===large.length&&sha(bytes)===sha(large)),'TUS must preserve positional reads across the six MiB chunk boundary')
  await invoke('studyMarket:discardBundle',{bundleId:largeBundle.id})
  state={...state,accountID:'fixture-user-b'}
  await assert.rejects(invoke('studyMarket:previewSource',{bundleId:bundle.id,fileId:note.id}),/준비한 자료/)
  state=structuredClone(configured)
  await invoke('studyMarket:discardBundle',{bundleId:bundle.id});await assert.rejects(invoke('studyMarket:previewSource',{bundleId:bundle.id,fileId:note.id}),/준비한 자료/)

  const bytes=Buffer.from('# 구매한 원문\n\n원자적 파일 가져오기'),url='https://fixture.supabase.co/storage/v1/object/sign/market/note'
  downloads.set(url,bytes);manifest=[{id:crypto.randomUUID(),path:'내용.md',bytes:bytes.length,sha256:sha(bytes),mime:'text/markdown',url}]
  const imported=await invoke('studyMarket:import',{orderId:'paid-order-fixture',courseId:course.id,acceptSupply:true})
  assert.match(fs.readFileSync(path.join(course.folderPath,imported.relPath,'내용.md'),'utf8'),/구매한 원문/)
  const purchases=path.join(course.folderPath,'구매 자료'),before=fs.readdirSync(purchases)
  wrongChecksum=true;await assert.rejects(invoke('studyMarket:import',{orderId:'wrong-checksum',courseId:course.id,acceptSupply:true}),/무결성/);wrongChecksum=false
  assert.deepEqual(fs.readdirSync(purchases),before,'Failed import must not publish or leak a temporary folder')
  failDownload=true;await assert.rejects(invoke('studyMarket:import',{orderId:'cancelled',courseId:course.id,acceptSupply:true}),/cancellation/);failDownload=false
  assert.ok(cancelled.length>0);assert.deepEqual(fs.readdirSync(purchases),before)
  const originalManifest=manifest,secondURL=url+'-second';downloads.set(secondURL,bytes)
  manifest=[...manifest,{...manifest[0],id:crypto.randomUUID(),path:'두번째.md',url:secondURL}];switchDuringRead=true
  await assert.rejects(invoke('studyMarket:import',{orderId:'account-switch',courseId:course.id,acceptSupply:true}),/initial account binding/)
  state=structuredClone(configured);manifest=originalManifest;assert.deepEqual(fs.readdirSync(purchases),before,'Account switch must roll back a multi-file import')
  await assert.rejects(invoke('studyMarket:openCheckout',{orderId:'untrusted-checkout'}),/결제 페이지/)
  const beforeBad=requests.length;manifest=[{...manifest[0],url:'https://evil.example/file'}]
  await assert.rejects(invoke('studyMarket:import',{orderId:'untrusted-storage',courseId:course.id,acceptSupply:true}),/저장소/)
  assert.equal(requests.length,beforeBad+1,'Untrusted storage must be rejected before file fetch')

  assert.deepEqual(await invoke('marketplace:submit',{changelog:'cancelled'}),{canceled:true})
  const Zip=require('jszip'),zip=new Zip();zip.file('manifest.json',JSON.stringify({manifestVersion:2,id:'fixture.plugin',name:'Fixture plugin',version:'1.0.0',minAppVersion:'0.1.0',main:'main.js',permissions:[],contributes:{}}));zip.file('main.js','throw new Error("never execute submitted code")')
  pickedArchive={data:(await zip.generateAsync({type:'nodebuffer',compression:'DEFLATE'})).toString('base64')}
  assert.deepEqual(await invoke('marketplace:submit',{changelog:'validated archive fixture'}),{canceled:false})
  assert.deepEqual(await invoke('marketplace:reviewBundle',{id:crypto.randomUUID()}),{canceled:true})
  zip.file('not-allowed.exe','binary');pickedArchive={data:(await zip.generateAsync({type:'nodebuffer'})).toString('base64')}
  const beforeUnsafe=requests.length;await assert.rejects(invoke('marketplace:submit',{changelog:'reject'}),/Unsupported/);assert.equal(requests.length,beforeUnsafe)
  const bomb=new Zip();bomb.file('main.js','x'.repeat(8*1024*1024+1));pickedArchive={data:(await bomb.generateAsync({type:'nodebuffer',compression:'DEFLATE'})).toString('base64')}
  await assert.rejects(invoke('marketplace:submit',{changelog:'expanded limit'}),/size limit/)
  for(let index=0;index<3;index++)assert.deepEqual(await invoke('feedback:send',{kind:'bug',body:'z'.repeat(5000),includeAppInfo:false}),{ok:true})
  assert.deepEqual(await invoke('feedback:send',{kind:'bug',body:'rate guard',includeAppInfo:false}),{ok:false,reason:'rate-limited'})
  const feedback=requests.filter(req=>req.url.endsWith('/rpc/submit_feedback')).map(req=>JSON.parse(Buffer.from(req.bodyBase64,'base64')))
  assert.equal(feedback[0].p_body.length,4000);assert.equal(feedback[0].p_app_version,null);assert.equal(feedback[0].p_os,null)
  assert.ok(requests.every(req=>req.accountID==='fixture-user-a'))
  assert.ok(requests.filter(req=>req.headers.Authorization).every(req=>req.headers.Authorization==='Bearer native-keychain'))
  assert.equal(bodies.size,0)
  console.log('Market fixture passed: original snapshot/dependencies/rotated PDF, preview/discard, symlink refusal, TUS upload, account separation, atomic verified imports, cancellation, untrusted URL rejection, bounded ZIP validation, feedback privacy/rate guard; no network used')
}
