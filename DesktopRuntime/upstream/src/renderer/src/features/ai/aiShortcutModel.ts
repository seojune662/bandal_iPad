import type { TabDescriptor } from '../../../../shared/tabs'
import type { AgentProvider } from '../../../../shared/types/agent-events'

export type AiWebService = 'chatgpt' | 'gemini' | 'claude'
export const AI_WEB_SHORTCUTS: readonly { id: AiWebService; label: string; url: string; provider: AgentProvider; hosts: readonly string[] }[] = [
  { id: 'chatgpt', label: 'ChatGPT', url: 'https://chatgpt.com/', provider: 'codex', hosts: ['chatgpt.com', 'chat.openai.com'] },
  { id: 'gemini', label: 'Gemini', url: 'https://gemini.google.com/app', provider: 'gemini', hosts: ['gemini.google.com'] },
  { id: 'claude', label: 'Claude', url: 'https://claude.ai/new', provider: 'claude-code', hosts: ['claude.ai'] }
]

/** Match the live page, including conversation URLs, without resetting it. */
export function findAiShortcutPanel(service: AiWebService, openTabs: Record<string, TabDescriptor>, nav: Record<string, { url: string } | undefined>, activePanelId: string | null, recentTabIds: readonly string[]): string | null {
  const hosts = AI_WEB_SHORTCUTS.find(shortcut => shortcut.id === service)!.hosts
  const matches: { panelId: string; recency: number; order: number }[] = []
  for (const [panelId, descriptor] of Object.entries(openTabs)) {
    if (descriptor.kind !== 'browser' || descriptor.payload.isPrivate) continue
    const url = nav[descriptor.payload.tabId]?.url ?? descriptor.payload.initialUrl
    try {
      const parsed = new URL(url)
      if (!['https:', 'http:'].includes(parsed.protocol) || !hosts.includes(parsed.hostname)) continue
    } catch { continue }
    if (panelId === activePanelId) return panelId
    matches.push({ panelId, recency: recentTabIds.lastIndexOf(descriptor.payload.tabId), order: matches.length })
  }
  // Unvisited restored tabs have no live guest yet; prefer the last such tab.
  return matches.sort((a, b) => b.recency - a.recency || b.order - a.order).at(0)?.panelId ?? null
}

export const AI_SHORTCUTS_COLLAPSED_KEY = 'bandal:ai-shortcuts:collapsed:v1'
export function readAiShortcutsCollapsed(): boolean {
  try { return typeof window !== 'undefined' && window.localStorage.getItem(AI_SHORTCUTS_COLLAPSED_KEY) === 'true' } catch { return false }
}
export function persistAiShortcutsCollapsed(collapsed: boolean): void {
  try { window.localStorage.setItem(AI_SHORTCUTS_COLLAPSED_KEY, String(collapsed)) } catch { /* Storage can be disabled. */ }
}
