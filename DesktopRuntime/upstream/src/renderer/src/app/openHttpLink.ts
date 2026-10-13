import type { LinkRouting } from '../../../shared/types/settings'
import { invoke } from '../lib/ipc'
import { settingsSnapshot } from '../stores/settingsSnapshot'
import { createBrowserTab } from './tabCommands'

interface LinkModifiers {
  shift: boolean
  mod: boolean
}

export function shouldOpenExternally(
  routing: LinkRouting,
  modifiers: LinkModifiers
): boolean {
  return routing === 'system' || (modifiers.shift && modifiers.mod)
}

export function openHttpLink(
  url: string,
  modifiers: LinkModifiers = { shift: false, mod: false }
): void {
  const routing = settingsSnapshot().browser.linkRouting
  if (shouldOpenExternally(routing, modifiers)) {
    void invoke('shell:openExternal', { url })
    return
  }
  createBrowserTab(url)
}
