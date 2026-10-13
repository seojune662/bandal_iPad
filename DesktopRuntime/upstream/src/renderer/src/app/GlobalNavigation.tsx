import { openStudyMarket } from './studyMarketNavigation'
import { useAuthStore } from '../stores/authStore'
import { useUiStore } from '../stores/uiStore'
import { SidebarAccountEntry } from '../features/account/SidebarAccountEntry'
import { HelpHub } from '../features/help/HelpHub'
import { TabKindIcon } from '../features/workspace/workspaceIcons'
import { openActiveAssistant, useActiveAssistantOpen } from '../features/assistantPanel/assistantController'
import { captureLauncherContext } from '../features/launcher/launcherContext'
import { Tooltip } from '../components/Tooltip'
import { Icon } from './icons'
import { useWorkspaceStore } from '../stores/workspaceStore'
import { openLearningHome, returnToCourseWorkspace } from '../features/learning/learningNavigation'
import { RailUpdateButton } from '../features/updates/RailUpdateButton'
import './global-navigation.css'

export function GlobalNavigation(): JSX.Element {
  const phase = useAuthStore((state) => state.auth.phase)
  const boardOpen = useUiStore((state) => state.isBoardOverlayOpen)
  const settingsOpen = useUiStore((state) => state.isSettingsOpen)
  const graphOpen = useUiStore((state) => state.isLinkGraphOpen)
  const courseOpen = useUiStore((state) => state.courseRailOpen)
  const leftPanel = useUiStore((state) => state.leftRailPanel)
  const assistantOpen = useActiveAssistantOpen()
  const leftOpen = useUiStore((state) => state.leftRailOpen)
  const surface = useWorkspaceStore((state) => state.surface)
  const openCourses = (): void => {
    const ui = useUiStore.getState()
    if (useWorkspaceStore.getState().surface !== 'course') { returnToCourseWorkspace(); return }
    if (ui.isSettingsOpen || ui.isBoardOverlayOpen || ui.isLinkGraphOpen || ui.leftRailPanel !== 'courses') ui.showCourses()
    else ui.toggleCourseRail()
  }
  return (
    <nav className="global-navigation" aria-label="앱 메뉴" aria-hidden={!leftOpen}
      {...{ inert: !leftOpen ? '' : undefined }}>
      <Tooltip label="과목" placement="right">
        <button
          className="rail-nav__item"
          aria-label="과목"
          aria-expanded={surface === 'course' && courseOpen && leftPanel === 'courses' && !boardOpen && !settingsOpen && !graphOpen}
          aria-controls="course-rail"
          data-active={(!boardOpen && !settingsOpen && !graphOpen && surface === 'course' && courseOpen && leftPanel === 'courses') || undefined}
          onClick={openCourses}
        >
          <Icon name="folder" />
        </button>
      </Tooltip>
      <Tooltip label="학습" placement="right">
        <button className="rail-nav__item" aria-label="학습"
          aria-expanded={courseOpen && leftPanel === 'learning' && !boardOpen && !settingsOpen && !graphOpen}
          aria-controls="learning-home"
          data-active={surface === 'learning-home' && !boardOpen && !settingsOpen && !graphOpen || undefined}
          onClick={openLearningHome}>
          <svg aria-hidden="true" viewBox="0 0 24 24" width="1em" height="1em" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
            <path d="M12 5.5C9 3.5 5.5 3.5 3 4.5v14c2.5-1 6-1 9 1 3-2 6.5-2 9-1v-14c-2.5-1-6-1-9 1Z" /><path d="M12 5.5v14" />
          </svg>
        </button>
      </Tooltip>
      <Tooltip label="학업 보드" placement="right">
        <button
          className="rail-nav__item"
          aria-label={boardOpen ? '학업 보드 닫기' : '학업 보드 열기'}
          aria-pressed={boardOpen}
          data-active={boardOpen || undefined}
          onClick={() => {
            useUiStore.getState().closeSettings()
            useUiStore.getState().toggleBoardOverlay()
          }}
        >
          <TabKindIcon kind="board" />
        </button>
      </Tooltip>
      <Tooltip label="AI" placement="right">
        <button className="rail-nav__item" aria-label="AI" aria-pressed={assistantOpen}
          data-active={assistantOpen && !boardOpen && !settingsOpen && !graphOpen || undefined}
          onPointerDown={event => { if (event.button === 0) event.preventDefault() }}
          onClick={() => {
            const ui = useUiStore.getState()
            ui.closeSettings(); ui.closeBoardOverlay(); ui.closeLinkGraph()
            void openActiveAssistant()
          }}><span aria-hidden="true">✦</span></button>
      </Tooltip>
      <Tooltip label="도구" placement="right">
        <button className="rail-nav__item" aria-label="도구"
          aria-expanded={surface !== 'study-market' && courseOpen && leftPanel === 'plugins' && !boardOpen && !settingsOpen && !graphOpen}
          aria-controls="plugins-panel"
          data-active={surface !== 'study-market' && courseOpen && leftPanel === 'plugins' && !boardOpen && !settingsOpen && !graphOpen || undefined}
          onPointerDown={event => { if (event.button === 0) { event.preventDefault(); void captureLauncherContext() } }}
          onClick={event => {
            if (surface === 'study-market') {
              useWorkspaceStore.getState().showCourseWorkspace(useWorkspaceStore.getState().activeCourseId)
              useUiStore.setState({ courseRailOpen: false })
            }
            if (event.detail === 0) void captureLauncherContext()
            useUiStore.getState().togglePluginsPanel()
          }}>
          <Icon name="puzzle" />
        </button>
      </Tooltip>
      <Tooltip label="마켓플레이스" placement="right">
        <button className="rail-nav__item" aria-label="마켓플레이스" aria-pressed={surface === 'study-market' && !boardOpen && !settingsOpen && !graphOpen}
          data-active={surface === 'study-market' && !boardOpen && !settingsOpen && !graphOpen || undefined} onClick={openStudyMarket}>
          <svg aria-hidden="true" viewBox="0 0 24 24" width="1em" height="1em" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round"><path d="M4 10v10h16V10M3 10l2-6h14l2 6M3 10a3 3 0 0 0 6 0 3 3 0 0 0 6 0 3 3 0 0 0 6 0M9 20v-6h6v6" /></svg>
        </button>
      </Tooltip>
      <HelpHub />
      <div className="global-navigation__bottom">
        <RailUpdateButton />
        {phase === 'signed-in' ? (
          <SidebarAccountEntry />
        ) : (
          <Tooltip label="계정" placement="right">
            <button
              className="rail-nav__item"
              aria-label="계정"
              onClick={() => useUiStore.getState().openSettings('account')}
            >
              <Icon name="user" />
            </button>
          </Tooltip>
        )}
        <Tooltip label="설정" placement="right">
          <button
            className="rail-nav__item"
            aria-label="설정"
            data-active={settingsOpen || undefined}
            onClick={() => useUiStore.getState().openSettings()}
          >
            <Icon name="settings" />
          </button>
        </Tooltip>
      </div>
    </nav>
  )
}
