import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
let calls=[],kills=[],pending,blockNext=false,large=false
export async function hoverPlatform(channel,input){
  if(channel==='native:hoverTerminate'){kills.push(input.workerID);return{ok:true}}
  if(channel!=='native:hoverExtract')throw new Error('Unexpected preview boundary '+channel)
  calls.push(input)
  if(blockNext){blockNext=false;return new Promise(resolve=>{pending=resolve})}
  return{kind:'text',text:large?'x'.repeat(5*1024*1024):path.basename(input.input.absolutePath),truncated:false}
}
export async function runHoverTests({invoke,backend,environment}){
  const course=await invoke('courses:create',{name:'Hover originals',color:'blue'}),folder=course.folderPath
  assert.equal(typeof folder,'string')
  const write=(name,bytes)=>fs.writeFileSync(path.join(folder,name),bytes)
  const read=relPath=>invoke('materials:hoverPreview',{courseId:course.id,relPath})
  write('original.md','# 한글 원문\n**굵게**');assert.equal((await read('original.md')).content.kind,'markdown');assert.match((await read('original.md')).content.text,/굵게/)
  write('partial.txt',Buffer.concat([Buffer.alloc(65534),Buffer.from('한글')]))
  const partial=(await read('partial.txt')).content;assert.equal(partial.text,'');assert.equal(partial.truncated,true,'Incomplete UTF-8 at 64KiB must be omitted')
  write('original.pdf','%PDF-1.7\n');assert.deepEqual((await read('original.pdf')).content,{kind:'pdf'})
  write('movie.mp4',Buffer.from([0]));assert.deepEqual((await read('movie.mp4')).content,{kind:'video'})
  assert.equal(calls.length,0,'Text/PDF/video must use original direct/renderer preview paths')
  write('photo.png',Buffer.from([1]));await Promise.all([read('photo.png'),read('photo.png')]);assert.equal(calls.length,1,'Concurrent same revision is deduplicated')
  await read('photo.png');assert.equal(calls.length,1,'Cached same revision')
  write('photo.png',Buffer.from([1,2]));await read('photo.png');assert.equal(calls.length,2,'Modified file invalidates cache')
  for(let index=0;index<33;index++){write(`cache-${index}.docx`,Buffer.from([index]));await read(`cache-${index}.docx`)}
  const before=calls.length;await read('cache-0.docx');assert.equal(calls.length,before+1,'Original 32-entry LRU evicts oldest')
  large=true
  for(let index=0;index<4;index++){write(`large-${index}.docx`,Buffer.from([index]));await read(`large-${index}.docx`)}
  const bytesBefore=calls.length;await read('large-0.docx');assert.equal(calls.length,bytesBefore+1,'Original 16MiB cache byte budget evicts oversized aggregate')
  large=false
  const big=path.join(folder,'oversize.docx'),fd=fs.openSync(big,'w');fs.ftruncateSync(fd,32*1024*1024+1);fs.closeSync(fd)
  assert.equal((await read('oversize.docx')).content.reason,'too-large')
  await assert.rejects(read('../outside.docx'))
  blockNext=true
  const started=Date.now(),requests=[]
  for(let index=0;index<10;index++){write(`queue-${index}.docx`,Buffer.from([index]));requests.push(read(`queue-${index}.docx`))}
  const overflow=await requests[1];assert.equal(overflow.content.reason,'timeout');assert.ok(Date.now()-started<2500,'Ninth queued request evicts oldest queued before active timeout')
  const results=await Promise.all(requests);assert.equal(results[0].content.reason,'timeout');assert.equal(results[9].content.text,'queue-9.docx');assert.ok(Date.now()-started>=2900);assert.ok(Date.now()-started<6000)
  assert.ok(kills.length);pending({kind:'text',text:'stale terminated reply',truncated:false})
  assert.equal((await read('queue-9.docx')).content.text,'queue-9.docx')
  // Fixtures terminate the current idle worker immediately; original service
  // keeps its real ten-second idle timer, which is unref'd on Node.
  await hoverPlatform('native:hoverTerminate',{workerID:calls.at(-1).workerID})
  console.log('PASS: original hover text/PDF/media, UTF8 cutoff, revision dedup, LRU32/16MiB, 32MiB input refusal, queue8, actual3s timeout, stale-worker reply guard')
}
