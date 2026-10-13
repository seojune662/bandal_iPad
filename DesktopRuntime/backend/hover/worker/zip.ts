import { Buffer } from 'buffer'
export async function readWorkerZipEntry(entry:any,limit:number,limitError:()=>Error):Promise<Buffer> {
  const chunks:Uint8Array[]=[];let size=0,done=false
  await new Promise<void>((resolve,reject)=>{
    const stream=entry.internalStream('uint8array')
    stream.on('data',(chunk:Uint8Array)=>{
      if(done)return;size+=chunk.length
      if(size>limit){done=true;stream.pause();chunks.length=0;reject(limitError());return}
      chunks.push(chunk)
    }).on('error',(error:Error)=>{if(!done){done=true;reject(error)}}).on('end',()=>{if(!done){done=true;resolve()}}).resume()
  })
  return Buffer.concat(chunks)
}

// SheetJS synchronously expands workbook parts itself. Validate actual output
// before handing it the archive, because forged ZIP headers are not a budget.
export async function validateWorkerWorkbookZip(zip:any,limitError:()=>Error):Promise<void> {
  let remaining=64*1024*1024
  for(const entry of Object.values(zip.files) as any[]){
    if(entry.dir)continue
    const bytes=await readWorkerZipEntry(entry,Math.min(8*1024*1024,remaining),limitError)
    remaining-=bytes.length
  }
}
