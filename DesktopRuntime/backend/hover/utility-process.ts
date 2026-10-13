import { randomUUID } from '../shims/crypto'
// Preserve the original utility-process queue, timeout, idle disposal and stale
// reply guards. Only the disposable process primitive changes on iPad.
export const utilityProcess={fork(_path:string,_args:unknown[],_options:unknown){
  const workerID=randomUUID(),listeners=new Map<string,Array<(value:any)=>void>>()
  let killed=false
  const invoke=(channel:string,request:any)=>(globalThis as any).__bandalPlatform.invoke(channel,request)
  const emit=(name:string,value?:any)=>{if(!killed)for(const fn of listeners.get(name)??[])fn(value)}
  const worker={stdout:undefined,stderr:undefined,on(name:string,fn:(value:any)=>void){const list=listeners.get(name)??[];list.push(fn);listeners.set(name,list);return worker},
    postMessage(message:any){if(killed)throw new Error('Preview worker terminated');void invoke('native:hoverExtract',{workerID,input:message.input}).then((content:any)=>emit('message',{id:message.id,content}),()=>emit('exit',1))},
    kill(){if(killed)return;killed=true;listeners.clear();void invoke('native:hoverTerminate',{workerID}).catch(()=>undefined);return true}
  };return worker
}}
