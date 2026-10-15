import type { IpadAuxiliary, IpadPanelMode, IpadPanelModes, IpadPresentation } from './policy'

export const PANEL_MODES_KEY = 'bandal:ipad:panel-modes:v2'
export function readPanelModes(storage: Pick<Storage, 'getItem'>): IpadPanelModes {
  const defaults: IpadPanelModes = { left: 'auto', materials: 'auto', assistant: 'auto' }
  try {
    const saved = storage.getItem(PANEL_MODES_KEY)
    if (saved) {
      const parsed = JSON.parse(saved)
      for (const key of Object.keys(defaults) as IpadAuxiliary[]) if (parsed?.[key] === 'auto' || parsed?.[key] === 'overlay') defaults[key] = parsed[key]
      return defaults
    }
    // The old shell key only recorded a positive pin. Absence was not a choice.
    const legacy = storage.getItem('bandal:ipad:pinned-panel:v1')
    if (legacy === 'left') defaults.left = 'auto'
    if (legacy === 'right') defaults.materials = 'auto'
    if (storage.getItem('bandal:ipad:assistant-pin:v1') === 'false') defaults.assistant = 'overlay'
  } catch { /* Preferences are optional, including unavailable storage. */ }
  return defaults
}
let modes = (() => { try { return readPanelModes(localStorage) } catch { return { left: 'auto', materials: 'auto', assistant: 'auto' } as IpadPanelModes } })()
let revision = 0
let last: IpadAuxiliary = 'left'
let presentations: Record<IpadAuxiliary, IpadPresentation> = { left: 'closed', materials: 'closed', assistant: 'closed' }
export type AssistantRegistration = { panelId: string; width: number; close(): void }
let assistant: AssistantRegistration | null = null
const listeners = new Set<() => void>()
const emit = () => { revision++; for (const listener of listeners) listener() }
export const subscribeIpadPanels = (listener: () => void) => { listeners.add(listener); return () => { listeners.delete(listener) } }
export const ipadPanelRevision = () => revision
export const ipadPanelState = () => ({ modes, last, assistant })
export function noteIpadPresentation(value: typeof presentations): void { presentations = value }
export function activateIpadAuxiliary(surface: IpadAuxiliary): void { last = surface; emit() }
export function setIpadPanelMode(surface: IpadAuxiliary, mode: IpadPanelMode): void {
  modes = { ...modes, [surface]: mode }; last = surface
  try { localStorage.setItem(PANEL_MODES_KEY, JSON.stringify(modes)) } catch { /* Optional preference. */ }
  emit()
}
/** A suspended request is promoted, rather than accidentally switched off. */
export function toggleIpadRail(surface: 'left' | 'materials', requested: boolean): boolean {
  const next = !requested || presentations[surface] === 'suspended'
  if (next) {
    if (surface === 'materials') assistant?.close()
    activateIpadAuxiliary(surface)
  }
  return next
}
export function registerIpadAssistant(value: AssistantRegistration): () => void {
  if (assistant?.panelId !== value.panelId) assistant?.close()
  assistant = value; emit()
  return () => { if (assistant === value) { assistant = null; emit() } }
}
export function closeIpadAssistant(): void { assistant?.close() }

export function isIpadAssistantVisible(panelId: string): boolean { return assistant?.panelId === panelId && (presentations.assistant === 'docked' || presentations.assistant === 'overlay') }

export function isIpadRailVisible(surface: 'left' | 'materials'): boolean { return presentations[surface] === 'docked' || presentations[surface] === 'overlay' }
