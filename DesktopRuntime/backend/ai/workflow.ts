import { createPackRunGuard } from '../../upstream/src/main/features/workflowPacks/runGuard'
import { randomUUID } from '../shims/crypto'

export function createWorkflowBridge(deps: { chat:any; courses:any; manager:(request:any)=>Promise<any>; confirm:(request:any)=>Promise<any> }) {
  const guard=createPackRunGuard(),sessions=new Map<string,string>(),armed=new Map<string,string>(),pending=new Map<string,{resolve:()=>void;reject:(error:Error)=>void}>()
  const sessionFor=(courseId:string)=>{
    deps.courses.getById(courseId)
    let id=sessions.get(courseId)
    if(!id){id=deps.chat.listConversations(courseId,'app')[0]?.id??randomUUID();sessions.set(courseId,id)}
    return id
  }
  return {
    restrictionFor:(sessionId:string)=>guard.restrictionFor(sessionId),
    runGuard:{arm(courseId:string,restriction:any){const id=sessionFor(courseId);armed.set(courseId,id);guard.arm(id,restriction)},clear(courseId:string){const id=armed.get(courseId);if(id)guard.clear(id);armed.delete(courseId)}},
    async confirm(request:any){const id=sessionFor(request.courseId);try{const result=await deps.confirm({...request,conversationId:id});if(result===false)sessions.delete(request.courseId);return result}catch(error){sessions.delete(request.courseId);throw error}},
    async askStudy(courseId:string,prompt:string){
      const sessionId=sessionFor(courseId),manager=await deps.manager({courseId,sessionId})
      if(pending.has(sessionId)||deps.chat.getSession(sessionId)?.status==='running')throw new Error('진행 중인 대화가 끝난 후 학습 도구를 실행하세요.')
      const completed=new Promise<void>((resolve,reject)=>pending.set(sessionId,{resolve,reject}));void completed.catch(()=>undefined)
      const timer=setTimeout(()=>{manager.cancel(courseId,sessionId);pending.get(sessionId)?.reject(new Error('학습 도구 실행 시간이 초과되었습니다.'))},15*60*1000)
      timer.unref?.()
      try{await manager.send(courseId,sessionId,prompt);await completed}
      finally{clearTimeout(timer);pending.delete(sessionId);if(sessions.get(courseId)===sessionId)sessions.delete(courseId)}
    },
    settle(info:{sessionId:string;reason:string;error?:unknown}){const waiter=pending.get(info.sessionId);if(!waiter)return;info.reason==='success'?waiter.resolve():waiter.reject(new Error(typeof info.error==='string'?info.error:info.reason==='cancelled'?'학습 실행을 취소했습니다.':'학습 도구 실행을 완료하지 못했습니다.'))},
    dispose(){for(const waiter of pending.values())waiter.reject(new Error('학습 도구 연결을 종료했습니다.'));pending.clear();for(const id of armed.values())guard.clear(id);armed.clear();sessions.clear()}
  }
}
