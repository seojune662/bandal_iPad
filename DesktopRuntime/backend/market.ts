import { createStudyMarketClient } from '../upstream/src/main/features/studyMarket/client'
import { createStudyMarketBundles } from '../upstream/src/main/features/studyMarket/bundles'
import { registerStudyMarketHandlers } from '../upstream/src/main/ipc/studyMarketHandlers'
import { STUDY_MARKET_CHANNELS } from '../upstream/src/shared/ipc/studyMarketContract'
import { createMarketplaceClient } from '../upstream/src/main/features/plugins/marketplaceClient'
import { inspectPluginArchive } from '../upstream/src/shared/plugins/archive'
import { createFeedbackService, createFeedbackRateGuard } from '../upstream/src/main/features/feedback/feedbackService'
import { getSettings } from '../upstream/src/main/settingsStore'
import { Buffer } from './shims/buffer'
import { env, emit } from './native'
import { boundCloudFetch, cloudSession, cloudInvoke, type CloudState } from './cloud'

type Handler = (request:any)=>unknown|Promise<unknown>
export function installMarket(deps:{handle:(channel:string,fn:Handler)=>void;courses:any;materials:any;annotations:any;pdfExport:(input:any,path:string)=>Promise<void>}) {
  const scopes = new Map<string, ReturnType<typeof createScope>>()
  const rateGuard = createFeedbackRateGuard()
  // Each scope closes over a fixed account. A second account cannot resume the
  // first account's TUS upload or access its prepared bundles. Native checks the
  // same account again for every HTTP request, including continuation chunks.
  function createScope(state:CloudState) {
    const fetch = boundCloudFetch(state)
    const client = createStudyMarketClient({getClient:()=>cloudSession(state),fetch,config:()=>state.supabase})
    const marketplace = createMarketplaceClient({getClient:()=>cloudSession(state),fetch,url:()=>state.marketplaceURL})
    const bundles = createStudyMarketBundles({
      getCourseFolder:id=>deps.courses.getFolder(id),exportAnnotated:deps.pdfExport,
      listAnnotations:(courseId,relPath)=>deps.annotations.listForFile({courseId,relPath}),fetch,tempRoot:env().tempPath,
      sanitizePreview:async bytes=>Buffer.from(await cloudInvoke<string>('native:marketSanitizePreview',{dataUrl:`data:image/png;base64,${bytes.toString('base64')}`}), 'base64')
    })
    const handlers = new Map<string,Handler>()
    registerStudyMarketHandlers((channel,fn)=>{handlers.set(channel,fn as Handler)}, {
      client,bundles,
      createCourse:name=>{const course=deps.courses.create({name,color:'blue'});emit('courses:changed',{});return course},
      changed:courseId=>{deps.materials.invalidateTree(courseId);emit('materials:changed',{courseId});emit('courses:changed',{})},
      openExternal:async url=>{await cloudInvoke('shell:openExternal',{url})},
      pickPreviewImage:async()=>{const picked=await cloudInvoke<{dataUrl:string}|null>('native:marketPickPreview');return picked?{dataUrl:picked.dataUrl}:null}
    })
    // Keep the original service's rate/body/privacy semantics; this minimal RPC
    // adapter exposes only its fixed endpoint and never receives an access token.
    const feedbackClient = state.supabase ? {async rpc(name:string,input:any) {
      if(name!=='submit_feedback')throw new Error('Unsupported feedback operation')
      const response=await fetch(`${state.supabase!.url}/rest/v1/rpc/submit_feedback`,{
        method:'POST',redirect:'error',signal:AbortSignal.timeout(30_000),
        headers:{'Content-Type':'application/json',apikey:state.supabase!.publishableKey,...(state.signedIn?{Authorization:'Bearer native-keychain'}:{})},body:JSON.stringify(input)
      })
      const data=await response.json().catch(()=>null)
      return{data:response.ok?data:null,error:response.ok?null:data??{message:'Feedback unavailable'}}
    }} : null
    const feedback=createFeedbackService({getClient:()=>feedbackClient as any,rateGuard,appVersion:env().version??'0.83.1',platform:env().platform,getPalette:()=>getSettings().palette})
    return {handlers,marketplace,bundles,feedback}
  }
  async function scope() {
    const state=await cloudInvoke<CloudState>('native:cloudState')
    const key=JSON.stringify([state.accountID,state.signedIn,state.supabase,state.marketplaceURL])
    let result=scopes.get(key)
    if(!result){
      // Never evict active work underneath an upload/import. Bound the number
      // of account/config contexts until the runtime is explicitly disposed.
      if(scopes.size>=16)throw new Error('마켓 연결 설정이 많이 변경되었습니다. 앱을 다시 열어 주세요.')
      result=createScope(state);scopes.set(key,result)
    }
    return result
  }
  for(const channel of STUDY_MARKET_CHANNELS)deps.handle(channel,async request=>(await scope()).handlers.get(channel)!(request))
  deps.handle('marketplace:dashboard',async()=>(await scope()).marketplace.dashboard())
  deps.handle('marketplace:release',async req=>(await scope()).marketplace.release(req.id))
  deps.handle('marketplace:register',async req=>{await(await scope()).marketplace.register(req.id,req.displayName);return{ok:true}})
  deps.handle('marketplace:resolveReport',async req=>{await(await scope()).marketplace.resolveReport(req.id,req.reason);return{ok:true}})
  deps.handle('marketplace:review',async req=>{await(await scope()).marketplace.review(req.id,req.decision,req.reason);return{ok:true}})
  deps.handle('marketplace:report',async req=>{await(await scope()).marketplace.report(req.releaseId,req.reason);return{ok:true}})
  deps.handle('marketplace:submit',async req=>{
    const current=await scope(),picked=await cloudInvoke<{data:string}|null>('native:marketPickPluginArchive')
    if(!picked)return{canceled:true}
    if(typeof picked.data!=='string'||picked.data.length>Math.ceil(8*1024*1024/3)*4)throw new Error('Plugin ZIP exceeds 8 MiB')
    const bytes=Buffer.from(picked.data,'base64');await inspectPluginArchive(bytes)
    await current.marketplace.submit(bytes.toString('base64'),req.changelog)
    return{canceled:false}
  })
  deps.handle('marketplace:reviewBundle',async req=>{
    const current=await scope(),bytes=await current.marketplace.reviewBundle(req.id)
    const saved=await cloudInvoke<{saved:boolean}>('native:saveFile',{suggestedName:'plugin-review.zip',mime:'application/zip',data:Buffer.from(bytes).toString('base64')})
    return{canceled:!saved.saved}
  })
  deps.handle('feedback:send',async req=>(await scope()).feedback.send(req))
  return {async dispose(){for(const current of scopes.values())await current.bundles.dispose();scopes.clear()}}
}
