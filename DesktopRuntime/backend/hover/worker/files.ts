import { Buffer } from 'buffer'
import { OFFICE_RUNTIME_VERSION } from './version'
let files=new Map<string,{bytes:Uint8Array;size:number}>(),source:Uint8Array,sha256=''
export function setSnapshot(value:any){
  const entries=value.files as Array<{path:string;bytes:ArrayBuffer;size:number}>
  if(!Array.isArray(entries)||entries.length<1||entries.length>2)throw new Error('Invalid snapshot')
  files=new Map(entries.map(entry=>[entry.path,{bytes:new Uint8Array(entry.bytes),size:entry.size}]));source=files.get('/source/file'+value.extension)?.bytes!
  if(!source||source.length>32*1024*1024||!String(value.sha256).match(/^[a-f0-9]{64}$/))throw new Error('Invalid source snapshot')
  sha256=value.sha256
  const cached=files.get('/cache/file.pptx');if(cached)files.set(`/userdata/presentation-runtime/cache/${OFFICE_RUNTIME_VERSION}/${sha256}.pptx`,cached)
}
export async function open(path:string,flags:string){
  if(flags!=='r')throw new Error('Snapshot is read-only')
  const file=files.get(path);if(!file)throw Object.assign(new Error('Snapshot file missing'),{code:'ENOENT'});const bytes=file.bytes
  let closed=false;const check=()=>{if(closed)throw new Error('Snapshot closed')}
  return{async stat(){check();return{size:file.size,isFile:()=>true}},async read(target:Uint8Array,offset:number,length:number,position:number){check();if(!Number.isInteger(position)||position<0||offset<0||length<0||offset+length>target.length)throw new Error('Invalid snapshot range');const slice=bytes.subarray(position,position+length);target.set(slice,offset);return{bytesRead:slice.length,buffer:target}},async close(){closed=true}}
}
// The only original synchronous hash operation identifies the PPT source.
// Native computes SHA256 over the immutable captured bytes, then this seam
// accepts exactly those bytes; no independent filesystem or crypto access.
export function createHash(algorithm:string){
  if(algorithm!=='sha256')throw new Error('Unsupported snapshot hash')
  let offset=0;return{update(bytes:Uint8Array){for(const byte of bytes)if(byte!==source[offset++])throw new Error('Hash input differs from snapshot');return this},digest(encoding:string){if(offset!==source.length||encoding!=='hex')throw new Error('Invalid snapshot hash');return sha256}}
}
