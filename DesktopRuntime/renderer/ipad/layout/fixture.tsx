import { useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { DockviewReact, type DockviewApi, type IDockviewPanelProps } from 'dockview'
import { setIpcAdapter, type IpcAdapter } from '../../../upstream/src/renderer/src/lib/ipc'
import { DEFAULT_SETTINGS } from '../../../upstream/src/shared/types/settings'
import { DEFAULT_AI_ACCESS } from '../../../upstream/src/shared/types/aiAccess'
import { useUiStore } from '../../../upstream/src/renderer/src/stores/uiStore'
import { useWorkspaceStore } from '../../../upstream/src/renderer/src/stores/workspaceStore'
import { GlobalNavigation } from '../../../upstream/src/renderer/src/app/GlobalNavigation'
import { CourseSidebar } from '../../../upstream/src/renderer/src/features/courses/CourseSidebar'
import { MaterialsSidebar } from '../../../upstream/src/renderer/src/features/materials/MaterialsSidebar'
import { useCoursesStore } from '../../../upstream/src/renderer/src/stores/coursesStore'
import { useMaterialsStore } from '../../../upstream/src/renderer/src/stores/materialsStore'
import type { MaterialNode } from '../../../upstream/src/shared/types/materials'
import { SettingsApp } from '../../../upstream/src/renderer/src/features/settings/SettingsApp'
import { withAssistantPanel } from '../../../upstream/src/renderer/src/features/assistantPanel/TabAssistantPanel'
import { usePanelAssistant } from '../../../upstream/src/renderer/src/features/assistantPanel/panelContext'
import { NewTabMenu } from '../../../upstream/src/renderer/src/features/workspace/NewTabMenu'
import { WorkspaceTab } from '../../../upstream/src/renderer/src/features/workspace/WorkspaceTab'
import { OpenTabsAction } from '../../../upstream/src/renderer/src/features/workspace/OpenTabsMenu'
import { useNewTabMenu } from '../../../upstream/src/renderer/src/features/workspace/newTabMenuController'
import { BoardOverlay } from '../../../upstream/src/renderer/src/features/board/BoardPanel'
import { LinkGraphOverlay } from '../../../upstream/src/renderer/src/features/links/graph/LinkGraphOverlay'
import { BrowserImportDialog } from '../../../upstream/src/renderer/src/features/browser/BrowserImportDialog'
import { useGlobalShortcuts } from '../../../upstream/src/renderer/src/app/shortcuts'
import { usePresence } from '../../../upstream/src/renderer/src/components/usePresence'
import type { BoardTask } from '../../../upstream/src/shared/types/board'
import type { Course } from '../../../upstream/src/shared/types/course'
import { minimumSplitWidth } from './policy'
import { IpadBackdrop, IpadRailControls, IpadShellChrome, useIpadShellLayout, bindIpadWorkspace } from './layout'
import { setNativeHostBlocked, flushNativeSurfaceLayout } from '../nativeSurfaces'
import '../../../upstream/src/renderer/src/styles/tokens.css'
import '../../../upstream/src/renderer/src/styles/base.css'
import '../../../upstream/src/renderer/src/app/app-shell.css'
import '../../../upstream/src/renderer/src/app/global-navigation.css'
import 'dockview/dist/styles/dockview.css'
import '../../../upstream/src/renderer/src/features/workspace/workspace.css'
import './layout.css'
import '../ui/styles.css'

const calls: Array<{ channel: string; request: Record<string, unknown> }> = []
let boardTask: BoardTask = { id: 'fixture-task', courseId: null, title: '보존할 태스크', notes: '', status: 'todo', kind: 'task', color: 'none', startAt: null, dueAt: null, allDay: false, sortOrder: 0, createdAt: '', updatedAt: '' }
const invoke = async (channel: string, request: Record<string, unknown>) => {
  calls.push({ channel, request })
  if (channel === 'runtime:nativeSurfaceSession') return { sessionId: 'layout-fixture' }
  if (channel === 'runtime:nativeSurfaces') return { revision: request.revision }
  if (channel === 'settings:get') return structuredClone(DEFAULT_SETTINGS)
  if (channel === 'settings:set') return { ...structuredClone(DEFAULT_SETTINGS), ...request }
  if (channel === 'plugins:list') return { plugins: [] }
  if (channel === 'courses:list') return [fixtureCourse, { ...fixtureCourse, id: 'course-two', name: '인지과학과 학습 전략', groupId: 'semester' }]
  if (channel === 'courseGroups:list') return [{ id: 'semester', name: '이번 학기', sortOrder: 0, createdAt: '', updatedAt: '' }]
  if (channel === 'materials:snapshot') return { tree: null }
  if (channel === 'board:listTasks') return [structuredClone(boardTask)]
  if (channel === 'board:updateTask') { boardTask = { ...boardTask, ...request }; return structuredClone(boardTask) }
  if (channel === 'materials:tree') return fixtureMaterials
  if (channel === 'canvas:list' || channel === 'widgets:list' || channel === 'links:backlinks' || channel === 'materials:search') return []
  if (channel === 'materials:states' || channel === 'recordings:list') return []
  if (channel === 'materials:watch' || channel === 'materials:unwatch') return undefined
  if (channel === 'agent:health') return { status: 'ready' }
  if (channel === 'links:graph') return { links: [], backlinks: [] }
  if (channel === 'browser:importSources') return []
  if (channel === 'browser:profiles') return [{ id: 'fixture-profile', name: 'Fixture profile', icon: '' }]
  if (channel === 'agent:availability') return { installed: true, loggedIn: true }
  if (channel === 'agent:models') return { models: [{ id: 'fixture', displayName: 'Fixture model', isDefault: true }], source: 'fallback', status: 'ready' }
  if (channel === 'chat:open') return { history: [], sessionInfo: null, availability: { installed: true, loggedIn: true } }
  if (channel === 'chat:context') return { id: 'fixture-context', courseId: 'fixture-course', courseName: 'Fixture course', capturedAt: '', refresh: 'fresh' }
  if (channel === 'chat:accessPolicy') return DEFAULT_AI_ACCESS
  if (channel === 'chat:conversations') return { conversations: [] }
  if (channel === 'agentTools:confirmations' || channel === 'favorites:list') return []
  if (channel === 'auth:getState') return { phase: 'signed-out' }
  if (channel === 'auth:signIn') return { ok: true }
  throw new Error(`Unexpected layout fixture request: ${channel}`)
}
Object.assign(window, { bandal: { platform: 'ipad', invoke, on: () => () => {} } })
setIpcAdapter({ invoke, on: () => () => {} } as IpcAdapter)
let api: DockviewApi | undefined
const trace = { calls, ui: useUiStore, flush: flushNativeSurfaceLayout, openPortal: () => {},
  materialsAvailable: (available: boolean) => useWorkspaceStore.setState({ activePanelSource: () => available ? null : ({ descriptor: { kind: 'learning' } } as ReturnType<ReturnType<typeof useWorkspaceStore.getState>['activePanelSource']>) }),
  openMenu: (x: number, y: number) => useNewTabMenu.getState().open({ x, y }), snapshot: () => api ? ({ groups: api.groups.map(group => ({ id: group.id, panels: group.panels.map(panel => panel.id) })), active: api.activePanel?.id, panels: api.panels.map(panel => panel.id), maximized: api.hasMaximizedGroup(), saved: api.toJSON(), requiredWidth: minimumSplitWidth(api.toJSON()) }) : null,
  select: (id: string) => api?.getPanel(id)?.api.setActive(), maximize: () => { if (api?.activePanel) api.maximizeGroup(api.activePanel) }, restore: () => api?.exitMaximizedGroup() }
Object.assign(window, { ipadLayoutFixture: trace })
function Pane({ api: panel }: IDockviewPanelProps): JSX.Element {
  const [draft, setDraft] = useState('retained ' + panel.id)
  const assistant = usePanelAssistant()
  return <div className="fixture-pane"><button data-ipad-assistant-trigger={panel.id} onClick={event => { event.currentTarget.focus(); assistant?.toggle() }}>도움 열기 {panel.id}</button><textarea aria-label={panel.id} value={draft} onChange={event => setDraft(event.target.value)} /></div>
}
const AssistantPane = withAssistantPanel(Pane)
const fixtureCourse: Course = { id: 'fixture-course', name: '디자인과 인간의 사고 — 사용자 경험 관찰과 인터뷰 실습', slug: 'fixture', color: '#a78bfa', folderPath: '/fixture', source: 'managed', missing: false, archived: false, groupId: null, sortOrder: 0, createdAt: '', updatedAt: '' }
const fixtureMaterials: MaterialNode[] = [
  { relPath: '강의.pdf', name: '강의.pdf', kind: 'pdf', size: 2400000 },
  { relPath: '리서치 노트.md', name: '리서치 노트.md', kind: 'note' },
  { relPath: '참고 자료', name: '참고 자료', kind: 'dir', children: [{ relPath: '참고 자료/사용자 경험을 이해하기 위한 관찰과 인터뷰.pdf', name: '사용자 경험을 이해하기 위한 관찰과 인터뷰.pdf', kind: 'pdf' }] }
]
useCoursesStore.setState({ courses: [fixtureCourse, { ...fixtureCourse, id: 'course-two', name: '인지과학과 학습 전략', groupId: 'semester' }], groups: [{ id: 'semester', name: '이번 학기', sortOrder: 0, createdAt: '', updatedAt: '' }], selectedCourseId: fixtureCourse.id, isLoading: false })
useMaterialsStore.setState({ expandedPaths: { '참고 자료': true } })
function Fixture(): JSX.Element {
  useGlobalShortcuts()
  const layout = useIpadShellLayout()
  const settings = useUiStore(state => state.isSettingsOpen)
  const settingsPresent = usePresence(settings, 160)
  const board = useUiStore(state => state.isBoardOverlayOpen)
  const graph = useUiStore(state => state.isLinkGraphOpen)
  const [portal, setPortal] = useState(false)
  trace.openPortal = () => setPortal(true)
  const newTabOpen = useNewTabMenu(state => state.isOpen)
  useEffect(() => { setNativeHostBlocked('fixture-settings', settings); return () => setNativeHostBlocked('fixture-settings', false) }, [settings])
  return <div className="app-shell ipad-shell" data-left-rail={layout.panels.left === 'closed' ? 'closed' : 'open'} data-course-rail={layout.panels.left === 'closed' ? 'closed' : 'open'} data-right-rail={layout.panels.materials === 'closed' ? 'closed' : 'open'} data-ipad-side={layout.side ?? 'none'} data-ipad-pinned={layout.pinned ?? 'none'} data-ipad-panel={layout.presentation} data-ipad-left={layout.panels.left} data-ipad-materials={layout.panels.materials} data-ipad-assistant={layout.panels.assistant}>
    <GlobalNavigation />
    {layout.overlay && <IpadBackdrop close={layout.close} />}
    <section className="ipad-left-surface" aria-owns={layout.panels.left === 'overlay' ? 'ipad-global-navigation' : undefined} hidden={layout.panels.left === 'closed' || layout.panels.left === 'suspended'} role={layout.panels.left === 'overlay' ? 'dialog' : 'complementary'} aria-label="내 공간" aria-modal={layout.panels.left === 'overlay' || undefined} {...{ inert: layout.overlayOwner && layout.overlayOwner !== 'left' ? '' : undefined }}><IpadRailControls layout={layout} side="left" /><div className="shell-course-rail"><CourseSidebar /></div></section>
    <main className="app-workspace" {...{ inert: settings || layout.overlay ? '' : undefined }}>
      <div className="workspace-course" style={{ height: '100%', width: '100%' }}>
        <DockviewReact className="bandal-dockview" rightHeaderActionsComponent={OpenTabsAction} defaultTabComponent={WorkspaceTab} components={{ note: AssistantPane }} onReady={event => {
          api = event.api
          const first = api.addPanel({ id: 'first', component: 'note', title: '첫 문서', params: { assistant: { open: true, courseId: 'fixture-course' } } })
          api.addPanel({ id: 'second', component: 'note', title: '두 번째 문서', params: { assistant: { open: true, courseId: 'fixture-course' } }, position: { referencePanel: first, direction: 'right' } })
          bindIpadWorkspace(api, document.querySelector('.workspace-course'))
        }} />
      </div>
    </main>
    <div className="shell-materials-rail ipad-right-surface" role={layout.panels.materials === 'overlay' ? 'dialog' : 'complementary'} aria-label="자료" aria-modal={layout.panels.materials === 'overlay' || undefined} {...{ inert: layout.panels.materials === 'closed' || layout.panels.materials === 'suspended' || !!layout.overlayOwner && layout.overlayOwner !== 'materials' ? '' : undefined }}><IpadRailControls layout={layout} side="right" /><MaterialsSidebar course={fixtureCourse} /></div>
    <IpadShellChrome />
    {board && <BoardOverlay onClose={() => useUiStore.getState().closeBoardOverlay()} />}
    {graph && <LinkGraphOverlay courseId={fixtureCourse.id} onClose={() => useUiStore.getState().closeLinkGraph()} />}
    {newTabOpen && <NewTabMenu course={fixtureCourse} />}
    <button className="fixture-materials" onClick={() => useUiStore.getState().toggleRightRail()}>자료 열기</button>
    <button className="fixture-settings" onClick={() => useUiStore.getState().openSettings()}>설정 열기</button>
    {settingsPresent && <div className="settings-overlay shell-settings-overlay" role="dialog" aria-modal="true" aria-label="설정" data-open={settings} {...{ inert: !settings ? '' : undefined }}><SettingsApp embedded onClose={() => useUiStore.getState().closeSettings()} /></div>}
    {settings && portal && <BrowserImportDialog profileId="fixture-profile" onClose={() => setPortal(false)} />}
  </div>
}
const style = document.createElement('style')
style.textContent = 'html,body,#root{width:100%;height:100%;margin:0}*{box-sizing:border-box}.fixture-materials,.fixture-settings{position:absolute;top:48px;height:44px;z-index:50}.fixture-materials{right:110px}.fixture-settings{right:0}textarea{display:block;width:100%;min-width:0}.app-rail{overflow:auto}.fixture-pane{display:flex;flex-direction:column;height:100%;min-height:0}.fixture-pane>button{height:44px;flex:none}.fixture-pane>textarea{flex:1;height:0;min-height:0}'
document.head.append(style)
createRoot(document.getElementById('root')!).render(<Fixture />)
