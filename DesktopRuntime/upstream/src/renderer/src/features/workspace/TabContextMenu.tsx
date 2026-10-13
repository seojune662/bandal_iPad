import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { DockviewApi } from 'dockview'
import type { TabDescriptor } from '../../../../shared/tabs'
import type { Course } from '../../../../shared/types/course'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { useT } from '../../i18n'
import { openInSystemBrowser } from '../university/openService'
import { requestChatPrompt } from '../chat/chatPromptBus'
import { guestActions } from '../browser/guestActions'
import { useBrowserGuests } from '../browser/browserGuestsStore'
import { absoluteMaterialPath } from '../materials/materialPaths'
import { invoke } from '../../lib/ipc'
import { useFavoritesStore } from '../../stores/favoritesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { createDuplicatePanelId, duplicateTabDescriptor } from './tabDuplication'
import { descriptorFor, tabPanelId, tabTitle } from './tabIdentity'
import { TabKindIcon } from './workspaceIcons'

export interface TabContextMenuProps {
  descriptor: TabDescriptor
  label: string
  course: Course
  panelId: string
  rightPanelIds: readonly string[]
  containerApi: DockviewApi
  x: number
  y: number
  placement: 'top' | 'bottom'
  align: 'start' | 'end'
  returnFocus: HTMLElement | null
  onClose: () => void
}

function enabledMenuItems(menu: HTMLElement): HTMLButtonElement[] {
  return Array.from(
    menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')
  )
}

async function copyText(value: string, successMessage: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(value)
    showToast(successMessage)
  } catch (error) {
    console.error('[Bandal] 클립보드에 복사하지 못했습니다.', error)
    showToast('클립보드에 복사하지 못했어요.', 'danger')
  }
}

function currentBrowserUrl(descriptor: TabDescriptor): string | null {
  if (descriptor.kind !== 'browser') return null
  return (
    useBrowserGuests.getState().nav[descriptor.payload.tabId]?.url ??
    descriptor.payload.initialUrl
  )
}

export function TabContextMenu({
  descriptor,
  label,
  course,
  panelId,
  rightPanelIds,
  containerApi,
  x,
  y,
  placement,
  align,
  returnFocus,
  onClose
}: TabContextMenuProps): JSX.Element {
  const t = useT()
  const menuRef = useRef<HTMLDivElement>(null)
  const isFileTab = descriptor.kind === 'pdf' || descriptor.kind === 'note'
  const isBrowserTab = descriptor.kind === 'browser'
  const canOpenNewInstance =
    descriptor.kind !== 'board'
  const resourceCourse = useCoursesStore(state => isFileTab
    ? state.courses.find(entry => entry.id === descriptor.payload.courseId) : undefined)

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      menuRef.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus()
    })
    const dismissOnPointerDown = (event: PointerEvent): void => {
      if (!menuRef.current?.contains(event.target as Node)) onClose()
    }
    const dismissOnEscape = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('pointerdown', dismissOnPointerDown)
    window.addEventListener('keydown', dismissOnEscape)
    window.addEventListener('blur', onClose)
    return () => {
      window.cancelAnimationFrame(frame)
      window.removeEventListener('pointerdown', dismissOnPointerDown)
      window.removeEventListener('keydown', dismissOnEscape)
      window.removeEventListener('blur', onClose)
      if (returnFocus?.isConnected === true) returnFocus.focus()
    }
  }, [onClose, returnFocus])

  const activate = (action: () => void | Promise<void>): void => {
    onClose()
    void action()
  }

  const duplicateTab = (split = false): void => {
    const sourcePanel = containerApi.getPanel(panelId)
    if (!sourcePanel || (split && !canOpenNewInstance)) return
    const copy = duplicateTabDescriptor(descriptor, currentBrowserUrl(descriptor) ?? undefined)
    const index = sourcePanel.group.panels.findIndex(panel => panel.id === panelId)
    containerApi.addPanel({
      id: copy.kind === 'browser' ? tabPanelId(copy) : createDuplicatePanelId(copy),
      component: copy.kind,
      title: label,
      params: { descriptor: copy },
      position: split
        ? { referencePanel: sourcePanel, direction: 'right' }
        : { referencePanel: sourcePanel, index: index + 1 }
    })
  }

  const addToFavorites = async (): Promise<void> => {
    try {
      await useFavoritesStore.getState().add({
        courseId: course.id,
        label: tabTitle(descriptor),
        descriptor
      })
      showToast('즐겨찾기에 추가했어요.')
    } catch (error) {
      console.error('[Bandal] 즐겨찾기를 추가하지 못했습니다.', error)
      showToast('즐겨찾기를 추가하지 못했어요.', 'danger')
    }
  }

  const addToBoard = async (): Promise<void> => {
    try {
      await invoke('board:createTask', { courseId: course.id, title: label })
      showToast('보드에 할 일로 추가했어요.')
    } catch (error) {
      console.error('[Bandal] 보드에 할 일을 추가하지 못했습니다.', error)
      showToast('보드에 할 일을 추가하지 못했어요.', 'danger')
    }
  }

  const revealFile = async (): Promise<void> => {
    if (!isFileTab) return
    try {
      await invoke('materials:reveal', descriptor.payload)
    } catch (error) {
      console.error('[Bandal] Finder에서 자료를 열지 못했습니다.', error)
      showToast('Finder에서 자료를 열지 못했어요.', 'danger')
    }
  }

  const askTutorAboutFile = (): void => {
    if (!isFileTab) return
    const { courseId } = descriptor.payload
    const conversationId = crypto.randomUUID()
    requestChatPrompt(
      conversationId,
      `"${tabTitle(descriptor)}" 자료에 대해 질문하고 싶어: `
    )
    useWorkspaceStore
      .getState()
      .openTab(descriptorFor('chat', { courseId, conversationId }))
  }

  const handleKeyDown = (event: React.KeyboardEvent<HTMLDivElement>): void => {
    const menu = menuRef.current
    if (menu === null) return
    const items = enabledMenuItems(menu)
    if (items.length === 0) return
    const current = items.indexOf(document.activeElement as HTMLButtonElement)
    let next: number | null = null

    if (event.key === 'ArrowDown') next = current < 0 ? 0 : (current + 1) % items.length
    if (event.key === 'ArrowUp') {
      next = current < 0 ? items.length - 1 : (current - 1 + items.length) % items.length
    }
    if (event.key === 'Home') next = 0
    if (event.key === 'End') next = items.length - 1
    if (event.key === 'Tab') {
      next = event.shiftKey
        ? current <= 0 ? items.length - 1 : current - 1
        : current >= items.length - 1 ? 0 : current + 1
    }
    if (next === null) return
    event.preventDefault()
    items[next]?.focus()
  }

  const menu = (
    <div
      ref={menuRef}
      className="context-menu workspace-tab-context-menu"
      role="menu"
      aria-label={`${label} 탭 메뉴`}
      data-placement={placement}
      data-align={align}
      style={{
        left: x,
        top: y,
        maxHeight:
          placement === 'top'
            ? `calc(${y}px - var(--space-2))`
            : `calc(100vh - ${y}px - var(--space-2))`
      }}
      onKeyDown={handleKeyDown}
    >
      <button
        type="button"
        role="menuitem"
        onClick={() => activate(() => useWorkspaceStore.getState().closeTab(panelId))}
      >
        <Icon name="x" />닫기
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => activate(() => useWorkspaceStore.getState().closeOthers(panelId))}
      >
        <Icon name="x" />이 그룹의 다른 탭 닫기
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => activate(() => useWorkspaceStore.getState().closeOthers(panelId, 'workspace'))}
      >
        <Icon name="x" />전체 작업 공간의 다른 탭 닫기
      </button>
      <button
        type="button"
        role="menuitem"
        disabled={rightPanelIds.length === 0}
        onClick={() =>
          activate(() => useWorkspaceStore.getState().closeTabs(rightPanelIds))
        }
      >
        <Icon name="chevronRight" />오른쪽 탭 모두 닫기
      </button>
      <span className="context-menu__separator" role="separator" />
      <button type="button" role="menuitem" onClick={() => activate(addToFavorites)}>
        <Icon name="link" />즐겨찾기에 추가
      </button>
      <button type="button" role="menuitem" onClick={() => activate(addToBoard)}>
        <TabKindIcon kind="board" />보드에 할 일로 추가
      </button>
      <button type="button" role="menuitem" onClick={() => activate(duplicateTab)}>
        <Icon name="file" />탭 복제
      </button>
      {canOpenNewInstance && (
        <button
          type="button"
          role="menuitem"
          onClick={() => activate(() => duplicateTab(true))}
        >
          <Icon name="layoutRight" />
          {t('workspace.tab.context.openSplitRight')}
        </button>
      )}

      {isFileTab && (
        <>
          <span className="context-menu__separator" role="separator" />
          <button type="button" role="menuitem" onClick={() => activate(revealFile)}>
            <Icon name="folderOpen" />Finder에서 보기
          </button>
          <button
            type="button"
            role="menuitem"
            disabled={!resourceCourse}
            onClick={() =>
              activate(() =>
                copyText(
                  absoluteMaterialPath(resourceCourse!.folderPath, descriptor.payload.relPath),
                  '경로를 복사했어요.'
                )
              )
            }
          >
            <Icon name="link" />경로 복사
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => activate(askTutorAboutFile)}
          >
            <TabKindIcon kind="chat" />AI 튜터에게 이 자료 물어보기
          </button>
        </>
      )}

      {isBrowserTab && (
        <>
          <span className="context-menu__separator" role="separator" />
          <button
            type="button"
            role="menuitem"
            onClick={() =>
              activate(() =>
                copyText(currentBrowserUrl(descriptor) ?? '', 'URL을 복사했어요.')
              )
            }
          >
            <Icon name="link" />URL 복사
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() =>
              activate(() => openInSystemBrowser(currentBrowserUrl(descriptor) ?? ''))
            }
          >
            <Icon name="link" />기본 브라우저로 열기
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => activate(() => guestActions.reload(descriptor.payload.tabId))}
          >
            <Icon name="refresh" />새로고침
          </button>
        </>
      )}
    </div>
  )

  return createPortal(menu, document.body)
}
