import { createContext, useContext } from 'react'
export interface AssistantPanelState {
  courseId?: string
  conversationId: string
  open: boolean
  highlightsOpen: boolean
  width: number
}
export function normalizeAssistantPanel(value: unknown): AssistantPanelState {
  const r = value && typeof value === 'object' ? value as Partial<AssistantPanelState> & { section?: unknown } : {}
  return {
    ...(typeof r.courseId === 'string' && r.courseId ? { courseId: r.courseId } : {}),
    conversationId: typeof r.conversationId === 'string' && r.conversationId ? r.conversationId : crypto.randomUUID(),
    open: r.open === true && r.section !== 'highlights',
    highlightsOpen: r.highlightsOpen === true || (r.open === true && r.section === 'highlights'),
    width: typeof r.width === 'number' && Number.isFinite(r.width) ? Math.min(480, Math.max(280, r.width)) : 320
  }
}
export const PanelAssistantContext = createContext<{
  panelId: string
  open: boolean
  toggle: () => void
  highlightsOpen: boolean
  setHighlightsOpen: (open: boolean) => void
  ask: (text: string) => void
} | null>(null)
export const usePanelAssistant = () => useContext(PanelAssistantContext)
