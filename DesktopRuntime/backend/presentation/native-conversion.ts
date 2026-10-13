import { Buffer } from '../shims/buffer'
const platform=(channel:string,request:any={})=>{const invoke=(globalThis as any).__bandalPlatform?.invoke;if(!invoke)throw new Error('Native presentation conversion is unavailable');return invoke(channel,request)}
export function createConversionRuntime(_userData:string){return{
  getState:()=>platform('native:presentationRuntime'),
  install:()=>platform('native:presentationConfigure'),
  cancelInstall:()=>platform('native:presentationCancel',{requestId:null}),
  cancel:(requestId:string)=>platform('native:presentationCancel',{requestId}),
  async normalize(path:string,requestId:string){const result=await platform('native:presentationNormalize',{path,requestId}),bytes=Buffer.from(result.data,'base64');if(bytes.length>128*1024*1024||bytes[0]!==0x50||bytes[1]!==0x4b)throw new Error('The converter did not return a valid PPTX package');return bytes}
}}
