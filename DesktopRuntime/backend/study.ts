import { createContextWriter } from '../upstream/src/main/features/context/dossier'
import { createInsights } from '../upstream/src/main/features/insights/insights'
import { createPackRunner } from '../upstream/src/main/features/workflowPacks/packRunner'
import { getLegacyPack } from '../upstream/src/shared/workflowPacks/builtins'
import { importChatAttachments } from '../upstream/src/main/features/agent/chatAttachments'
export function installStudy(deps:any){
  const {db,courses,materials,canvas,board,activity,linkIndex,packs,ai,handle,changed}=deps
  const insights=createInsights({db,getCourseFolder:(id:string)=>courses.getFolder(id),getMaterialCitations:(id:string)=>linkIndex.allForCourse(id).map((g:any)=>g.relPath)})
  const context=createContextWriter({db,getCourseFolder:(id:string)=>courses.getFolder(id),getCourse:(id:string)=>({name:courses.getById(id).name}),activity,
    getUpcomingDeadlines:(id:string)=>board.upcoming({courseId:id,withinDays:30,limit:8}),getStudyGaps:(id:string)=>insights.gaps(id),
    getWhiteboards:(id:string)=>canvas.listBoards(id).map((b:any)=>({title:b.title,shapeCount:canvas.countShapes(b.id)})),getMaterialLinks:(id:string)=>linkIndex.allForCourse(id)})
  handle('context:rebuild',(req:any)=>context.rebuild(req.courseId))
  handle('chat:importAttachments',async(req:any)=>{const result=await importChatAttachments(courses.getFolder(req.courseId),req.paths);materials.invalidateTree(req.courseId);changed(req.courseId);return result})
  handle('chat:pickAttachments',()=>{const invoke=(globalThis as any).__bandalPlatform?.invoke;if(!invoke)throw new Error('Native attachment picker unavailable');return invoke('native:chatPickAttachments',{})})
  const runner=createPackRunner({store:{resolve:id=>{const p=packs.resolve(id);return p?getLegacyPack(p):null},list:()=>packs.list().map((s:any)=>s.source==='builtin'?{...s,pack:getLegacyPack(s.pack)}:s),approve:(id,at)=>packs.approve(id,at)},
    runGuard:{arm:(id,r)=>ai.workflow.runGuard.arm(id,r),clear:id=>ai.workflow.runGuard.clear(id)},getCourse:id=>({name:courses.getById(id).name,folder:courses.getFolder(id)}),
    ask:(id,prompt)=>{context.rebuild(id,true);return ai.workflow.askStudy(id,prompt)},confirm:request=>ai.workflow.confirm(request),
    recordActivity:(courseId,summary,relPath)=>activity.record({courseId,summary,relPath,kind:'study-tool-run'}),getPlanningContext:courseId=>({asOf:new Date().toISOString(),upcomingDeadlines:board.upcoming({courseId,withinDays:30,limit:8}).filter((d:any)=>d.task.dueAt!==null).map((d:any)=>({title:d.task.title,dueAt:d.task.dueAt,daysLeft:d.daysLeft})),studyGaps:insights.gaps(courseId)})})
  handle('study:tools',()=>({tools:packs.list().map(({pack,source,enabled}:any)=>({id:pack.id,label:pack.name,description:pack.description,worksOnCourse:pack.worksOn.includes('course'),source,enabled,usesWeb:pack.usesWeb,...(pack.schemaVersion===2?{experience:pack.experience}:{}),outputs:{...pack.outputs},...(pack.followUp?{followUp:{...pack.followUp}}:{})}))}))
  handle('study:run',(req:any)=>{if(req.browserTabUrl){if(!req.browserTabId)throw new Error('현재 브라우저 탭을 확인할 수 없습니다.');ai.assertSourceTab(req.courseId,req.browserTabId,req.browserTabUrl)}return runner.run({courseId:req.courseId,packId:req.tool,...(req.relPath===null?{}:{targetRelPath:req.relPath}),...(req.selection===undefined?{}:{selectionText:req.selection}),...(req.browserTabUrl===undefined?{}:{browserTabUrl:req.browserTabUrl}),...(req.followUpOf===undefined?{}:{followUpOf:req.followUpOf})})})
  return{context,insights}
}
