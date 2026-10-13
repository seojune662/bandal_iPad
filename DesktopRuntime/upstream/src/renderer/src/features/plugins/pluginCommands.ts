import { showToast } from '../../app/toast'
import { usePluginsStore } from '../../stores/pluginsStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'

export function openPluginPanel(pluginId: string, panelId: string): void {
  useWorkspaceStore
    .getState()
    .openTab(descriptorFor('plugin-panel', { pluginId, panelId }))
}

export async function runPluginCommand(
  pluginId: string,
  commandId: string,
  context?: { courseId: string; relPath: string },
  options: { notify?: boolean } = {}
): Promise<void> {
  try {
    await usePluginsStore.getState().runCommand(pluginId, commandId, context)
  } catch (error) {
    console.error('[Bandal] 플러그인 명령을 실행하지 못했습니다.', error)
    if (options.notify !== false) showToast('플러그인 명령을 실행하지 못했어요.', 'danger')
    throw error
  }
}
