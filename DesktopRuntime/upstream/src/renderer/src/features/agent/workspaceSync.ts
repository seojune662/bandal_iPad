/** Publishes the non-browser workspace tabs visible to the student. */

import { useEffect } from 'react'
import type { TabDescriptor } from '../../../../shared/tabs'
import { readDocumentContexts } from './documentContext'
import type { MaterialContext } from '../../../../shared/types/chatContext'
import { invoke, onPush } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import {
  isTabDescriptor,
  tabPanelId,
  tabTitle
} from '../workspace/tabIdentity'

export interface AgentWorkspaceTab {
  kind: string
  title: string
  active: boolean
  courseId?: string
  relPath?: string
  documentId?: string
}

export interface AgentWorkspaceSyncPayload {
  activeKind?: string
  selectedCourseId: string | null
  tabs: AgentWorkspaceTab[]
  documents?: MaterialContext[]
  selection?: string
  refreshId?: string
}

export interface WorkspaceSyncSources {
  surface?: 'course' | 'learning-home' | 'study-market'
  openTabs: Record<string, TabDescriptor>
  activeDescriptor: TabDescriptor | null
  selectedCourseId: string | null
  hydration: string
}

/** Builds the renderer-owned view of the non-browser workspace. */
export function workspaceSyncPayload(
  sources: WorkspaceSyncSources
): AgentWorkspaceSyncPayload | null {
  if (sources.surface !== undefined && sources.surface !== 'course') return { selectedCourseId: null, tabs: [], documents: [], selection: '' }
  if (sources.hydration !== 'ready') return null

  const activePanelId =
    sources.activeDescriptor === null
      ? null
      : tabPanelId(sources.activeDescriptor)
  let activeFound = false
  const tabs: AgentWorkspaceTab[] = []

  for (const [panelId, descriptor] of Object.entries(sources.openTabs)) {
    if (!isTabDescriptor(descriptor) || descriptor.kind === 'browser') continue

    const active =
      !activeFound &&
      activePanelId !== null &&
      tabPanelId(descriptor) === activePanelId
    if (active) activeFound = true

    tabs.push({
      ...('courseId' in descriptor.payload && descriptor.payload.courseId ? { courseId: descriptor.payload.courseId } : {}),
      ...('relPath' in descriptor.payload ? { relPath: descriptor.payload.relPath } : {}),
      documentId: panelId,
      kind: descriptor.kind,
      title: tabTitle(descriptor),
      active
    })
  }

  return {
    ...(sources.activeDescriptor ? { activeKind: sources.activeDescriptor.kind } : {}),
    selectedCourseId: sources.selectedCourseId,
    tabs
  }
}

function currentPayload(): AgentWorkspaceSyncPayload | null {
  const workspace = useWorkspaceStore.getState()
  return workspaceSyncPayload({
    surface: workspace.surface,
    openTabs: workspace.openTabs,
    activeDescriptor: workspace.activeTabDescriptor(),
    selectedCourseId: useCoursesStore.getState().selectedCourseId,
    hydration: workspace.hydration
  })
}

const SYNC_DEBOUNCE_MS = 200

/** Keeps main's cached view of the student's app workspace current. */
export function useAgentWorkspaceSync(): void {
  useEffect(() => {
    let timer: number | null = null
    let lastSent = ''

    const publish = (refreshId?: string): void => {
      timer = null
      const payload = currentPayload()
      if (payload === null) return
      const courseVisible = useWorkspaceStore.getState().surface === 'course'
      payload.documents = courseVisible ? readDocumentContexts() : []
      const selected = courseVisible ? window.getSelection()?.toString().trim() : ''
      if (selected && !document.activeElement?.closest('.chat-tab')) payload.selection = selected.slice(0, 8000)
      if (refreshId) payload.refreshId = refreshId
      const serialized = JSON.stringify(payload)
      if (serialized === lastSent) return

      try {
        const request = invoke('agent:syncWorkspace', payload)
        lastSent = serialized
        void request.catch(() => {
          if (lastSent === serialized) lastSent = ''
        })
      } catch {
        // A synchronous transport failure must not escape a store notification.
      }
    }

    const schedule = (): void => {
      if (timer !== null) window.clearTimeout(timer)
      timer = window.setTimeout(() => publish(), SYNC_DEBOUNCE_MS)
    }

    const selectionChanged = (): void => { if (window.getSelection()?.toString().trim()) publish() }
    if (typeof document !== 'undefined') document.addEventListener('selectionchange', selectionChanged)
    const blurred = (): void => publish()
    window.addEventListener('blur', blurred)
    schedule()
    const unsubWorkspace = useWorkspaceStore.subscribe(schedule)
    // Course selection is also the context used by plugin commands. Publishing
    // it immediately avoids a freshly-created/selected course briefly looking
    // like "no course" when a command is invoked inside the debounce window.
    const unsubCourses = useCoursesStore.subscribe(() => publish())
    const offRefresh = onPush('assistant:contextRefresh', ({ requestId }) => publish(requestId))
    return () => {
      if (timer !== null) window.clearTimeout(timer)
      if (typeof document !== 'undefined') document.removeEventListener('selectionchange', selectionChanged)
      window.removeEventListener('blur', blurred)
      offRefresh()
      unsubWorkspace()
      unsubCourses()
    }
  }, [])
}
