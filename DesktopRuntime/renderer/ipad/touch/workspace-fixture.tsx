// Real Dockview, tab headers, drop overlay, course hover and workspace store.
// Only document bodies and the persistence/native IPC boundaries are fixtures.
import { useEffect, useRef, type ReactNode } from 'react'
import { createRoot } from 'react-dom/client'
import { DockviewReact, type DockviewApi } from 'dockview'
import { WorkspaceTab } from '../../../upstream/src/renderer/src/features/workspace/WorkspaceTab'
import { CourseTabMoveOverlay } from '../../../upstream/src/renderer/src/features/workspace/CourseTabMoveOverlay'
import { WorkspaceCourseContext } from '../../../upstream/src/renderer/src/features/workspace/placementContext'
import { installWorkspaceDragSession, tabDragSession } from '../../../upstream/src/renderer/src/features/workspace/tabDragSession'
import { installWorkspaceCourseMoveNavigation } from '../../../upstream/src/renderer/src/features/workspace/courseTabMoveNavigation'
import { useWorkspaceCourseHover } from '../../../upstream/src/renderer/src/features/courses/useWorkspaceCourseHover'
import { useWorkspaceStore } from '../../../upstream/src/renderer/src/stores/workspaceStore'
import { useCoursesStore } from '../../../upstream/src/renderer/src/stores/coursesStore'
import { descriptorFor } from '../../../upstream/src/renderer/src/features/workspace/tabIdentity'
import { ensureSettingsLoaded } from '../../../upstream/src/renderer/src/stores/settingsSnapshot'
import { setIpcAdapter, type IpcAdapter } from '../../../upstream/src/renderer/src/lib/ipc'
import { DEFAULT_SETTINGS } from '../../../upstream/src/shared/types/settings'
import { installWorkspaceTouchDrag } from './tabDrag'
import { GlobalNavigation } from '../../../upstream/src/renderer/src/app/GlobalNavigation'
import { useUiStore } from '../../../upstream/src/renderer/src/stores/uiStore'
import { useIpadShellLayout } from '../layout/layout'
import { ipadPanelRevision } from '../layout/coordination'
import 'dockview/dist/styles/dockview.css'
import '../../../upstream/src/renderer/src/styles/tokens.css'
import '../../../upstream/src/renderer/src/styles/base.css'
import '../../../upstream/src/renderer/src/features/workspace/workspace.css'
import './touch.css'

const ids = ['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002']
const apis = new Map<string, DockviewApi>(), layouts = new Map<string, unknown>()
const calls: Array<{ channel: string; request: Record<string, unknown> }> = []
let deferNative = false, nativeAck: (() => void) | undefined
const invoke = async (channel: string, request: Record<string, unknown>): Promise<unknown> => {
  calls.push({ channel, request })
  if (channel === 'settings:get') return structuredClone(DEFAULT_SETTINGS)
  if (channel === 'settings:set') return { ...structuredClone(DEFAULT_SETTINGS), ...request }
  if (channel === 'courses:list') return useCoursesStore.getState().courses
  if (channel === 'update:status') return { phase: 'unsupported' }
  if (channel === 'agent:availability') return { installed: false, loggedIn: false }
  if (channel === 'materials:tree' || channel === 'favorites:list' || channel === 'activity:recent') return []
  if (channel === 'layout:get') return { layout: layouts.get(String(request.courseId)) ?? null }
  if (channel === 'layout:saveMany') { for (const item of request.layouts as Array<{ courseId: string; layout: unknown }>) layouts.set(item.courseId, structuredClone(item.layout)); return { ok: true } }
  if (channel === 'layout:save') { layouts.set(String(request.courseId), structuredClone(request.layout)); return { ok: true } }
  if (channel === 'runtime:nativeSurfaceSession') return { sessionId: 'touch-fixture' }
  if (channel === 'runtime:nativeSurfaces') {
    if (deferNative && request.inputBlocked) await new Promise<void>(resolve => { nativeAck = resolve })
    return { revision: request.revision }
  }
  throw new Error(`Unexpected tab touch IPC ${channel}`)
}
Object.assign(window, { bandal: { platform: 'ipad', invoke, on: () => () => {} } })
setIpcAdapter({ invoke, on: () => () => {} } as IpcAdapter)
useCoursesStore.setState({ courses: ids.map((id, index) => ({ id, name: `과목 ${index + 1}`, color: 'blue', slug: id, source: 'managed' as const, missing: false, archived: false, groupId: null, sortOrder: index, createdAt: '', updatedAt: '', folderPath: `/fixture/${id}`, folderStatus: 'connected' })) })
await ensureSettingsLoaded()
useCoursesStore.getState().selectCourse(ids[0]!)
const Body = (): JSX.Element => <div className="document-body"><div>Document scroll surface</div><div style={{ height: 1600 }} /></div>
function NavigationFrame({ workspace, rows }: { workspace: ReactNode; rows: ReactNode }): JSX.Element {
  const layout = useIpadShellLayout()
  return <div className="fixture-shell fixture-navigation ipad-shell" data-ipad-left={layout.panels.left}>
    <GlobalNavigation />
    <aside className="ipad-left-surface" hidden={layout.panels.left === 'closed' || layout.panels.left === 'suspended'}
      role={layout.overlay ? 'dialog' : 'complementary'} aria-label="내 공간" aria-modal={layout.overlay || undefined}>{rows}</aside>
    <main className="app-workspace" {...{ inert: layout.overlay ? '' : undefined }}>{workspace}</main>
  </div>
}
function Fixture(): JSX.Element {
  const root = useRef<HTMLDivElement>(null)
  const selected = useCoursesStore(state => state.selectedCourseId)
  const hover = useWorkspaceCourseHover()
  useEffect(() => {
    const element = root.current!
    const stopNavigation = installWorkspaceCourseMoveNavigation(), stopSession = installWorkspaceDragSession(element)
    const stopTouch = installWorkspaceTouchDrag(element)
    return () => { stopTouch(); stopSession(); stopNavigation() }
  }, [])
  const rows = ids.map((id, index) => <div key={id} className="course-row" data-course-id={id} {...hover.rowProps(id, true)}><button onClick={() => useCoursesStore.getState().selectCourse(id)}>과목 {index + 1}</button></div>)
  const workspace = <div className="workspace-host" ref={root}>{ids.map(id => <WorkspaceCourseContext.Provider key={id} value={id}>
      <div className="workspace-course" data-workspace-course={id} hidden={selected !== id}><DockviewReact
        components={{ note: Body }} defaultTabComponent={WorkspaceTab}
        onReady={event => {
          apis.set(id, event.api); useWorkspaceStore.getState().attachCourseApi(id, event.api)
          event.api.onDidLayoutChange(() => { if (useWorkspaceStore.getState().activeCourseId === id) useWorkspaceStore.getState().notifyLayoutChanged() })
        }}/></div></WorkspaceCourseContext.Provider>)}<CourseTabMoveOverlay /></div>
  return new URLSearchParams(location.search).has('navigation') ? <NavigationFrame workspace={workspace} rows={rows} />
    : <div className="fixture-shell"><aside>{rows}</aside>{workspace}</div>
}
Object.assign(window, { tabTouchFixture: {
  ids, calls, layouts, apis, ready: () => apis.size === 2 && useWorkspaceStore.getState().hydration === 'ready',
  state: () => ({ selected: useCoursesStore.getState().selectedCourseId, kind: tabDragSession.getSnapshot(), source: tabDragSession.getSource(),
    groups: Object.fromEntries([...apis].map(([id, api]) => [id, api.groups.map(group => ({ id: group.id, panels: group.panels.map(panel => ({ id: panel.id, title: panel.title, descriptor: panel.params?.descriptor })) }))])) }),
  create: () => { for (const relPath of ['one.md', 'two.md', 'three.md']) useWorkspaceStore.getState().openTab(descriptorFor('note', { courseId: ids[0]!, relPath })) },
  defer: (value: boolean) => { deferNative = value }, ack: () => { deferNative = false; nativeAck?.(); nativeAck = undefined },
  nativePending: () => !!nativeAck,
  panelRevision: ipadPanelRevision, ui: useUiStore,
  select: (index: number) => useCoursesStore.getState().selectCourse(ids[index]!),
  flush: () => useWorkspaceStore.getState().flushPendingSave()
} })
const style = document.createElement('style')
style.textContent = '.fixture-shell{display:flex;height:100dvh}.fixture-shell>aside{width:180px;flex:none;padding:10px}.course-row{height:52px}.course-row button{width:100%;height:100%}.workspace-host{flex:1;min-width:0;height:100%;position:relative}.workspace-course{position:absolute;inset:0}.workspace-course[hidden]{display:none}.dv-tabs-and-actions-container{height:44px!important}.dv-tab{min-width:140px}.workspace-tab{height:44px}.workspace-tab__close{width:30px;height:44px}.document-body{height:100%;overflow:auto;touch-action:pan-y}'
style.textContent += '.fixture-navigation>.global-navigation{position:relative;inset:auto;width:56px;min-width:56px;height:100%;flex:none}.fixture-navigation>.app-workspace{flex:1;min-width:0}.fixture-navigation>.ipad-left-surface{position:absolute;left:56px;top:0;width:280px;height:100%;z-index:40;background:var(--bg-surface)}.fixture-navigation>.ipad-left-surface[hidden]{display:none}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture />)
