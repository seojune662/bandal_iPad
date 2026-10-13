/** Global keyboard shortcuts resolved from the shared, customizable keymap. */

import { useEffect } from 'react'
import { create } from 'zustand'
import {
  chordFromKeyboardEvent,
  resolveKeymap,
  SHORTCUT_SPECS,
  type ShortcutActionId
} from '../../../shared/keymap'
import { onPush } from '../lib/ipc'
import { openNewTabMenu } from '../features/workspace/newTabMenuController'
import { createBrowserTab, createMarkdownTab, createStudyTab } from './tabCommands'
import { showToast } from './toast'
import { tabIdForWebContents } from '../features/browser/guestActions'
import { viewerKindFor } from '../features/file/fileFormats'
import { tabPanelId } from '../features/workspace/tabIdentity'
import type { ShortcutPassthrough } from '../../../shared/ipc/events'
import { guestActions } from '../features/browser/guestActions'
import { useBrowserGuests } from '../features/browser/browserGuestsStore'
import { toggleFavorite } from '../features/browser/browserFavorite'
import { DEFAULT_ZOOM_LEVEL, zoomIn, zoomOut } from '../features/browser/zoom'
import { mediaUrlFor } from '../features/materials/mediaUrl'
import {
  ensureSettingsLoaded,
  settingsSnapshot
} from '../stores/settingsSnapshot'
import { useUiStore } from '../stores/uiStore'
import { useWorkspaceStore } from '../stores/workspaceStore'
import { chordMap as pluginChordMap, usePluginsStore } from '../stores/pluginsStore'
import { runPluginCommand } from '../features/plugins/pluginCommands'

// -- pure resolver ------------------------------------------------------------

export type ShortcutAction =
  | { type: 'new-tab' }
  | { type: 'new-markdown' }
  | { type: 'new-browser-tab' }
  | { type: 'new-ai-tab' | 'new-recording-tab' | 'new-whiteboard' | 'open-study-board' }
  | { type: 'close-tab' }
  | { type: 'quick-search' }
  | { type: 'settings' }
  | { type: 'activate-tab'; index: number }
  | { type: 'activate-last-tab' }
  | { type: 'browser-back' }
  | { type: 'browser-forward' }
  // Browser-only. No-ops unless a browser tab is focused (or the chord came
  // out of a guest page, which names its own tab).
  | { type: 'browser-reload'; ignoreCache: boolean }
  | { type: 'browser-focus-address' }
  | { type: 'browser-find' }
  | { type: 'browser-bookmark' }
  | { type: 'reopen-tab' }
  | { type: 'cycle-tab'; delta: number }
  | { type: 'browser-zoom'; direction: 'in' | 'out' | 'reset' }
  | { type: 'toggle-left-rail' }
  | { type: 'toggle-right-rail' }
  | { type: 'toggle-board' }
  | { type: 'add-course' }
  | { type: 'import-materials' }
  | { type: 'open-pip' }
  | { type: 'shortcut-help' }
  | { type: 'send-feedback' }
  | { type: 'plugin-command'; pluginId: string; commandId: string }

export interface ShortcutInput {
  key: string
  code?: string | undefined
  metaKey: boolean
  ctrlKey: boolean
  altKey: boolean
  shiftKey: boolean
  /** True while an IME composition is in flight (or keyCode === 229). */
  isComposing: boolean
  /** True when the event target / focus is a <webview> guest element. */
  targetIsWebview: boolean
}

const GUEST_ALLOWED: ReadonlySet<ShortcutActionId> = new Set(
  SHORTCUT_SPECS.filter((spec) => spec.guestAllowed).map((spec) => spec.id)
)

let currentKeymap = resolveKeymap(settingsSnapshot().keybindings)

function actionForId(id: ShortcutActionId): ShortcutAction | null {
  if (id.startsWith('activate-tab-')) {
    return { type: 'activate-tab', index: Number(id.slice(-1)) - 1 }
  }
  switch (id) {
    case 'new-tab':
    case 'new-markdown':
    case 'new-browser-tab':
    case 'new-ai-tab':
    case 'new-recording-tab':
    case 'new-whiteboard':
    case 'open-study-board':
    case 'close-tab':
    case 'quick-search':
    case 'settings':
    case 'activate-last-tab':
    case 'browser-back':
    case 'browser-forward':
    case 'browser-focus-address':
    case 'browser-find':
    case 'browser-bookmark':
    case 'reopen-tab':
    case 'toggle-left-rail':
    case 'toggle-right-rail':
    case 'toggle-board':
    case 'add-course':
    case 'import-materials':
    case 'open-pip':
    case 'shortcut-help':
    case 'send-feedback':
      return { type: id }
    case 'browser-reload':
      return { type: 'browser-reload', ignoreCache: false }
    case 'browser-reload-hard':
      return { type: 'browser-reload', ignoreCache: true }
    case 'cycle-tab-prev':
      return { type: 'cycle-tab', delta: -1 }
    case 'cycle-tab-next':
      return { type: 'cycle-tab', delta: 1 }
    case 'browser-zoom-in':
      return { type: 'browser-zoom', direction: 'in' }
    case 'browser-zoom-out':
      return { type: 'browser-zoom', direction: 'out' }
    case 'browser-zoom-reset':
      return { type: 'browser-zoom', direction: 'reset' }
    case 'whiteboard-select':
    case 'whiteboard-pen':
    case 'whiteboard-highlighter':
    case 'whiteboard-eraser':
    case 'whiteboard-text':
    case 'whiteboard-rectangle':
    case 'whiteboard-ellipse':
      return null
  }
  return null
}

/** Maps a keydown to a shortcut action, or null when guards reject it. */
export function resolveShortcut(
  input: ShortcutInput,
  keymap: ReadonlyMap<string, ShortcutActionId> = currentKeymap
): ShortcutAction | null {
  if (input.isComposing) return null
  const chord = chordFromKeyboardEvent(input)
  if (chord === null) return null
  const actionId = keymap.get(chord)
  if (actionId !== undefined) {
    if (input.targetIsWebview && !GUEST_ALLOWED.has(actionId)) return null
    return actionForId(actionId)
  }
  // The shared keymap intentionally knows only built-in actions today.
  // Extension chords are a renderer-owned second tier, so built-ins always
  // win a collision and plugin commands never run from an embedded guest.
  if (input.targetIsWebview) return null
  const pluginCommand = pluginChordMap(usePluginsStore.getState()).get(chord)
  return pluginCommand === undefined
    ? null
    : {
        type: 'plugin-command',
        pluginId: pluginCommand.pluginId,
        commandId: pluginCommand.command.id
      }
}

// -- quick-search open/close state (⌘P overlay) -------------------------------

interface QuickSearchState {
  isOpen: boolean
  open: () => void
  close: () => void
  toggle: () => void
}

export const useQuickSearch = create<QuickSearchState>()((set) => ({
  isOpen: false,
  open: () => set({ isOpen: true }),
  close: () => set({ isOpen: false }),
  toggle: () => set((state) => ({ isOpen: !state.isOpen }))
}))

// -- dispatch + registration --------------------------------------------------

/**
 * `originTabId` is set only for chords replayed out of a guest page. A guest
 * lives in a fixed layer outside the dockview panel DOM and focusing it does
 * NOT make its panel active, so 'close-tab' has to name the tab explicitly —
 * otherwise ⌘W in a split closes whichever panel dockview thinks is active.
 */
export const ADD_COURSE_SHORTCUT_EVENT = 'bandal:open-add-course'
export const IMPORT_MATERIALS_SHORTCUT_EVENT = 'bandal:import-materials'
export const SHORTCUT_HELP_EVENT = 'bandal:open-shortcut-help'
export const FEEDBACK_EVENT = 'bandal:open-feedback'

function openActiveVideoPip(): void {
  const descriptor = useWorkspaceStore.getState().activeTabDescriptor()
  if (
    descriptor?.kind !== 'file' ||
    viewerKindFor(descriptor.payload.relPath) !== 'video'
  ) {
    return
  }

  const source = mediaUrlFor(
    descriptor.payload.courseId,
    descriptor.payload.relPath
  )
  const video = [...document.querySelectorAll<HTMLVideoElement>(
    '.file-video__media'
  )].find((candidate) => candidate.getAttribute('src') === source)
  video
    ?.closest('.file-video')
    ?.querySelector<HTMLButtonElement>('.file-video__pip:not(:disabled)')
    ?.click()
}

export function runShortcutAction(
  action: ShortcutAction,
  originTabId?: string
): void {
  switch (action.type) {
    case 'new-tab':
      openNewTabMenu()
      return
    case 'new-markdown':
      void createMarkdownTab()
      return
    case 'new-browser-tab':
      createBrowserTab()
      return
    case 'new-ai-tab':
    case 'new-recording-tab':
    case 'new-whiteboard':
    case 'open-study-board':
      void createStudyTab({
        'new-ai-tab': 'chat', 'new-recording-tab': 'recording',
        'new-whiteboard': 'whiteboard', 'open-study-board': 'board'
      }[action.type] as 'chat' | 'recording' | 'whiteboard' | 'board').catch(() => showToast('탭을 열지 못했습니다.', 'danger'))
      return
    case 'close-tab':
      if (originTabId !== undefined) {
        useWorkspaceStore
          .getState()
          .closeTab(
            tabPanelId({
              kind: 'browser',
              payload: { tabId: originTabId, initialUrl: '' }
            })
          )
        return
      }
      useWorkspaceStore.getState().closeActiveTab()
      return
    case 'quick-search':
      useQuickSearch.getState().toggle()
      return
    case 'settings':
      useUiStore.getState().openSettings()
      return
    case 'activate-tab':
      useWorkspaceStore.getState().activateTabAt(action.index)
      return
    case 'activate-last-tab':
      useWorkspaceStore.getState().activateLastTab()
      return
    case 'browser-back': {
      const target = browserTarget(originTabId)
      if (target === null) return
      guestActions.back(target)
      return
    }
    case 'browser-forward': {
      const target = browserTarget(originTabId)
      if (target === null) return
      guestActions.forward(target)
      return
    }
    case 'browser-reload': {
      const target = browserTarget(originTabId)
      if (target === null) return
      if (action.ignoreCache) guestActions.reloadIgnoringCache(target)
      else guestActions.reload(target)
      return
    }
    case 'browser-focus-address': {
      const target = browserTarget(originTabId)
      if (target === null) return
      useBrowserGuests.getState().requestAddressFocus(target)
      return
    }
    case 'reopen-tab':
      useWorkspaceStore.getState().reopenClosedTab()
      return
    case 'cycle-tab':
      useWorkspaceStore.getState().activateRelativeTab(action.delta)
      return
    case 'browser-find': {
      const target = browserTarget(originTabId)
      if (target === null) return
      useBrowserGuests.getState().openFind(target)
      return
    }
    case 'browser-bookmark': {
      const target = browserTarget(originTabId)
      if (target === null) return
      const nav = useBrowserGuests.getState().nav[target]
      if (nav === undefined) return
      toggleFavorite(target, nav)
      return
    }
    case 'browser-zoom': {
      const target = browserTarget(originTabId)
      if (target === null) return
      const store = useBrowserGuests.getState()
      const current = store.zoom[target] ?? DEFAULT_ZOOM_LEVEL
      const next =
        action.direction === 'reset'
          ? DEFAULT_ZOOM_LEVEL
          : action.direction === 'in'
            ? zoomIn(current)
            : zoomOut(current)
      store.setZoom(target, next)
      guestActions.setZoom(target, next)
      return
    }
    case 'toggle-left-rail':
      useUiStore.getState().toggleLeftRail()
      return
    case 'toggle-right-rail':
      useUiStore.getState().toggleRightRail()
      return
    case 'toggle-board':
      useUiStore.getState().toggleBoardOverlay()
      return
    case 'add-course':
      window.dispatchEvent(new CustomEvent(ADD_COURSE_SHORTCUT_EVENT))
      return
    case 'import-materials':
      window.dispatchEvent(new CustomEvent(IMPORT_MATERIALS_SHORTCUT_EVENT))
      return
    case 'open-pip':
      openActiveVideoPip()
      return
    case 'shortcut-help':
      useUiStore.getState().openSettings('shortcuts')
      return
    case 'send-feedback':
      window.dispatchEvent(new CustomEvent(FEEDBACK_EVENT))
      return
    case 'plugin-command':
      void runPluginCommand(action.pluginId, action.commandId).catch(
        () => undefined
      )
      return
  }
}

/** Main names the chord; the renderer owns what it means. */
function passthroughAction(
  action: ShortcutPassthrough['action']
): ShortcutAction | null {
  switch (action) {
    case 'new-markdown':
    case 'new-browser-tab':
    case 'new-ai-tab':
    case 'new-recording-tab':
    case 'new-whiteboard':
    case 'open-study-board':
    case 'toggle-left-rail':
      return { type: action }
    case 'new-tab':
      return { type: 'new-tab' }
    case 'close-tab':
      return { type: 'close-tab' }
    case 'activate-last-tab':
      return { type: 'activate-last-tab' }
    case 'activate-tab-1':
    case 'activate-tab-2':
    case 'activate-tab-3':
    case 'activate-tab-4':
    case 'activate-tab-5':
    case 'activate-tab-6':
    case 'activate-tab-7':
    case 'activate-tab-8':
      return { type: 'activate-tab', index: Number(action.slice(-1)) - 1 }
    case 'browser-back':
      return { type: 'browser-back' }
    case 'browser-forward':
      return { type: 'browser-forward' }
    case 'reload':
      return { type: 'browser-reload', ignoreCache: false }
    case 'reload-hard':
      return { type: 'browser-reload', ignoreCache: true }
    case 'focus-address':
      return { type: 'browser-focus-address' }
    case 'find':
      return { type: 'browser-find' }
    case 'bookmark':
      return { type: 'browser-bookmark' }
    case 'reopen-tab':
      return { type: 'reopen-tab' }
    case 'prev-tab':
      return { type: 'cycle-tab', delta: -1 }
    case 'next-tab':
      return { type: 'cycle-tab', delta: 1 }
    case 'zoom-in':
      return { type: 'browser-zoom', direction: 'in' }
    case 'zoom-out':
      return { type: 'browser-zoom', direction: 'out' }
    case 'zoom-reset':
      return { type: 'browser-zoom', direction: 'reset' }
    default:
      return null
  }
}

/**
 * A chord replayed out of a guest names its own tab; one typed in the app
 * chrome applies to the focused browser tab, and does nothing over a PDF,
 * a note or the board.
 */
function browserTarget(originTabId?: string): string | null {
  return originTabId ?? useWorkspaceStore.getState().activeBrowserTabId()
}

function isWebviewTarget(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLElement && target.tagName.toLowerCase() === 'webview'
  )
}

/** Registers the window keydown listener + the guest passthrough push. */
export function useGlobalShortcuts(): void {
  useEffect(() => {
    let active = true
    const pendingFrames = new Set<number>()
    const clickButton = (selector: string): boolean => {
      const button = document.querySelector<HTMLButtonElement>(selector)
      if (button === null || button.disabled || button.closest('[inert]')) return false
      button.click()
      return true
    }
    const clickOnNextFrame = (selector: string): void => {
      const frame = window.requestAnimationFrame(() => {
        pendingFrames.delete(frame)
        clickButton(selector)
      })
      pendingFrames.add(frame)
    }
    const onAddCourse = (): void => {
      const selector = '[aria-label="과목 추가"][aria-haspopup="menu"]'
      if (clickButton(selector)) return
      const ui = useUiStore.getState()
      ui.showCourses()
      clickOnNextFrame(selector)
    }
    const onImportMaterials = (): void => {
      if (useWorkspaceStore.getState().activeCourseId === null) return
      const selector = 'button[data-tour="materials-import"]'
      if (clickButton(selector)) return
      const ui = useUiStore.getState()
      if (!ui.rightRailOpen) ui.toggleRightRail()
      clickOnNextFrame(selector)
    }
    window.addEventListener(ADD_COURSE_SHORTCUT_EVENT, onAddCourse)
    window.addEventListener(IMPORT_MATERIALS_SHORTCUT_EVENT, onImportMaterials)

    void ensureSettingsLoaded()
      .then((settings) => {
        if (active) currentKeymap = resolveKeymap(settings.keybindings)
      })
      .catch((error: unknown) => {
        console.error('[Bandal] 단축키 설정을 불러오지 못했습니다.', error)
      })

    const unsubscribeSettings = onPush(
      'settings:changed',
      ({ settings }) => {
        currentKeymap = resolveKeymap(settings.keybindings)
      }
    )

    const onKeyDown = (event: KeyboardEvent): void => {
      // Editors and dialogs get the first chance to handle their own chords.
      if (event.defaultPrevented) return
      const action = resolveShortcut({
        key: event.key,
        code: event.code,
        metaKey: event.metaKey,
        ctrlKey: event.ctrlKey,
        altKey: event.altKey,
        shiftKey: event.shiftKey,
        isComposing: event.isComposing || event.keyCode === 229,
        targetIsWebview:
          isWebviewTarget(event.target) ||
          isWebviewTarget(document.activeElement)
      })
      if (action === null) return
      event.preventDefault()
      runShortcutAction(action)
    }
    window.addEventListener('keydown', onKeyDown)

    // ⌘T/⌘W typed INSIDE a browser guest arrive via main's
    // before-input-event interception (the guest never sees the chord).
    const unsubscribe = onPush(
      'shortcut:passthrough',
      ({ action, webContentsId }) => {
        const originTabId = tabIdForWebContents(webContentsId) ?? undefined
        const resolved = passthroughAction(action)
        if (resolved !== null) runShortcutAction(resolved, originTabId)
      }
    )

    return () => {
      active = false
      for (const frame of pendingFrames) window.cancelAnimationFrame(frame)
      window.removeEventListener(ADD_COURSE_SHORTCUT_EVENT, onAddCourse)
      window.removeEventListener(
        IMPORT_MATERIALS_SHORTCUT_EVENT,
        onImportMaterials
      )
      window.removeEventListener('keydown', onKeyDown)
      unsubscribeSettings()
      unsubscribe()
    }
  }, [])
}
