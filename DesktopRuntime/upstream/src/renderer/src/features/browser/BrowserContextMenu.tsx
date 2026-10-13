import { useViewportBounds } from '../../lib/useViewportBounds'
/**
 * Right-click inside a guest page.
 *
 * An Electron guest has no default context menu at all, so before this
 * right-clicking a lecture page did literally nothing.
 *
 * Two things make this trickier than an ordinary menu:
 *  - `event.params.x/y` are GUEST-viewport relative; the menu is host DOM, so
 *    they have to be offset by the webview element's rect (the same correction
 *    `selectionBridge` applies to selection rectangles).
 *  - a guest swallows the pointer stream, so without a passthrough token the
 *    click-outside that should dismiss the menu never reaches us. The release
 *    is unconditional in the effect cleanup — `BrowserWebviewLayer` already
 *    carries scars from a token that stayed held and left guests unclickable.
 */

import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { invoke } from '../../lib/ipc'
import { showToast } from '../../app/toast'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useBrowserGuests } from './browserGuestsStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { guestActions } from './guestActions'
import { openDiagnostics } from './diagnosticsBridge'
import { usePrintStore } from '../print/printStore'
import { resolveAddressInput } from './urlInput'
import { v4 as uuidv4 } from 'uuid'
import { openWebVideoInPip } from './videoBridge'
import { requestLearningArticleImport } from '../learning/LearningDialogsHost'

export interface BrowserContextMenuState {
  /** Host-viewport coordinates, already offset. */
  x: number
  y: number
  linkURL: string
  srcURL: string
  mediaType: string
  selectionText: string
  /** A text field or contenteditable was under the cursor. */
  isEditable: boolean
  pageURL: string
  /** Guest-relative coordinates, for `copyImageAt`. */
  guestX: number
  guestY: number
  /** Page title, for the clip's source line. */
  pageTitle: string
  /** Reporter saw a page video, even if the pointer is elsewhere. */
  hasPlayingVideo: boolean
  /** Course a clip would be filed under; null = no course selected. */
  courseId: string | null
}

export type ContextMenuItemId =
  | 'open-link'
  | 'copy-link'
  | 'save-link'
  | 'copy-image'
  | 'save-image'
  | 'pip-video'
  | 'copy-selection'
  | 'cut-selection'
  | 'paste'
  | 'select-all'
  | 'search-selection'
  | 'clip-to-note'
  | 'add-to-learning'
  | 'reload'
  | 'copy-page-url'
  | 'open-external'
  | 'print'
  | 'diagnose'
  | 'inspect'

/**
 * Which entries a click offers, given what was under the cursor. Pure so the
 * branching is testable: Playwright cannot deliver a real right-click into a
 * guest WebContents, so this is the only place the logic can be pinned down.
 */
export function contextMenuItems(
  state: Pick<
    BrowserContextMenuState,
    'linkURL' | 'srcURL' | 'mediaType' | 'selectionText' | 'isEditable'
  > & { courseId: string | null; hasPlayingVideo?: boolean }
): ContextMenuItemId[] {
  const items: ContextMenuItemId[] = []
  if (state.linkURL !== '') {
    items.push('open-link', 'copy-link', 'save-link')
  }
  if (state.mediaType === 'image' && state.srcURL !== '') {
    items.push('copy-image', 'save-image')
  }
  if (state.mediaType === 'video' || state.hasPlayingVideo === true) {
    items.push('pip-video')
  }
  // Korean students paste 학번 into portal fields constantly, and this menu
  // used to offer them 새로고침 · 페이지 주소 복사 · 검사 — nothing usable.
  if (state.isEditable) {
    if (state.selectionText.trim() !== '') items.push('cut-selection', 'copy-selection')
    items.push('paste', 'select-all')
    if (state.selectionText.trim() !== '') items.push('search-selection')
    items.push('reload', 'copy-page-url', 'print', 'open-external', 'diagnose', 'inspect')
    return items
  }
  if (state.selectionText.trim() !== '') {
    items.push('copy-selection', 'search-selection')
    // Only offered with a course to file it under; a clip has nowhere to go
    // otherwise, and a disabled row would just be noise.
    if (state.courseId !== null) items.push('clip-to-note')
  }
  if (state.courseId) items.push('add-to-learning')
  // Always available, so a right-click anywhere does something useful.
  // 검사 is here rather than behind a dev flag because a broken Korean portal
  // is only diagnosable from a real login on a real machine — which is a
  // release build, by definition.
  items.push(
    'reload',
    'copy-page-url',
    'print',
    'open-external',
    'diagnose',
    'inspect'
  )
  return items
}

interface MenuItem {
  label: string
  run: () => void
}

export function BrowserContextMenu({
  tabId,
  state,
  onClose
}: {
  tabId: string
  state: BrowserContextMenuState
  onClose: () => void
}): JSX.Element {
  const menuRef = useRef<HTMLDivElement>(null)
  useViewportBounds(menuRef)

  useEffect(() => {
    const dismiss = (): void => onClose()
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose()
    }
    // `capture` so a click anywhere closes it before anything else reacts.
    window.addEventListener('pointerdown', dismiss, true)
    window.addEventListener('keydown', onKeyDown)
    window.addEventListener('blur', dismiss)
    return () => {
      window.removeEventListener('pointerdown', dismiss, true)
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('blur', dismiss)
    }
  }, [onClose])

  useEffect(() => {
    menuRef.current?.focus()
  }, [])

  const openTab = (url: string): void => {
    const isPrivate = useBrowserGuests.getState().liveGuests.some(
      (guest) => guest.tabId === tabId && guest.isPrivate
    )
    useWorkspaceStore
      .getState()
      .openTab(descriptorFor('browser', {
        tabId: uuidv4(),
        initialUrl: url,
        ...(isPrivate ? { isPrivate: true } : {})
      }))
  }

  const trimmed = state.selectionText.trim().slice(0, 40)
  const actions: Record<ContextMenuItemId, MenuItem> = {
    'open-link': {
      label: '링크를 새 탭에서 열기',
      run: () => openTab(state.linkURL)
    },
    'copy-link': {
      label: '링크 주소 복사',
      run: () => void navigator.clipboard.writeText(state.linkURL)
    },
    'save-link': {
      label: '링크를 자료로 저장',
      run: () => guestActions.download(tabId, state.linkURL)
    },
    'copy-image': {
      label: '이미지 복사',
      run: () => guestActions.copyImageAt(tabId, state.guestX, state.guestY)
    },
    'save-image': {
      label: '이미지를 자료로 저장',
      run: () => guestActions.download(tabId, state.srcURL)
    },
    'pip-video': {
      label: '영상을 작은 창으로',
      run: () => {
        void openWebVideoInPip(tabId, {
          url: state.pageURL,
          title: state.pageTitle
        }).catch(() => {
          showToast('작은 창을 열지 못했어요.', 'danger')
        })
      }
    },
    'copy-selection': {
      label: '복사',
      run: () => guestActions.copySelection(tabId)
    },
    'cut-selection': {
      label: '잘라내기',
      run: () => guestActions.cut(tabId)
    },
    paste: {
      label: '붙여넣기',
      run: () => guestActions.paste(tabId)
    },
    'select-all': {
      label: '전체 선택',
      run: () => guestActions.selectAll(tabId)
    },
    'clip-to-note': {
      label: '필기에 담기',
      run: () => {
        if (state.courseId === null) return
        void invoke('link:sendWebClipToNote', {
          courseId: state.courseId,
          url: state.pageURL,
          title: state.pageTitle,
          quote: state.selectionText,
          comment: null
        })
          .then((result) => {
            showToast(`«${result.relPath}»에 담았어요.`)
          })
          .catch(() => {
            showToast('필기에 담지 못했어요.', 'danger')
          })
      }
    },
    'add-to-learning': {
      label: '이 글을 학습에 추가',
      run: () => { if (state.courseId) requestLearningArticleImport({ courseId: state.courseId, url: state.pageURL, tabId }) }
    },
    'search-selection': {
      label: `\u201c${trimmed}\u201d 검색`,
      run: () => {
        const url = resolveAddressInput(state.selectionText.trim())
        if (url !== null) openTab(url)
      }
    },
    reload: { label: '새로고침', run: () => guestActions.reload(tabId) },
    'copy-page-url': {
      label: '페이지 주소 복사',
      run: () => void navigator.clipboard.writeText(state.pageURL)
    },
    'open-external': {
      label: '기본 브라우저에서 열기',
      run: () => void invoke('shell:openExternal', { url: state.pageURL })
    },
    print: {
      label: '인쇄…',
      run: () => usePrintStore.getState().open(
        { kind: 'browser', tabId },
        state.pageTitle
      )
    },
    diagnose: {
      label: '이 페이지 진단',
      run: () => openDiagnostics(tabId)
    },
    inspect: {
      label: '검사',
      run: () => guestActions.openDevTools(tabId)
    }
  }
  const items = contextMenuItems(state).map((id) => ({ id, ...actions[id] }))

  return createPortal(
    <div
      ref={menuRef}
      className="browser-context-menu"
      role="menu"
      tabIndex={-1}
      style={{ left: `${state.x}px`, top: `${state.y}px` }}
      onPointerDown={(event) => event.stopPropagation()}
    >
      {items.map((item) => (
        <button
          key={item.id}
          type="button"
          role="menuitem"
          className="browser-context-menu__item"
          onClick={() => {
            item.run()
            onClose()
          }}
        >
          {item.label}
        </button>
      ))}
    </div>,
    document.body
  )
}
