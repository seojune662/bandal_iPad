import type { IDockviewPanelProps } from 'dockview'
import type { LearningBinding, LearningProjectSummary } from '../../../../shared/types/learning'
import type { LearningTabPayload } from '../../../../shared/tabs'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor, tabPanelId } from '../workspace/tabIdentity'

/** A copy can share an id; the original folder must be absent before recovery. */
export function findMovedLearningBinding(original: LearningBinding, projectId: string, projects: LearningProjectSummary[]): LearningBinding | null {
  const peers = projects.filter(project => project.binding.courseId === original.courseId)
  if (peers.some(project => project.binding.rootRelPath === original.rootRelPath)) return null
  const candidates = peers.filter(project => project.projectId === projectId && !project.warning)
  return candidates.length === 1 ? candidates[0]!.binding : null
}

/** Dockview ids are immutable: replace this panel in place with its new binding. */
export function rebindLearningPanel(props: IDockviewPanelProps, payload: LearningTabPayload): void {
  const descriptor = descriptorFor('learning', payload)
  const container = props.containerApi
  const original = container.getPanel(props.api.id)
  if (!original) return
  const active = container.activePanel
  const wasActive = active?.id === original.id
  const id = tabPanelId(descriptor)
  const existing = container.getPanel(id)
  const next = existing ?? container.addPanel({ id, component: 'learning', title: original.title ?? '학습 공간',
    params: { descriptor }, position: { referencePanel: original, index: original.group.panels.findIndex(panel => panel.id === original.id) } })
  if (existing && wasActive) existing.api.updateParameters({ descriptor })
  original.api.close()
  if (wasActive) next.api.setActive()
  else if (active) active.api.setActive()
  useWorkspaceStore.getState().notifyLayoutChanged()
}
