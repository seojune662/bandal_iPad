import {createCatalogService} from '../upstream/src/main/features/plugins/catalog/catalogService'
import {createCatalogInstaller} from '../upstream/src/main/features/plugins/catalog/catalogInstall'
import {getSettings} from '../upstream/src/main/settingsStore'
import {env,emit} from './native'
import {cloudFetch,cloudInvoke,type CloudState} from './cloud'

export function installPluginCatalog({handle,plugins,packs}:any){
  let marketplace:string|null=null
  const fetch=(url:string,init:RequestInit,entry?:{id:string;sourceUrl:string;sha256:string})=>cloudFetch(url,init,null,{
    request:input=>cloudInvoke('native:catalogRequest',{...input,kind:entry?'artifact':'index',sourceUrl:entry?.sourceUrl??url,...(entry?{entryID:entry.id,sha256:entry.sha256}:{})}),
    read:bodyID=>cloudInvoke('native:catalogRead',{bodyID}),cancel:id=>cloudInvoke('native:catalogCancel',{id})
  })
  const catalog=createCatalogService({userDataDir:env().userDataPath,getMarketplaceUrl:()=>marketplace,
    getPluginSources:()=>[...getSettings().pluginSources,...(marketplace?[`${marketplace}/index.json`]:[])],fetch})
  handle('plugins:catalog',async(req:any)=>{
    marketplace=(await cloudInvoke<CloudState>('native:cloudState')).marketplaceURL
    return catalog.get(req.refresh)
  })
  handle('plugins:installFromCatalog',async(req:any)=>{
    const snapshot=catalog.current(),entry=snapshot?.entries.find(item=>item.sourceUrl===req.sourceUrl&&item.id===req.id)
    if(!entry)throw new Error('카탈로그를 먼저 새로고침하세요')
    // Freeze the selection for this installation even if another view refreshes
    // the catalog meanwhile. Native rechecks its current source before download.
    const installer=createCatalogInstaller({catalog:{current:()=>snapshot},pluginStore:plugins,packStore:packs,
      fetch:(url,init)=>fetch(url,init,entry),appVersion:()=>env().version??'0.84.1',tempDir:env().tempPath})
    const installed=await installer.install(req.sourceUrl,req.id)
    if(installed.kind==='extension'){
      // Imported executable plugins remain disabled on iPad. Approval/execution
      // cannot be inferred from a successful verified download.
      plugins.setEnabled(installed.plugin.manifest.id,false)
      installed.plugin=plugins.get(installed.plugin.manifest.id)!
      installed.warnings=[...installed.warnings,'iPad에서는 실행형 플러그인을 실행할 수 없습니다. 설치 파일과 설정만 보관합니다.']
      emit('plugins:changed',{plugins:plugins.list()})
    }
    return installed
  })
}
