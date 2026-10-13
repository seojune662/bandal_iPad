import './globals'
import { setSnapshot } from './files'
import { extractMaterialHoverPreview } from '../../../upstream/src/main/features/materials/hoverPreviewExtract'
const worker=globalThis as any
worker.onmessage=async(event:any)=>{
  const snapshot=event.data
  try{
    setSnapshot(snapshot)
    const content=await extractMaterialHoverPreview({absolutePath:'/source/file'+snapshot.extension,extension:snapshot.extension,userData:'/userdata'})
    worker.postMessage({id:snapshot.id,content})
  }catch{worker.postMessage({id:snapshot.id,content:{kind:'unsupported',reason:'unreadable',message:'내용 미리보기를 불러오지 못했어요.'}})}
}
