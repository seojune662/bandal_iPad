/**
 * [M8] Opening a university shortcut.
 *
 * Two destinations, decided by one flag:
 *  - embedded → a Bandal browser tab on the `persist:browsing` partition, so
 *    the school login survives between shortcuts and app restarts. We never
 *    store passwords; the partition cookie is the whole mechanism.
 *  - external → `shell.openExternal`, for the three classes of sites that
 *    cannot work in an embedded webview (docs/university-sites.md §5.2).
 */

import { v4 as uuidv4 } from 'uuid'
import { descriptorFor } from '../workspace/tabIdentity'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { invoke } from '../../lib/ipc'
import { showToast } from '../../app/toast'

/** Opens `url` inside the app as a new browser tab. */
export function openInBandalBrowser(url: string): void {
  useWorkspaceStore
    .getState()
    .openTab(descriptorFor('browser', { tabId: uuidv4(), initialUrl: url }))
}

/** Hands `url` to the system browser; surfaces a toast when that fails. */
export async function openInSystemBrowser(url: string): Promise<void> {
  try {
    await invoke('shell:openExternal', { url })
  } catch (error) {
    console.error('[Bandal] 기본 브라우저로 열지 못했습니다.', error)
    showToast('기본 브라우저로 열지 못했어요.', 'danger')
  }
}

export function openShortcut(target: {
  url: string
  opensExternally: boolean
}): void {
  if (target.opensExternally) {
    void openInSystemBrowser(target.url)
    return
  }
  openInBandalBrowser(target.url)
}
