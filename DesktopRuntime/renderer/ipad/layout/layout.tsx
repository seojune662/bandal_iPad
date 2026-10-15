import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type ReactNode, type RefObject } from 'react'
import type { DockviewApi } from 'dockview'
import { useUiStore } from '../../../upstream/src/renderer/src/stores/uiStore'
import { useT } from '../../../upstream/src/renderer/src/i18n'
import { Icon as SettingsIcon } from '../../../upstream/src/renderer/src/features/settings/SettingsIcon'
import { useWorkspaceStore } from '../../../upstream/src/renderer/src/stores/workspaceStore'
import { focusableElements, useFocusTrap } from '../../../upstream/src/renderer/src/components/useFocusTrap'
import { openActiveAssistant, useActiveAssistantOpen } from '../../../upstream/src/renderer/src/features/assistantPanel/assistantController'
import { setNativeHostBlocked } from '../nativeSurfaces'
import { IpadSidebarSwipe } from './sidebarSwipe'
import { ipadLayout, minimumSplitWidth, retainSplitProportions, splitGroupFractions, type IpadSide, type IpadAuxiliary } from './policy'
import { activateIpadAuxiliary, closeIpadAssistant, ipadPanelRevision, ipadPanelState, noteIpadPresentation, registerIpadAssistant, setIpadPanelMode, subscribeIpadPanels } from './coordination'
export { toggleIpadRail, activateIpadAuxiliary, isIpadAssistantVisible, isIpadRailVisible } from './coordination'
import './layout.css'

export function useIpadWidth(): number {
  const [width, setWidth] = useState(() => window.innerWidth)
  useLayoutEffect(() => {
    const update = () => setWidth(window.innerWidth)
    window.addEventListener('resize', update)
    return () => window.removeEventListener('resize', update)
  }, [])
  return width
}
function useIpadPanelPolicy(assistantWidth?: number) {
  const width = useIpadWidth()
  useSyncExternalStore(subscribeIpadPanels, ipadPanelRevision)
  const left = useUiStore(state => state.leftRailOpen)
  const courseRail = useUiStore(state => state.courseRailOpen)
  const surface = useWorkspaceStore(state => state.surface)
  const right = useUiStore(state => state.rightRailOpen)
  const settings = useUiStore(state => state.isSettingsOpen)
  const { modes, last, assistant } = ipadPanelState()
  const effectiveAssistantWidth = settings ? undefined : assistantWidth ?? assistant?.width
  return { width, modes, ...ipadLayout(width, { left: !settings && left && courseRail && surface !== 'study-market', materials: !settings && right,
    ...(effectiveAssistantWidth !== undefined ? { assistantWidth: effectiveAssistantWidth } : {}) }, modes, last) }
}
export function useIpadRailVisible(surface: 'left' | 'materials'): boolean {
  const layout = useIpadPanelPolicy()
  return layout.panels[surface] === 'docked' || layout.panels[surface] === 'overlay'
}
export function useIpadNavigationBlocked(): boolean {
  const layout = useIpadPanelPolicy()
  const settings = useUiStore(state => state.isSettingsOpen)
  return settings || layout.overlayOwner !== null && layout.overlayOwner !== 'left'
}
/** One focus owner for a modal shell sheet; docked panels remain ordinary navigation. */
function useRailFocus(owner: IpadAuxiliary | null, close: () => void) {
  const closeRef = useRef(close); closeRef.current = close
  const currentOwner = useRef(owner); currentOwner.current = owner
  useLayoutEffect(() => {
    if (owner !== 'left' && owner !== 'materials') return
    const panel = document.querySelector<HTMLElement>(owner === 'left' ? '.ipad-left-surface' : '.ipad-right-surface')
    if (!panel) return
    const focused = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const previous = focused && focused !== document.body && focused !== document.documentElement && !panel.contains(focused) ? focused : document.querySelector<HTMLElement>(owner === 'left' ? '.ipad-shell-chrome button' : '.titlebar-button[aria-label^="자료 사이드바"]')
    const frame = requestAnimationFrame(() => { if (!panel.contains(document.activeElement)) focusableElements(panel)[0]?.focus({ preventScroll: true }) })
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return
      const nested = document.activeElement?.closest('[role="dialog"], [role="alertdialog"]')
      if (nested && nested !== panel) return
      if (event.key === 'Escape') { event.preventDefault(); closeRef.current(); return }
      if (event.key !== 'Tab') return
      const navigation = owner === 'left' ? document.querySelector<HTMLElement>('.global-navigation') : null
      const targets = [...(navigation ? focusableElements(navigation) : []), ...focusableElements(panel)]
      if (!targets.length) return
      event.preventDefault()
      const index = targets.indexOf(document.activeElement as HTMLElement)
      targets[index < 0 ? 0 : (index + (event.shiftKey ? -1 : 1) + targets.length) % targets.length]?.focus({ preventScroll: true })
    }
    window.addEventListener('keydown', key)
    return () => {
      cancelAnimationFrame(frame); window.removeEventListener('keydown', key)
      // Reflow only ends modal focus ownership. Keep a search/editor focused
      // while its requested panel becomes docked or temporarily suspended.
      const requested = () => owner === 'left' ? useUiStore.getState().leftRailOpen : useUiStore.getState().rightRailOpen
      if (!requested()) requestAnimationFrame(() => {
        // A newly opened modal owns focus; a docked AI does not prevent return.
        if (requested() || currentOwner.current !== null || useUiStore.getState().isSettingsOpen) return
        if (previous?.isConnected && !previous.closest('[inert], [hidden]') && previous.getClientRects().length && getComputedStyle(previous).visibility !== 'hidden') previous.focus({ preventScroll: true })
      })
    }
  }, [owner])
}
export function useIpadShellLayout() {
  const layout = useIpadPanelPolicy()
  const left = useUiStore(state => state.leftRailOpen)
  const right = useUiStore(state => state.rightRailOpen)
  const settings = useUiStore(state => state.isSettingsOpen)
  const board = useUiStore(state => state.isBoardOverlayOpen)
  const graph = useUiStore(state => state.isLinkGraphOpen)
  const materialsAvailable = useWorkspaceStore(state => state.surface === 'course' && state.activePanelSource()?.descriptor.kind !== 'learning')
  const previous = useRef({ left, right })
  const close = (side?: IpadSide) => {
    const owner = side === 'left' ? 'left' : side === 'right' ? 'materials' : layout.overlayOwner
    if (owner === 'left') useUiStore.setState({ leftRailOpen: false })
    else if (owner === 'materials') useUiStore.setState({ rightRailOpen: false })
  }
  useLayoutEffect(() => {
    noteIpadPresentation(layout.panels)
  }, [layout.panels.left, layout.panels.materials, layout.panels.assistant])
  useLayoutEffect(() => {
    if (settings || board || graph) { useUiStore.setState({ leftRailOpen: false, rightRailOpen: false }); closeIpadAssistant() }
    else if (right && !materialsAvailable) useUiStore.setState({ rightRailOpen: false })
    if (left && !previous.current.left) activateIpadAuxiliary('left')
    if (right && !previous.current.right) activateIpadAuxiliary('materials')
    previous.current = { left, right }
  }, [left, right, settings, board, graph, materialsAvailable])
  useLayoutEffect(() => {
    setNativeHostBlocked('ipad-sidebar', layout.overlay)
    return () => setNativeHostBlocked('ipad-sidebar', false)
  }, [layout.overlay])
  useRailFocus(layout.overlayOwner, close)
  const togglePin = (side: IpadSide) => {
    const surface = side === 'left' ? 'left' : 'materials'
    setIpadPanelMode(surface, layout.modes[surface] === 'auto' ? 'overlay' : 'auto')
  }
  return { ...layout, close, togglePin }
}
export function IpadRailControls({ layout, side }: { layout: ReturnType<typeof useIpadShellLayout>; side: IpadSide }): JSX.Element | null {
  const surface = side === 'left' ? 'left' : 'materials'
  if (layout.panels[surface] === 'closed' || layout.panels[surface] === 'suspended') return null
  const automatic = layout.modes[surface] === 'auto'
  return <header className="ipad-rail-controls">
    <strong>{side === 'left' ? '내 공간' : '자료'}</strong>
    {layout.width >= 700 && <button type="button" onClick={() => layout.togglePin(side)} aria-pressed={automatic} aria-label={automatic ? '패널 고정 해제' : '패널 고정'}>{automatic ? '고정 해제' : '고정'}</button>}
    <button type="button" onClick={() => layout.close(side)} aria-label={side === 'left' ? '내 공간 닫기' : '자료 닫기'}>닫기</button>
  </header>
}
export function IpadBackdrop({ close }: { close(): void }): JSX.Element {
  return <button type="button" className="ipad-panel-backdrop" aria-label="패널 닫기" onClick={close} tabIndex={-1} />
}
export function IpadShellChrome(): JSX.Element {
  const layout = useIpadPanelPolicy()
  const open = layout.panels.left === 'docked' || layout.panels.left === 'overlay'
  const settings = useUiStore(state => state.isSettingsOpen)
  if (settings) return <></>
  const setOpen = (value: boolean) => {
    if (value) {
      activateIpadAuxiliary('left')
      useUiStore.getState().closeBoardOverlay()
      useUiStore.getState().closeLinkGraph()
      const workspace = useWorkspaceStore.getState()
      if (workspace.surface === 'study-market') {
        workspace.showCourseWorkspace(workspace.activeCourseId)
        useUiStore.setState({ leftRailPanel: 'courses' })
      }
    }
    useUiStore.setState({ leftRailOpen: value, courseRailOpen: true })
  }
  return <><IpadSidebarSwipe open={open} boundary={open ? (layout.width < 700 ? layout.width : 336) : 56}
    disabled={layout.overlayOwner !== null && layout.overlayOwner !== 'left'} onOpen={() => setOpen(true)} onClose={() => setOpen(false)} />
  <header className="shell-chrome ipad-shell-chrome"><button type="button" aria-label={open ? '내 공간 닫기' : '내 공간 열기'} aria-expanded={open}
    onClick={event => { event.currentTarget.focus({ preventScroll: true }); setOpen(!open) }}><svg aria-hidden="true" width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><rect x="3" y="4" width="18" height="16" rx="3" /><path d="M9 4v16" /></svg></button></header></>
}
export function IpadAssistantAction({ activate, panelId }: { activate(): void; panelId?: string | undefined }): JSX.Element {
  const open = useActiveAssistantOpen()
  const layout = useIpadPanelPolicy()
  const visible = open && (layout.panels.assistant === 'docked' || layout.panels.assistant === 'overlay')
  return <button type="button" className="ipad-assistant-action" data-ipad-assistant-trigger={panelId} aria-label="현재 문서 AI 열기" aria-pressed={visible}
    onClick={event => { event.currentTarget.focus({ preventScroll: true }); activate(); void openActiveAssistant() }}><span aria-hidden="true">✦</span><span className="ipad-assistant-action__label">AI</span></button>
}
export function useIpadAssistant({ panelId, active, open, width, close, root }: {
  panelId: string; active: boolean; open: boolean; width: number; availableWidth: number; close(): void; root: RefObject<HTMLElement>
}) {
  const layout = useIpadPanelPolicy(active && open ? width : undefined)
  const pinned = layout.modes.assistant === 'auto'
  const canPin = layout.width >= 700
  const visible = active && open && layout.panels.assistant !== 'suspended' && layout.panels.assistant !== 'closed'
  const overlay = layout.panels.assistant !== 'docked'
  const wasOpen = useRef(false)
  useLayoutEffect(() => {
    if (active && open && !wasOpen.current) {
      useUiStore.setState({ rightRailOpen: false })
      activateIpadAuxiliary('assistant')
    }
    wasOpen.current = active && open
  }, [active, open])
  useLayoutEffect(() => {
    if (!active || !open) return
    return registerIpadAssistant({ panelId, width, close })
  }, [panelId, active, open, width, close])
  const current = useRef({ active, open }); current.current = { active, open }
  const returnFocus = useRef<HTMLElement | null>(null)
  useLayoutEffect(() => {
    if (!visible || !overlay) return
    const dialog = root.current?.querySelector<HTMLElement>('.tab-assistant')
    if (!dialog) return
    const focused = document.activeElement
    const opener = [...document.querySelectorAll<HTMLElement>('[data-ipad-assistant-trigger]')].find(element => element.dataset.ipadAssistantTrigger === panelId)
    if (opener) returnFocus.current = opener
    else if (!returnFocus.current?.isConnected && focused instanceof HTMLElement && focused !== document.body && !dialog.contains(focused)) returnFocus.current = focused
    const controls = () => [...dialog.querySelectorAll<HTMLElement>('button, input, select, textarea, a[href], [tabindex]')]
      .filter(element => element.tabIndex >= 0 && !element.matches(':disabled') && !element.closest('[inert], [hidden]') && element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden')
    let initial = requestAnimationFrame(() => {
      if (!dialog.contains(document.activeElement)) (dialog.querySelector<HTMLElement>('.chat-composer__input') ?? controls()[0])?.focus({ preventScroll: true })
    })
    const key = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return
      if (event.key === 'Escape') { event.preventDefault(); close(); return }
      if (event.key !== 'Tab') return
      const targets = controls()
      if (!targets.length) return
      event.preventDefault()
      const index = targets.indexOf(document.activeElement as HTMLElement)
      const next = index < 0 ? (event.shiftKey ? targets.length - 1 : 0) : (index + (event.shiftKey ? -1 : 1) + targets.length) % targets.length
      targets[next]?.focus({ preventScroll: true })
    }
    // Bubble after nested menus so their own Escape handling takes priority.
    window.addEventListener('keydown', key)
    return () => {
      cancelAnimationFrame(initial); window.removeEventListener('keydown', key)
      if (current.current.active && !current.current.open) requestAnimationFrame(() => {
        const target = returnFocus.current
        if (target?.isConnected && !target.closest('[inert], [hidden]') && target.getClientRects().length && getComputedStyle(target).visibility !== 'hidden') target.focus({ preventScroll: true })
      })
    }
  }, [panelId, active, open, visible, overlay, close, root])
  useLayoutEffect(() => { if (open && !active) close() }, [active, open, close])
  useLayoutEffect(() => {
    setNativeHostBlocked(`ipad-assistant:${panelId}`, visible && overlay)
    return () => setNativeHostBlocked(`ipad-assistant:${panelId}`, false)
  }, [panelId, visible, overlay])
  const togglePin = () => setIpadPanelMode('assistant', pinned ? 'overlay' : 'auto')
  return { overlay, canPin, visible, pinned: pinned && !overlay, automatic: pinned, togglePin }
}
export function useIpadSettingsNavigation(initialCategory: string | null) {
  const width = useIpadWidth()
  const [detail, setDetail] = useState(initialCategory !== null)
  useEffect(() => { if (initialCategory !== null) setDetail(true) }, [initialCategory])
  const focusNarrowView = (selector: string) => {
    if (width < 760) requestAnimationFrame(() => document.querySelector<HTMLElement>(`.ipad-settings ${selector}`)?.focus())
  }
  return { narrow: width < 760, detail,
    showCategory: () => { setDetail(true); focusNarrowView('.settings-content') },
    showList: () => { setDetail(false); focusNarrowView('.settings-nav__item[aria-current="page"]') } }
}
const settingsOwnedEvents = new WeakSet<Event>()
export function isIpadSettingsForeground(event?: Event): boolean {
  return useUiStore.getState().isSettingsOpen || !!event && settingsOwnedEvents.has(event)
}
/** Settings temporarily owns focus without unmounting background editors. */
export function useIpadSettingsModal(active: boolean, close?: (() => void) | undefined) {
  const root = useRef<HTMLDivElement>(null)
  const previousFocus = useRef<HTMLElement | null>(null)
  useLayoutEffect(() => {
    if (active) previousFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
  }, [active])
  useFocusTrap(root, { active, onEscape: close, returnFocus: false })
  useEffect(() => {
    if (!active) return
    // Board editors/menus are portals. Include them as well as their surfaces,
    // leaving their local draft and the original save/cancel paths intact.
    const suspended = new Map<HTMLElement, string | null>()
    const suspend = () => {
      for (const element of document.querySelectorAll<HTMLElement>('.board-overlay, .board-editor, .board-context-menu, .link-graph-overlay')) {
        if (suspended.has(element)) continue
        suspended.set(element, element.getAttribute('inert'))
        element.setAttribute('inert', '')
      }
    }
    suspend()
    const observer = new MutationObserver(suspend)
    observer.observe(document.body, { childList: true, subtree: true })
    // WebKit's platform Tab policy can skip buttons, including the boundary
    // button of a trap. Cycle explicitly after nested dialogs get first refusal.
    const cycle = (event: KeyboardEvent) => {
      const container = root.current
      if (event.key !== 'Tab' || event.defaultPrevented || !container) return
      const focused = document.activeElement
      const nested = focused?.closest('[role="dialog"], [role="alertdialog"]')
      if (nested && nested !== container.closest('[role="dialog"], [role="alertdialog"]')) return
      const targets = focusableElements(container)
      if (!targets.length) return
      event.preventDefault()
      const index = targets.indexOf(focused as HTMLElement)
      const next = index < 0 ? (event.shiftKey ? targets.length - 1 : 0) : (index + (event.shiftKey ? -1 : 1) + targets.length) % targets.length
      targets[next]?.focus({ preventScroll: true })
    }
    // Closing can synchronously clear the store before this same Escape reaches
    // background window handlers. Ownership lasts for the whole event dispatch.
    const own = (event: KeyboardEvent) => { settingsOwnedEvents.add(event) }
    window.addEventListener('keydown', own, true)
    window.addEventListener('keydown', cycle)
    return () => {
      observer.disconnect()
      window.removeEventListener('keydown', own, true)
      window.removeEventListener('keydown', cycle)
      for (const [element, inert] of suspended) {
        if (inert === null) element.removeAttribute('inert')
        else element.setAttribute('inert', inert)
      }
      requestAnimationFrame(() => {
        if (isIpadSettingsForeground()) return
        const visible = (element: HTMLElement | null): element is HTMLElement => !!element?.isConnected && element !== document.body && element !== document.documentElement && !element.closest('[inert], [hidden], [aria-hidden="true"]') && element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden'
        const target = previousFocus.current
        if (visible(target)) target.focus({ preventScroll: true })
        else document.querySelector<HTMLElement>('.ipad-shell-chrome button')?.focus({ preventScroll: true })
      })
    }
  }, [active])
  return root
}
export function IpadSettingsHeader({ navigation, title, close }: { navigation: ReturnType<typeof useIpadSettingsNavigation>; title: string; close?: (() => void) | undefined }): JSX.Element {
  const t = useT()
  return <header className="ipad-settings-header">
    {navigation.narrow && navigation.detail ? <button type="button" onClick={navigation.showList} aria-label="설정 목록으로">‹ 목록</button> : <span />}
    <strong>{navigation.narrow && navigation.detail ? title : t('settings.window.title')}</strong>
    <button type="button" className="back-button ipad-settings-return" onClick={close ?? (() => window.close())}>
      <SettingsIcon name="arrow-left" size={17} /><span>{t('settings.back')}</span>
    </button>
  </header>
}
/** The original row continues to own opening, selection, drag and its menu. */
export function IpadRowActions({ children, label }: { children: ReactNode; label: string }): JSX.Element {
  const root = useRef<HTMLDivElement>(null)
  return <div className="ipad-row-actions" ref={root}>{children}<button className="ipad-row-more" type="button" aria-label={`${label} 더 보기`} onClick={event => {
    event.stopPropagation()
    const row = root.current?.querySelector<HTMLElement>('[data-material-row], .material-row, .material-result')
    const rect = event.currentTarget.getBoundingClientRect()
    row?.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: rect.left, clientY: rect.bottom }))
  }}>•••</button></div>
}
/** Dockview maximization retains the split tree and live panel identities. */
export function bindIpadWorkspace(api: DockviewApi, root: HTMLElement | null): () => void {
  if (!root) return () => {}
  let frame = 0, owned = false, disposed = false
  let retained: ReturnType<DockviewApi['toJSON']> | null = null
  const originalSerialize = api.toJSON
  // Responsive presentation must never become a saved user maximization.
  api.toJSON = () => {
    const layout = originalSerialize.call(api)
    if (owned) {
      delete (layout.grid as typeof layout.grid & { maximizedNode?: unknown }).maximizedNode
      if (retained && !retainSplitProportions(layout, retained)) retained = structuredClone(layout)
    }
    return layout
  }
  const compactNow = () => {
    if (retained && splitGroupFractions(retained).map(group => group.id).sort().join('|') !== api.groups.map(group => group.id).sort().join('|')) api.toJSON()
    const current = ipadPanelState().assistant
    const group = current ? api.getPanel(current.panelId)?.group.id : undefined
    const docked = current && root.querySelector(`[data-tour-panel="${CSS.escape(current.panelId)}"][data-assistant-open="true"][data-assistant-overlay="false"]`)
    const extras = group && docked ? { [group]: current!.width } : {}
    return root.getBoundingClientRect().width < minimumSplitWidth(retained ?? api.toJSON(), extras) && api.groups.length > 1
  }
  const update = () => {
    frame = 0
    if (disposed || root.hidden || !root.getBoundingClientRect().width) return
    const compact = compactNow()
    root.dataset.ipadCompactPanes = String(compact)
    if (compact && api.activePanel && (!api.hasMaximizedGroup() || owned)) {
      if (!api.hasMaximizedGroup()) { retained ??= originalSerialize.call(api); owned = true; api.maximizeGroup(api.activePanel) }
    } else if (!compact && owned) {
      const bounds = root.getBoundingClientRect()
      // ResizeObserver ordering can otherwise restore against the old width.
      api.layout(bounds.width, bounds.height)
      api.exitMaximizedGroup()
      // Resize the existing groups in place: never deserialize/remount editors.
      for (const group of retained ? splitGroupFractions(retained) : []) {
        api.groups.find(value => value.id === group.id)?.api.setSize({ width: bounds.width * group.width, height: bounds.height * group.height })
      }
      retained = null; owned = false
    }
  }
  const schedule = () => { if (!frame) frame = requestAnimationFrame(update) }
  const observer = new ResizeObserver(schedule); observer.observe(root)
  const active = api.onDidActivePanelChange(panel => {
    if (owned && panel && compactNow()) api.maximizeGroup(panel)
    schedule()
  })
  const changed = api.onDidLayoutChange(schedule)
  const stopPanels = subscribeIpadPanels(schedule)
  schedule()
  return () => { disposed = true; observer.disconnect(); active.dispose(); changed.dispose(); stopPanels(); cancelAnimationFrame(frame); api.toJSON = originalSerialize }
}
