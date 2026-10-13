import { Buffer } from 'buffer'
const worker=globalThis as any
worker.Buffer=Buffer
// JSZip's legacy scheduler probes window.postMessage when importScripts is
// absent. Supply the worker-safe primitive before removing network loading.
worker.setImmediate=(callback:(...args:any[])=>void,...args:any[])=>setTimeout(()=>callback(...args),0)
worker.clearImmediate=(id:number)=>clearTimeout(id)
for(const name of ['fetch','XMLHttpRequest','WebSocket','EventSource','importScripts'])Object.defineProperty(worker,name,{value:undefined,writable:false,configurable:false})
