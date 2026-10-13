/**
 * Open/close state for the "+" new-tab menu. Kept as a tiny standalone
 * store so the header "+" button, the watermark affordance, and a future
 * ⌘T shortcut can all call `openNewTabMenu()` without prop drilling.
 */

import { create } from 'zustand'
import type { WorkspaceTarget } from './placementContext'

export interface MenuAnchor {
  x: number
  y: number
  target?: WorkspaceTarget
}

interface NewTabMenuState {
  isOpen: boolean
  /** Fixed-position anchor (viewport coords); null = centered fallback. */
  anchor: MenuAnchor | null
  open: (anchor?: MenuAnchor) => void
  close: () => void
}

export const useNewTabMenu = create<NewTabMenuState>()((set) => ({
  isOpen: false,
  anchor: null,
  open: (anchor) => {
    set({ isOpen: true, anchor: anchor ?? null })
  },
  close: () => {
    set({ isOpen: false })
  }
}))

/** Callable for keyboard shortcuts (⌘T wiring lands with the shell). */
export function openNewTabMenu(anchor?: MenuAnchor): void {
  useNewTabMenu.getState().open(anchor)
}
