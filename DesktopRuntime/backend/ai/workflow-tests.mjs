import assert from 'node:assert/strict'
import path from 'node:path'
import fs from 'node:fs'

export async function runWorkflowTests({invoke,plans,tool,complete,wait,backend}) {
  const course = await invoke('courses:create', {name:'Workflow fixture',color:'blue'})
  const source = await invoke('notes:create',{courseId:course.id,dirRelPath:'',title:'자료',markdown:'검증할 원문'})
  await invoke('packs:setEnabled',{id:'summary',enabled:true})
  const request = {courseId:course.id,tool:'summary',relPath:source.relPath}
  let finish, written, runningSession
  plans.push(async api => {
    const prompt=api.messages.at(-1).text, match=prompt.match(/Write 도구의 파일 경로를 ("(?:[^"\\]|\\.)*")로/)
    assert.ok(match,'Original runner must supply its reserved destination')
    const destination=JSON.parse(match[1]).replace(/^\.\//,'')
    const denied=JSON.parse(await tool(api,'create_task',{courseId:course.id,title:'범위 밖 일정'}))
    assert.equal(denied.isError,true,'Pack must restrict tools while the turn is active')
    const result=JSON.parse(await tool(api,'write_file',{courseId:course.id,dirRelPath:path.posix.dirname(destination),fileName:path.posix.basename(destination),encoding:'utf8',data:'# 실제 생성한 요약\n\n검증할 원문'}))
    assert.equal(result.isError,undefined,JSON.stringify(result)); written=JSON.parse(result.content[0].text).relPath
    runningSession=backend.repositories.db.prepare("SELECT id FROM agent_sessions WHERE course_id=? AND status='running'").get(course.id)?.id
    return new Promise(resolve=>{finish=()=>resolve(complete)})
  })
  const started=await invoke('study:run',request)
  await wait(()=>finish!==undefined)
  assert.equal(written,started.relPath); assert.ok(runningSession)
  assert.match(fs.readFileSync(path.join(course.folderPath,started.relPath),'utf8'),/실제 생성한 요약/)
  await assert.rejects(invoke('study:run',request),/만들고 있어요/)
  finish()
  await wait(()=>backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(runningSession)?.status==='idle')
  // The same warm session must regain its normal permissions after settlement.
  await new Promise(resolve=>setTimeout(resolve,0))
  plans.push(async api=>{const result=JSON.parse(await tool(api,'create_task',{courseId:course.id,title:'완료 후 일반 도구'}));assert.equal(result.isError,undefined,JSON.stringify(result));return complete})
  await invoke('chat:send',{courseId:course.id,sessionId:runningSession,content:'학습 완료 후 일반 도구'})
  await wait(()=>backend.repositories.db.prepare('SELECT status FROM agent_sessions WHERE id=?').get(runningSession)?.status==='idle')
  assert.ok((await invoke('board:listTasks')).some(task=>task.title==='완료 후 일반 도구'))
  console.log('Workflow fixture passed: original pack prompt/reserved path, real generated note, restricted active tools, duplicate-run rejection, permission restoration after settlement')
}
