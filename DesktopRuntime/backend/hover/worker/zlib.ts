import { Inflate } from 'pako'
import { Buffer } from 'buffer'
export function inflateRawSync(bytes:Uint8Array,options:{maxOutputLength?:number}={}){
  const limit=options.maxOutputLength??8*1024*1024,chunks:Uint8Array[]=[];let size=0
  const decoder=new Inflate({raw:true,chunkSize:64*1024})
  decoder.onData=(chunk:Uint8Array)=>{size+=chunk.length;if(size>limit)throw new Error('Expanded HWP exceeds preview limit');chunks.push(chunk)}
  decoder.push(bytes,true);if(decoder.err)throw new Error('Invalid compressed HWP section')
  return Buffer.concat(chunks)
}
