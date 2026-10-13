/** JSZip's browser worker has the same bounded data events as nodeStream.
 * Pause immediately at the original archive validator's byte limit. */
export function createZipEntryStream(entry:any) {
  const worker=entry.internalStream('uint8array'),handlers=new Map<string,Array<(value?:any)=>void>>()
  let stopped=false
  const emit=(name:string,value?:any)=>{if(!stopped)for(const fn of handlers.get(name)??[])fn(value)}
  worker.on('data',(chunk:Uint8Array)=>emit('data',chunk)).on('error',(error:Error)=>emit('error',error)).on('end',()=>emit('end'))
  const stream={on(name:string,fn:(value?:any)=>void){const list=handlers.get(name)??[];list.push(fn);handlers.set(name,list);return stream},destroy(){stopped=true;worker.pause();handlers.clear();return stream}}
  void Promise.resolve().then(()=>{if(!stopped)worker.resume()})
  return stream
}
