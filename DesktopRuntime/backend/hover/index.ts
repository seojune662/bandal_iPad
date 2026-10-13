import { createMaterialHoverPreviewService } from '../../upstream/src/main/features/materials/hoverPreview'
import { env } from '../native'
export function installHoverPreview(deps:{handle:(channel:string,fn:(request:any)=>any)=>void;materials:any}) {
  const service=createMaterialHoverPreviewService({materials:deps.materials,userData:env().userDataPath})
  deps.handle('materials:hoverPreview',request=>service.read(request))
  return service
}
