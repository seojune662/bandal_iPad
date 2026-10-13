import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import crypto from 'node:crypto'
import {deflateRawSync} from 'node:zlib'
import {dependencies} from '../../scripts/dependencies.mjs'
const{require}=dependencies(),{webkit}=require('@playwright/test'),Zip=require('jszip'),xlsx=require('xlsx')
let script=await readFile(new URL('../dist/hover-worker.js',import.meta.url),'utf8')
if(process.env.HOVER_DEBUG)script=script.replace('return error instanceof PreviewLimitError','console.error(String(error), error.stack); return error instanceof PreviewLimitError')
const browser=await webkit.launch()
const png=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVioAAAAASUVORK5CYII=','base64')
try{
  const page=await browser.newPage()
  if(process.env.HOVER_DEBUG)page.on('console',message=>console.error(message.text()))
  await page.setContent('<meta http-equiv="Content-Security-Policy" content="default-src \'none\';script-src blob:;worker-src blob:;connect-src \'none\'">')
  async function extract(extension,bytes,cached,source=script,timeout=3000){
    const files=[{path:'/source/file'+extension,data:bytes.toString('base64'),size:bytes.length}]
    if(cached)files.push({path:'/cache/file.pptx',data:cached.toString('base64'),size:cached.length})
    return page.evaluate(async({source,files,extension,sha256,timeout})=>{
      const url=URL.createObjectURL(new Blob([source],{type:'text/javascript'})),worker=new Worker(url);URL.revokeObjectURL(url)
      return new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>{worker.terminate();resolve({kind:'unsupported',reason:'timeout'})},timeout)
        worker.onerror=event=>{clearTimeout(timer);worker.terminate();reject(new Error(event.message))}
        worker.onmessage=event=>{clearTimeout(timer);worker.terminate();resolve(event.data.content)}
        const snapshots=files.map(file=>{const raw=atob(file.data),bytes=Uint8Array.from(raw,c=>c.charCodeAt(0));return{path:file.path,size:file.size,bytes:bytes.buffer}})
        worker.postMessage({id:1,extension,sha256,files:snapshots},snapshots.map(file=>file.bytes))
      })
    },{source,files,extension,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),timeout})
  }
  const zip=async entries=>{const value=new Zip();for(const[name,bytes]of Object.entries(entries))value.file(name,bytes);return value.generateAsync({type:'nodebuffer',compression:'DEFLATE'})}
  const docx=await zip({'word/document.xml':'<w:document><w:p><w:r><w:t>한글 Word 본문 &amp; 원문</w:t></w:r></w:p></w:document>'})
  const word=await extract('.docx',docx);assert.equal(word.kind,'text',JSON.stringify(word));assert.match(word.text,/한글 Word 본문 & 원문/)
  const pptx=await zip({'ppt/presentation.xml':'<p:presentation><p:sldIdLst><p:sldId r:id="r1"/></p:sldIdLst></p:presentation>','ppt/_rels/presentation.xml.rels':'<Relationships><Relationship Id="r1" Target="slides/slide1.xml"/></Relationships>','ppt/slides/slide1.xml':'<p:sp><a:p><a:r><a:t>첫번째 발표 본문</a:t></a:r></a:p></p:sp>','docProps/thumbnail.png':png})
  const slides=await extract('.pptx',pptx);assert.equal(slides.kind,'slides');assert.equal(slides.slideCount,1);assert.match(slides.text,/발표/);assert.ok(slides.imageDataUrl.startsWith('data:image/png;'))
  const legacy=Buffer.from([0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1])
  assert.equal((await extract('.ppt',legacy)).reason,'needs-conversion')
  assert.equal((await extract('.ppt',legacy,pptx)).text,slides.text)
  const book=xlsx.utils.book_new();xlsx.utils.book_append_sheet(book,xlsx.utils.aoa_to_sheet(Array.from({length:12},(_,r)=>Array.from({length:8},(_,c)=>`행${r}열${c}`))),'첫 시트')
  for(const type of ['xlsx','xls']){const result=await extract('.'+type,xlsx.write(book,{type:'buffer',bookType:type==='xls'?'biff8':'xlsx'}));assert.equal(result.kind,'table',JSON.stringify(result));assert.equal(result.rows.length,8);assert.equal(result.rows[0].length,6);assert.equal(result.rows[0][0],'행0열0');assert.equal(result.truncated,true)}
  assert.deepEqual((await extract('.csv',Buffer.from('이름,값\n한글,12'))).rows,[['이름','값'],['한글','12']])
  const hwpx=await zip({'Contents/section0.xml':'<hp:p><hp:run><hp:t>한글 HWPX 본문</hp:t></hp:run></hp:p>'});assert.match((await extract('.hwpx',hwpx)).text,/HWPX/)
  const container=xlsx.CFB.utils.cfb_new(),header=Buffer.alloc(256),text=Buffer.from('압축된 HWP 원문','utf16le'),record=Buffer.alloc(4+text.length)
  header.write('HWP Document File');header.writeUInt32LE(1,36);record.writeUInt32LE((text.length<<20)|67);text.copy(record,4)
  xlsx.CFB.utils.cfb_add(container,'FileHeader',header);xlsx.CFB.utils.cfb_add(container,'BodyText/Section0',deflateRawSync(record))
  assert.match((await extract('.hwp',Buffer.from(xlsx.CFB.write(container,{type:'buffer'})))).text,/압축된 HWP 원문/)
  const image=await extract('.png',png);assert.equal(image.width,1);assert.equal(image.height,1);assert.equal(image.sourceDataUrl,'data:image/png;base64,'+png.toString('base64'))
  assert.equal((await extract('.svg',Buffer.from('<svg width="30" height="20"><script>alert(1)</script></svg>'))).reason,'unreadable')
  assert.equal((await extract('.docx',Buffer.from('PK broken archive'))).reason,'unreadable')
  const bomb=await zip({'word/document.xml':'x'.repeat(9*1024*1024)})
  // Lie about expanded sizes in local/central headers. Streaming limits must
  // reject actual output before allocating the full expanded entry.
  for(let i=0;i<bomb.length-24;i++){if(bomb.readUInt32LE(i)===0x04034b50)bomb.writeUInt32LE(1,i+22);if(bomb.readUInt32LE(i)===0x02014b50)bomb.writeUInt32LE(1,i+24)}
  assert.equal((await extract('.docx',bomb)).reason,'too-large')
  assert.equal((await extract('.xlsx',bomb)).reason,'too-large','SheetJS must not expand entries based on forged metadata')
  const started=Date.now();assert.equal((await extract('.docx',docx,undefined,'onmessage=()=>{while(true){}}',100)).reason,'timeout');assert.ok(Date.now()-started<2000)
  assert.equal(await page.evaluate(()=>1+1),2,'Terminating a hung parser must leave the page responsive')
  const probe='onmessage=()=>postMessage({content:{kind:"text",text:[typeof fetch,typeof XMLHttpRequest,typeof WebSocket,typeof importScripts].join(",")}})'
  assert.equal((await extract('.docx',docx,undefined,script+'\n'+probe)).text,'undefined,undefined,undefined,undefined')
  console.log('PASS: actual WebKit Worker DOCX/PPTX/cachedPPT/XLSX/XLS/CSV/HWP/HWPX/image, activeSVG/malformedZIP refusal, lying ZIP bounded expansion, terminated parser responsiveness, no network APIs')
}finally{await browser.close()}
