import { useUiStore } from '../stores/uiStore'
import { useWorkspaceStore } from '../stores/workspaceStore'

/** Keep course layouts and sidebar preferences alive while browsing the market. */
export function openStudyMarket(): void {
  const ui = useUiStore.getState()
  ui.closeSettings(); ui.closeBoardOverlay(); ui.closeLinkGraph()
  useUiStore.setState({ leftRailOpen: true })
  useWorkspaceStore.getState().showStudyMarket()
}
