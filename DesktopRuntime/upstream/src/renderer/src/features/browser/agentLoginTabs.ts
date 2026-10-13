import type { BrowserOpenUrl } from '../../../../shared/ipc/events'
import type { AgentProvider } from '../../../../shared/types/agent-events'
import { onPush } from '../../lib/ipc'
import { retainedTabDescriptors, useWorkspaceStore, workspaceApiForCourse } from '../../stores/workspaceStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { useUiStore } from '../../stores/uiStore'
import { showToast } from '../../app/toast'
import { useBrowserGuests } from './browserGuestsStore'
import { isAgentConnectionReady, useAgentConnectionStore } from '../chat/agentConnectionStore'
import { agentConnectionCopy } from '../chat/agentConnectionCopy'
import { getLocale } from '../../i18n/localeStore'

interface LoginTab { tabId: string; provider: AgentProvider; origin: string; callbackUrl: string | null; previousPanelId: string | null; courseId: string | null }
const loginTabs = new Map<string, LoginTab>()
const loginPopups = new Map<string, { provider: AgentProvider; requestId: string; origin: string }>()

/** OAuth redirects may finish on loopback; never close a tab repurposed for another site. */
export function isLoginTabUrl(initialOrigin: string, currentUrl: string, callbackUrl: string | null = null, provider?: AgentProvider): boolean {
  try {
    const url = new URL(currentUrl)
    if (callbackUrl && url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) {
      const callback = new URL(callbackUrl)
      if (url.origin === callback.origin && url.pathname === callback.pathname) return true
      // Codex serves its completion page after the OAuth callback. Older
      // versions used localhost for one URL and 127.0.0.1 for the other.
      const codexOrigin = ['https://auth.openai.com', 'https://chatgpt.com'].includes(initialOrigin)
      if (provider === 'codex' && codexOrigin && url.pathname === '/success' && callback.protocol === 'http:'
        && ['localhost', '127.0.0.1', '[::1]'].includes(callback.hostname) && url.port === callback.port) return true
    }
    if (url.origin === 'https://accounts.google.com' && /^\/(?:signin|v3\/signin|o\/oauth2|ServiceLogin)(?:\/|$)/u.test(url.pathname)) return true
    if (url.origin === 'https://platform.claude.com' && ['/oauth/code', '/oauth/code/callback', '/oauth/code/success'].includes(url.pathname)) return true
    if (url.origin !== initialOrigin) return false
    if (url.hostname === 'claude.com') return /^\/(?:cai\/oauth|oauth|login|signin|sign-in|auth|sso)(?:\/|$)/u.test(url.pathname)
    if (url.hostname === 'claude.ai') return /^\/(?:oauth|login|signin|sign-in|auth|sso)(?:\/|$)/u.test(url.pathname)
    return true
  } catch { return false }
}

export function getAgentLoginForTab(tabId: string): { provider: AgentProvider; requestId: string } | null {
  for (const [requestId, login] of loginTabs) if (login.tabId === tabId) return { provider: login.provider, requestId }
  const popup = loginPopups.get(tabId)
  return popup ? { provider: popup.provider, requestId: popup.requestId } : null
}

/** Reopening a sign-in page focuses its existing private tab. Ownership is memory-only. */
export function prepareAgentLoginTab(payload: BrowserOpenUrl, proposedId: string): { tabId: string; courseId: string | null | undefined } {
  if (!payload.loginRequestId || !payload.loginProvider) {
    const opener = payload.openerTabId ? getAgentLoginForTab(payload.openerTabId) : null
    if (opener) loginPopups.set(proposedId, { ...opener, origin: new URL(payload.url).origin })
    return { tabId: proposedId, courseId: payload.courseId }
  }
  const previous = loginTabs.get(payload.loginRequestId)
  const existing = previous && retainedTabDescriptors().find(tab => tab.kind === 'browser' && tab.payload.tabId === previous.tabId)
  if (existing && previous) {
    const workspace = useWorkspaceStore.getState()
    // Selecting the owning course makes the normal open path focus the
    // retained panel instead of adding a duplicate to an inactive Dockview.
    if (workspace.activeCourseId !== previous.courseId || workspace.surface !== 'course') useCoursesStore.getState().selectCourse(previous.courseId)
    return { tabId: previous.tabId, courseId: previous.courseId }
  }
  const workspace = useWorkspaceStore.getState()
  loginTabs.set(payload.loginRequestId, {
    tabId: proposedId, provider: payload.loginProvider, origin: new URL(payload.url).origin,
    callbackUrl: new URL(payload.url).searchParams.get('redirect_uri'),
    previousPanelId: previous?.previousPanelId ?? workspace.activePanelSource()?.panelId ?? null,
    courseId: workspace.activeCourseId
  })
  return { tabId: proposedId, courseId: workspace.activeCourseId }
}

export function installAgentLoginTabLifecycle(): () => void {
  const completed = new Set<AgentProvider>()
  const stopConnection = useAgentConnectionStore.subscribe(state => {
    for (const provider of completed) {
      const connection = state.connections[provider]
      if (connection.stage === 'idle' && isAgentConnectionReady(connection.availability)) {
        completed.delete(provider)
        showToast(agentConnectionCopy(getLocale(), provider).readyMessage)
      }
    }
  })
  const stopProgress = onPush('agent:login-progress', event => {
    if (event.stage !== 'done' && event.stage !== 'cancelled' && event.stage !== 'error') return
    const owned = loginTabs.get(event.requestId)
    if (!owned || owned.provider !== event.provider) return
    loginTabs.delete(event.requestId)
    if (event.stage === 'done') completed.add(event.provider)
    const targets = [{ tabId: owned.tabId, origin: owned.origin }]
    for (const [tabId, popup] of loginPopups) {
      if (popup.requestId !== event.requestId) continue
      targets.push({ tabId, origin: popup.origin }); loginPopups.delete(tabId)
    }
    const workspace = useWorkspaceStore.getState()
    const activeTabId = workspace.activeBrowserTabId()
    let wasActive = false
    for (const target of targets) {
      const descriptor = retainedTabDescriptors().find(tab => tab.kind === 'browser' && tab.payload.tabId === target.tabId)
      if (descriptor?.kind !== 'browser') continue
      const currentUrl = useBrowserGuests.getState().nav[target.tabId]?.url ?? descriptor.payload.initialUrl
      if (!isLoginTabUrl(target.origin, currentUrl, owned.callbackUrl, owned.provider)) continue
      wasActive ||= activeTabId === target.tabId
      if (owned.courseId === null) {
        // Resource deletion skips the temporary no-course canvas. Managed
        // login pages still own their panels there and must remove them.
        const temporary = workspaceApiForCourse(null)
        for (const panel of [...temporary?.panels ?? []]) {
          const candidate = panel.params?.descriptor
          if (candidate?.kind === 'browser' && candidate.payload.tabId === target.tabId) panel.api.close()
        }
        if (workspace.activeCourseId === null) workspace.notifyLayoutChanged()
      } else workspace.closeTabsMatching(descriptor)
    }
    if (wasActive && owned.courseId === workspace.activeCourseId) {
      if (owned.previousPanelId) workspace.activatePanel(owned.previousPanelId)
      else useUiStore.getState().openSettings('ai')
    }
  })
  return () => { stopProgress(); stopConnection(); completed.clear(); loginTabs.clear(); loginPopups.clear() }
}
