import { useState } from 'react'
import { v4 as uuidv4 } from 'uuid'
import { Icon } from '../../app/icons'
import { ProviderMark } from '../../components/ProviderMark'
import { useLocale } from '../../i18n'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useBrowserGuests } from '../browser/browserGuestsStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { AI_WEB_SHORTCUTS, findAiShortcutPanel, persistAiShortcutsCollapsed, readAiShortcutsCollapsed, type AiWebService } from './aiShortcutModel'
import './aiShortcuts.css'

export function openAiShortcut(service: AiWebService): void {
  const workspace = useWorkspaceStore.getState()
  const browser = useBrowserGuests.getState()
  const existing = findAiShortcutPanel(service, workspace.openTabs, browser.nav, workspace.activePanelId, browser.liveGuests.map(guest => guest.tabId))
  if (existing !== null) {
    workspace.showCourseWorkspace(workspace.activeCourseId)
    workspace.activatePanel(existing)
    const descriptor = workspace.openTabs[existing]
    if (descriptor?.kind === 'browser') browser.touchGuest(descriptor.payload.tabId)
    return
  }
  const shortcut = AI_WEB_SHORTCUTS.find(shortcut => shortcut.id === service)!
  workspace.openTab(descriptorFor('browser', { tabId: uuidv4(), initialUrl: shortcut.url, profileId: 'default' }))
}

export function AiShortcuts(): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [collapsed, setCollapsed] = useState(readAiShortcutsCollapsed)
  return <section className="ai-shortcuts-section" aria-label={ko ? 'AI 웹 바로가기' : 'AI web shortcuts'}>
    <button type="button" className="ai-shortcuts-section__heading" aria-expanded={!collapsed} aria-label={ko ? `AI 바로가기 ${collapsed ? '펼치기' : '접기'}` : `${collapsed ? 'Expand' : 'Collapse'} AI shortcuts`} onClick={() => {
      const next = !collapsed
      persistAiShortcutsCollapsed(next)
      setCollapsed(next)
    }}>
      <Icon name="chevronRight" />
      <span>AI</span>
    </button>
    {!collapsed && <ul className="ai-shortcuts">
      {AI_WEB_SHORTCUTS.map(shortcut => <li key={shortcut.id}>
        <button type="button" className="ai-shortcut" title={ko ? `${shortcut.label} 웹 열기` : `Open ${shortcut.label} web`} onClick={() => openAiShortcut(shortcut.id)}>
          <ProviderMark provider={shortcut.provider} size={20} />
          <span>{shortcut.label}</span>
        </button>
      </li>)}
    </ul>}
  </section>
}
