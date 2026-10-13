import { createPresentationService } from '../../upstream/src/main/features/presentation/presentationService'
import { createPdfExporter } from '../../upstream/src/main/features/pdf/exportPdf'
import { env } from '../native'
import { nativeFontPath } from './fonts'
export function installPresentation(deps:any){
  const exporter=createPdfExporter({getCourseFolder:(id:string)=>deps.courses.getFolder(id),listDrawings:(id:string,path:string)=>deps.drawings.listForFile(id,path),listAnnotations:(id:string,path:string)=>deps.annotations.listForFile({courseId:id,relPath:path}),resolveFontPath:nativeFontPath})
  const service=createPresentationService({userData:env().userDataPath,materials:deps.materials,exporter,changed:id=>{deps.materials.invalidateTree(id);deps.changed(id)}}),handle=deps.handle
  handle('presentation:runtime',()=>service.runtime.getState());handle('presentation:installRuntime',()=>service.runtime.install())
  handle('presentation:cancelRuntime',async()=>{await service.runtime.cancelInstall();return{ok:true}})
  handle('presentation:prepare',(req:any)=>service.prepare(req));handle('presentation:cancelPrepare',async(req:any)=>{await service.runtime.cancel(req.requestId);return{ok:true}})
  handle('presentation:pdfStart',(req:any)=>service.start(req));handle('presentation:pdfPage',async(req:any)=>{await service.append(req);return{ok:true}})
  handle('presentation:pdfFinish',(req:any)=>service.finish(req.sessionId));handle('presentation:pdfCancel',async(req:any)=>{await service.cancel(req.sessionId);return{ok:true}})
}
