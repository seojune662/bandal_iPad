import { createContext, useContext, useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { flushSync } from 'react-dom'
import { useStore } from 'zustand'
import { createStore, type StoreApi } from 'zustand/vanilla'
import type { InkTool, InkToolState } from '../../../upstream/src/renderer/src/features/ink/inkToolStore'
import { usePdfToolStore } from '../../../upstream/src/renderer/src/features/pdf/tools/toolStore'
import { focusPdfInputSurface } from './markdown'
import { readInputPreferences, writeInputPreferences, onInputPreferencesChanged, samePreset, type PenPreset, type PalettePosition, type InputPreferences } from './preferences'
import './input.css'

export interface PdfInputState extends InkToolState {
  favorites: InputPreferences['favorites']
  position: PalettePosition
  collapsed: boolean
  setActiveTool(tool: InkTool): void
  setColor(color: InkToolState['color']): void
  setWidth(width: number): void
  setOpacity(opacity: number): void
  rememberPen(): void
  choosePreset(preset: PenPreset): void
  saveFavorite(index: number): void
  setPosition(position: PalettePosition): void
  setCollapsed(collapsed: boolean): void
}
export function createPdfInputStore(): StoreApi<PdfInputState> {
  const preferences = readInputPreferences()
  let pen = { ...preferences.recentPen }, highlighter: PenPreset = { color: 'yellow', width: 0.004, opacity: 0.95 }
  return createStore<PdfInputState>()((set, get) => ({
    ...preferences.recentPen, activeTool: 'pen', favorites: preferences.favorites, position: preferences.position, collapsed: preferences.collapsed,
    setActiveTool: activeTool => {
      const current = get(), style = { color: current.color, width: current.width, opacity: current.opacity }
      if (current.activeTool === 'pen') { pen = style; current.rememberPen() }
      if (current.activeTool === 'highlighter') highlighter = style
      set({ activeTool, ...(activeTool === 'pen' ? pen : activeTool === 'highlighter' ? highlighter : {}) })
    },
    setColor: color => { set({ color }); get().rememberPen() },
    setWidth: width => { if (Number.isFinite(width)) { set({ width: Math.min(0.04, Math.max(0.001, width)) }); get().rememberPen() } },
    setOpacity: opacity => { if (Number.isFinite(opacity)) { set({ opacity: Math.min(1, Math.max(0.05, opacity)) }); get().rememberPen() } },
    rememberPen: () => {
      const state = get()
      if (state.activeTool !== 'pen') return
      pen = { color: state.color, width: state.width, opacity: state.opacity }
      writeInputPreferences({ ...readInputPreferences(), recentPen: pen })
    },
    choosePreset: preset => { pen = { ...preset }; set({ ...preset, activeTool: 'pen' }); get().rememberPen() },
    saveFavorite: index => {
      const state = get()
      if (state.activeTool !== 'pen' || !Number.isInteger(index) || index < 0 || index > 2) return
      const latest = readInputPreferences(), favorites = [...latest.favorites] as InputPreferences['favorites']
      favorites[index] = { color: state.color, width: state.width, opacity: state.opacity }
      set({ favorites }); writeInputPreferences({ ...latest, favorites })
    },
    setPosition: position => {
      const next = { x: Math.min(1, Math.max(0, position.x)), y: Math.min(1, Math.max(0, position.y)) }
      set({ position: next }); writeInputPreferences({ ...readInputPreferences(), position: next })
    },
    setCollapsed: collapsed => { set({ collapsed }); writeInputPreferences({ ...readInputPreferences(), collapsed }) }
  }))
}
export interface PdfInputScope {
  store: StoreApi<PdfInputState>
  owner: string
  active: boolean
  visible: boolean
  root: RefObject<HTMLDivElement>
}
const Context = createContext<PdfInputScope | null>(null)
export function usePdfInputScope(): PdfInputScope | null { return useContext(Context) }
// Outside a PDF provider, reused presentation components keep their original store.
export function usePdfInputStoreApi(): StoreApi<PdfInputState> {
  return useContext(Context)?.store ?? usePdfToolStore as unknown as StoreApi<PdfInputState>
}
export function usePdfInputStore<T>(selector: (state: PdfInputState) => T): T { return useStore(usePdfInputStoreApi(), selector) }

export function PdfInputProvider({ panelId, active, visible, onActivate, children }: {
  panelId: string; active: boolean; visible: boolean; onActivate(): void; children: ReactNode
}): JSX.Element {
  const [store] = useState(createPdfInputStore)
  const root = useRef<HTMLDivElement>(null)
  useEffect(() => onInputPreferencesChanged(() => {
    const favorites = readInputPreferences().favorites
    if (favorites.some((favorite, index) => !samePreset(favorite, store.getState().favorites[index]!))) store.setState({ favorites })
  }), [store])
  const scope = { store, owner: `pdf-input:${panelId}`, active, visible, root }
  return <Context.Provider value={scope}>
    <div ref={root} className="ipad-pdf-input-scope" data-ipad-pdf-active={active ? 'true' : 'false'}
      onPointerDownCapture={event => {
        const target = event.target instanceof Element ? event.target : null
        const scroller = target?.closest<HTMLElement>('.pdf-scroller')
        if (!scroller || target?.closest('button,input,textarea,[contenteditable="true"],.ink-layer__textbox-editor')) return
        // Publish active-panel props before InkLayer's same original event bubbles.
        if (!active) flushSync(onActivate)
        focusPdfInputSurface(scroller)
      }}>{children}</div>
  </Context.Provider>
}
