import { useContext, useEffect, useRef, useState } from 'react'
import type { IDockviewPanelHeaderProps } from 'dockview'
import { Icon } from '../../app/icons'
import { Tooltip } from '../../components/Tooltip'
import { useT } from '../../i18n'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { TabContextMenu } from './TabContextMenu'
import { isTabDescriptor } from './tabIdentity'
import { setWorkspaceTabDragImage, writeWorkspaceTabDragData } from './tabDrag'
import { WorkspaceTabIcon } from './workspaceIcons'
import { WorkspaceCourseContext } from './placementContext'
import { tabDragSession } from './tabDragSession'
import { layoutAdaptiveTabs } from './adaptiveTabs'
import './adaptive-tabs.css'

export function WorkspaceTab(props: IDockviewPanelHeaderProps): JSX.Element {
  const t = useT()
  const workspaceCourseId = useContext(WorkspaceCourseContext)
  const [title, setTitle] = useState(props.api.title ?? '')
  const [contextMenu, setContextMenu] = useState<{
    x: number
    y: number
    placement: 'top' | 'bottom'
    align: 'start' | 'end'
    rightPanelIds: string[]
  } | null>(null)
  const tabRef = useRef<HTMLDivElement>(null)
  const courses = useCoursesStore((state) => state.courses)
  const course = courses.find((entry) => entry.id === workspaceCourseId) ?? null
  useEffect(() => {
    const disposable = props.api.onDidTitleChange((event) => {
      setTitle(event.title)
    })
    return () => disposable.dispose()
  }, [props.api])

  const rawDescriptor = (props.params as Record<string, unknown>)['descriptor']
  const descriptor = isTabDescriptor(rawDescriptor) ? rawDescriptor : null
  const canOpenNewInstance =
    descriptor !== null &&
    descriptor.kind !== 'board'

  useEffect(() => {
    if (descriptor === null) return
    let dockviewTab: HTMLElement | null = null
    const handleDragStart = (event: DragEvent): void => {
      if (event.dataTransfer === null || dockviewTab === null) return
      const source = {
        courseId: workspaceCourseId, panelId: props.api.id, nonce: crypto.randomUUID()
      }
      tabDragSession.beginTab(source)
      writeWorkspaceTabDragData(event.dataTransfer, descriptor, title, source)
      setWorkspaceTabDragImage(event.dataTransfer, dockviewTab, title)
    }
    const handleKeyDown = (event: KeyboardEvent): void => {
      if (
        dockviewTab === null ||
        event.target !== dockviewTab ||
        event.metaKey ||
        event.ctrlKey ||
        event.altKey
      )
        return
      const panels = props.api.group.panels
      const current = panels.findIndex((panel) => panel.id === props.api.id)
      let index: number | undefined
      if (event.key === 'ArrowLeft')
        index = (current + panels.length - 1) % panels.length
      if (event.key === 'ArrowRight') index = (current + 1) % panels.length
      if (event.key === 'Home') index = 0
      if (event.key === 'End') index = panels.length - 1
      if (event.key === 'Enter' || event.key === ' ') index = current
      if (index === undefined) return
      event.preventDefault()
      event.stopPropagation()
      const elements =
        dockviewTab.parentElement?.querySelectorAll<HTMLElement>('.dv-tab')
      panels[index]?.api.setActive()
      layoutAdaptiveTabs(props.api.group.element)
      elements?.[index]?.focus()
    }
    const unbind = (): void => {
      dockviewTab?.removeEventListener('dragstart', handleDragStart)
      dockviewTab?.removeEventListener('keydown', handleKeyDown)
    }
    const updateSelection = (): void => {
      const current = tabRef.current?.closest<HTMLElement>('.dv-tab') ?? null
      if (current !== dockviewTab) {
        unbind()
        dockviewTab = current
        dockviewTab?.addEventListener('dragstart', handleDragStart)
        dockviewTab?.addEventListener('keydown', handleKeyDown)
      }
      if (!dockviewTab) return
      const selected = props.api.group.activePanel?.id === props.api.id
      dockviewTab.setAttribute('role', 'tab')
      dockviewTab.setAttribute('aria-label', title)
      dockviewTab.setAttribute('aria-selected', String(selected))
      dockviewTab.tabIndex = selected ? 0 : -1
    }
    let disposed = false
    let groupUpdateQueued = false
    const groupChanged = (): void => {
      if (groupUpdateQueued) return
      groupUpdateQueued = true
      // Whole-group merges can omit onDidMovePanel for the moved tabs. The
      // group event precedes DOM placement, which finishes in this same turn.
      queueMicrotask(() => {
        groupUpdateQueued = false
        if (!disposed) updateSelection()
      })
    }
    updateSelection()
    // Dockview preserves this React header but replaces its .dv-tab wrapper
    // when moving panels or restoring layouts. Group-change fires before the
    // new wrapper exists, so also bind on the completed container events.
    const selection = [
      props.api.onDidActiveChange(updateSelection),
      props.api.onDidVisibilityChange(updateSelection),
      props.api.onDidGroupChange(groupChanged),
      props.containerApi.onDidMovePanel(event => { if (event.panel.id === props.api.id) updateSelection() }),
      props.containerApi.onDidLayoutFromJSON(updateSelection)
    ]
    return () => {
      disposed = true
      selection.forEach(subscription => subscription.dispose())
      unbind()
    }
  }, [descriptor, title, props.api, props.containerApi, workspaceCourseId])

  return (
    <>
      <Tooltip
        label={
          canOpenNewInstance
            ? t('workspace.tab.newInstanceTooltip', { title })
            : title
        }
        placement="bottom"
      >
        <div
          ref={tabRef}
          className="workspace-tab"
          onContextMenu={(event) => {
            if (descriptor === null || course === null) return
            event.preventDefault()
            event.stopPropagation()
            props.api.setActive()
            const panels = props.api.group.panels
            const index = panels.findIndex((panel) => panel.id === props.api.id)
            setContextMenu({
              x: event.clientX,
              y: event.clientY,
              placement:
                event.clientY > window.innerHeight / 2 ? 'top' : 'bottom',
              align: event.clientX > window.innerWidth / 2 ? 'end' : 'start',
              rightPanelIds:
                index < 0
                  ? []
                  : panels.slice(index + 1).map((panel) => panel.id)
            })
          }}
          onMouseDown={(event) => {
            if (event.button === 1) {
              event.preventDefault()
              void useWorkspaceStore.getState().closeTab(props.api.id)
            }
          }}
          onClick={(event) => {
            if (
              descriptor === null ||
              !canOpenNewInstance ||
              !(window.bandal?.platform === 'darwin'
                ? event.metaKey
                : event.ctrlKey)
            ) {
              return
            }
            event.preventDefault()
            event.stopPropagation()
            useWorkspaceStore
              .getState()
              .openTab(descriptor, { newInstance: true })
          }}
        >
          {descriptor !== null && (
            <WorkspaceTabIcon
              descriptor={descriptor}
              className="workspace-tab__kind"
            />
          )}
          <span className="workspace-tab__title">{title}</span>
          <button
            type="button"
            className="workspace-tab__close"
            aria-label={`${title} 탭 닫기`}
            onMouseDown={(event) => event.stopPropagation()}
            onPointerDownCapture={(event) => event.stopPropagation()}
            onClick={(event) => {
              event.stopPropagation()
              void useWorkspaceStore.getState().closeTab(props.api.id)
            }}
          >
            <Icon name="x" />
          </button>
        </div>
      </Tooltip>
      {contextMenu !== null && descriptor !== null && course !== null && (
        <TabContextMenu
          descriptor={descriptor}
          label={title}
          course={course}
          panelId={props.api.id}
          rightPanelIds={contextMenu.rightPanelIds}
          containerApi={props.containerApi}
          x={contextMenu.x}
          y={contextMenu.y}
          placement={contextMenu.placement}
          align={contextMenu.align}
          returnFocus={tabRef.current?.closest<HTMLElement>('.dv-tab') ?? null}
          onClose={() => setContextMenu(null)}
        />
      )}
    </>
  )
}
