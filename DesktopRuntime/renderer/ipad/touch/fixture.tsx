// Actual adapted WhiteboardsGroup/BoardPanel and original CanvasToolRail.
// Only persistence and workspace opening are fixtures.
import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import type { IDockviewPanelProps, IDockviewHeaderActionsProps } from 'dockview'
import { WhiteboardsGroup } from '../../../upstream/src/renderer/src/features/materials/WhiteboardsGroup'
import BoardPanel from '../../../upstream/src/renderer/src/features/board/BoardPanel'
import { CanvasToolRail } from '../../../upstream/src/renderer/src/features/canvas/CanvasToolRail'
import { OpenTabsAction } from '../../../upstream/src/renderer/src/features/workspace/OpenTabsMenu'
import { useWorkspaceStore } from '../../../upstream/src/renderer/src/stores/workspaceStore'
import { useInkToolStore } from '../../../upstream/src/renderer/src/features/ink'
import { ensureSettingsLoaded } from '../../../upstream/src/renderer/src/stores/settingsSnapshot'
import { setIpcAdapter, type IpcAdapter } from '../../../upstream/src/renderer/src/lib/ipc'
import { DEFAULT_SETTINGS } from '../../../upstream/src/shared/types/settings'
import type { PersonalBoard } from '../../../upstream/src/shared/types/whiteboard'
import type { BoardTask } from '../../../upstream/src/shared/types/board'
import { setLocale } from '../../../upstream/src/renderer/src/i18n'
import '../../../upstream/src/renderer/src/styles/tokens.css'
import '../../../upstream/src/renderer/src/styles/base.css'
import '../../../upstream/src/renderer/src/features/materials/materials.css'
import '../../../upstream/src/renderer/src/features/courses/courses.css'
import '../../../upstream/src/renderer/src/features/canvas/canvas.css'
import '../layout/layout.css'
import './touch.css'

const today = new Date(), dateKey = `${today.getFullYear()}-${String(today.getMonth()+1).padStart(2,'0')}-${String(today.getDate()).padStart(2,'0')}`
const boards: PersonalBoard[] = [{ id:'whiteboard', courseId:'course', title:'생각 정리', background:'grid', surface:'light', pageCount:1, sortOrder:0, createdAt:'2026-01-01', updatedAt:'2026-01-01' }]
const tasks: BoardTask[] = Array.from({length:4},(_,index)=>({ id:`task-${index}`,courseId:null,title:index===0?'연습 과제':`일정 ${index}`,notes:'',status:'todo',kind:'task',color:'none',startAt:null,dueAt:dateKey,allDay:true,sortOrder:index,createdAt:'2026-01-01',updatedAt:'2026-01-01' }))
const trace = { calls: [] as Array<{ channel:string; request:Record<string,unknown> }>, opened: [] as unknown[], actions: [] as string[], today:dateKey, tasks, ink:()=>useInkToolStore.getState() }
const invoke = async(channel:string, request:Record<string,unknown>) => {
  trace.calls.push({channel,request})
  if(channel==='settings:get')return{...structuredClone(DEFAULT_SETTINGS),tabs:{...DEFAULT_SETTINGS.tabs,boardDefaultView:'board'}}
  if(channel==='canvas:list')return structuredClone(boards)
  if(channel==='canvas:rename'){const board=boards.find(item=>item.id===request.id)!;board.title=String(request.title);return{...board}}
  if(channel==='board:listTasks'||channel==='calendar:range')return structuredClone(tasks)
  if(channel==='board:updateTask'){const task=tasks.find(item=>item.id===request.id)!;Object.assign(task,request);return{...task}}
  if(channel==='appleCalendar:state')return{supported:false,connected:false,authorization:'not-determined',calendars:[],selectedCalendarIds:[],destinationCalendarId:null}
  if(channel==='appleCalendar:events')return[]
  throw new Error(`Unexpected touch fixture IPC ${channel}`)
}
Object.assign(window,{touchFixture:trace,bandal:{platform:'ipad',invoke,on:()=>()=>{}}})
setIpcAdapter({invoke,on:()=>()=>{}} as IpcAdapter)
useWorkspaceStore.setState({openTab:descriptor=>{trace.opened.push(descriptor)}})
setLocale('ko-KR')
await ensureSettingsLoaded()
const groupElement=document.createElement('div')
const tabsProps={group:{id:'fixture',element:groupElement,panels:[]},containerApi:{onDidLayoutChange:()=>({dispose(){}})}} as unknown as IDockviewHeaderActionsProps
function Fixture():JSX.Element{
  const[view,setView]=useState('materials'),[background,setBackground]=useState<'grid'|'dots'|'lines'|'blank'>('grid')
  return <div className="touch-fixture ipad-shell"><nav>{[['materials','자료 테스트'],['board','보드 테스트'],['canvas','화이트보드 도구 테스트'],['tabs','탭 테스트']].map(([key,label])=><button key={key} onClick={()=>setView(key!)}>{label}</button>)}</nav>
    <main>{view==='materials'?<WhiteboardsGroup courseId="course"/>:view==='board'?<BoardPanel {...{params:{descriptor:{kind:'board'}}} as IDockviewPanelProps}/>:view==='tabs'?<OpenTabsAction {...tabsProps}/>:<div className="canvas-tab">
      <header className="canvas-tab__header"><button className="canvas-tab__title" onClick={()=>trace.actions.push('rename')}>생각 정리 이름 변경</button></header>
      <CanvasToolRail canUndo canRedo enabled background={background} surface="light" backgroundBusy={false} pageBusy={false} exportingPdf={false}
        onUndo={()=>trace.actions.push('undo')} onRedo={()=>trace.actions.push('redo')} onInsertImages={()=>trace.actions.push('image')}
        onBackgroundChange={setBackground} onSurfaceToggle={()=>trace.actions.push('surface')} onAddPage={()=>trace.actions.push('page')} onExportPdf={()=>trace.actions.push('export')}/>
      <div className="canvas-tab__viewport touch-fixture-paper"><div style={{height:1000}}>Paper</div></div></div>}</main></div>
}
const style=document.createElement('style')
style.textContent='.touch-fixture{height:100%;display:flex;flex-direction:column;overflow:hidden}.touch-fixture>nav{display:flex;flex-wrap:wrap;flex:none;border-bottom:1px solid #ddd}.touch-fixture>nav button{min-height:44px;padding:8px}.touch-fixture>main{flex:1;min-height:0;min-width:0;overflow:hidden}.touch-fixture .whiteboards-group{max-width:320px}.touch-fixture-paper{background:#eee}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture/> )
