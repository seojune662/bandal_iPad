import { useViewportBounds } from '../../lib/useViewportBounds'
import { useEffect, useRef } from 'react'
import type { MaterialNode } from '../../../../shared/types/materials'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { useT } from '../../i18n'
import { useFavoritesStore } from '../../stores/favoritesStore'
import { useMaterialsStore } from '../../stores/materialsStore'
import { materialDescriptor } from '../courses/favoriteDrop'
import { MaterialsStudyToolMenuItem } from '../study/MaterialsStudyToolMenuItem'
import { tabTitle } from '../workspace/tabIdentity'
import { PluginMenuItems } from '../plugins/PluginMenuItems'
import { convertPresentationToPdf } from '../file/pptx/presentationJobs'
import { openStudyMarketSell } from '../studyMarket/controller'
import { isSellableMaterial } from '../studyMarket/presentation'

export interface MaterialsContextMenuState {
  target: MaterialNode | null
  x: number
  y: number
  placement: 'top' | 'bottom'
  align: 'start' | 'end'
  returnFocus: HTMLElement | null
}

interface MaterialsContextMenuProps extends MaterialsContextMenuState {
  onClose: () => void
  onCreateFile: () => void
  onCreateFolder: () => void
  onDuplicate: () => void
  onCopyAbsolutePath: () => void
  onCopyRelativePath: () => void
  onReveal: () => void
  onConnect: () => void
  onPageNote: () => void
  onRename: () => void
  onDelete: () => void
}

export function canConnectMaterial(
  target: MaterialNode | null
): target is MaterialNode & { kind: Exclude<MaterialNode['kind'], 'dir'> } {
  return target !== null && target.kind !== 'dir'
}

function menuItems(menu: HTMLElement): HTMLButtonElement[] {
  return Array.from(
    menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')
  )
}

export function MaterialsContextMenu({
  target,
  x,
  y,
  placement,
  align,
  returnFocus,
  onClose,
  onCreateFile,
  onCreateFolder,
  onDuplicate,
  onCopyAbsolutePath,
  onCopyRelativePath,
  onReveal,
  onConnect,
  onPageNote,
  onRename,
  onDelete
}: MaterialsContextMenuProps): JSX.Element {
  const menuRef = useRef<HTMLDivElement>(null)
  useViewportBounds(menuRef)
  const hasTarget = target !== null
  const t = useT()
  const activeCourseId = useMaterialsStore((state) => state.activeCourseId)
  const addFavorite = useFavoritesStore((state) => state.add)
  const favoriteDescriptor =
    canConnectMaterial(target) && activeCourseId !== null
      ? materialDescriptor(activeCourseId, target.relPath)
      : null

  const handleAddFavorite = async (): Promise<void> => {
    if (activeCourseId === null || favoriteDescriptor === null) return
    onClose()
    try {
      await addFavorite({
        courseId: activeCourseId,
        label: tabTitle(favoriteDescriptor),
        descriptor: favoriteDescriptor
      })
      showToast(t('materials.favorite.added'))
    } catch {
      showToast(t('materials.favorite.addFailed'), 'danger')
    }
  }

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

  const handleKeyDown = (event: React.KeyboardEvent<HTMLDivElement>): void => {
    const menu = menuRef.current
    if (menu === null) return
    const items = menuItems(menu)
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

  return (
    <div
      ref={menuRef}
      className="context-menu materials-context-menu"
      role="menu"
      aria-label={target === null ? '자료 폴더 메뉴' : `${target.name} 메뉴`}
      data-placement={placement}
      data-align={align}
      style={{ left: x, top: y }}
      onKeyDown={handleKeyDown}
    >
      <button type="button" role="menuitem" onClick={onCreateFile}>
        <Icon name="fileText" />새 파일
      </button>
      <button type="button" role="menuitem" onClick={onCreateFolder}>
        <Icon name="folderPlus" />새 폴더
      </button>
      <div className="materials-context-menu__separator" role="separator" />
      <MaterialsStudyToolMenuItem
        target={target}
        returnFocus={returnFocus}
        onClose={onClose}
      />
      {activeCourseId !== null && (target === null || target.kind === 'dir' || isSellableMaterial(target.relPath)) && (
        <button type="button" role="menuitem" onClick={() => {
          openStudyMarketSell({ courseId: activeCourseId, ...(target === null ? {} : { relPath: target.relPath }) })
          onClose()
        }}><Icon name="fileText" />자료 판매하기</button>
      )}
      {target !== null && activeCourseId !== null && <PluginMenuItems location="materials" courseId={activeCourseId} relPath={target.relPath} onClose={onClose} />}
      {favoriteDescriptor !== null && (
        <button
          type="button"
          role="menuitem"
          onClick={() => void handleAddFavorite()}
        >
          <Icon name="plus" />{t('materials.favorite.add')}
        </button>
      )}
      <button
        type="button"
        role="menuitem"
        disabled={!canConnectMaterial(target)}
        onClick={onConnect}
      >
        <Icon name="link" />{t('links.menu.connect')}
      </button>
      {(target?.kind === 'pdf' || (target?.kind !== 'dir' && /\.pptx?$/i.test(target?.relPath ?? ''))) && (
        <button type="button" role="menuitem" onClick={onPageNote}>
          <Icon name="fileText" />페이지 필기
        </button>
      )}
      {target && target.kind !== 'dir' && /\.pptx?$/i.test(target.relPath) && <button type="button" role="menuitem" onClick={() => {
        if (activeCourseId === null) return
        onClose(); void convertPresentationToPdf({ courseId: activeCourseId, relPath: target.relPath })
      }}><Icon name="fileText" />PDF로 변환</button>}
      <button
        type="button"
        role="menuitem"
        disabled={!hasTarget}
        onClick={onDuplicate}
      >
        <Icon name="file" />복제
      </button>
      <button type="button" role="menuitem" onClick={onCopyAbsolutePath}>
        <Icon name="link" />경로 복사
      </button>
      <button type="button" role="menuitem" onClick={onCopyRelativePath}>
        <Icon name="link" />상대 경로 복사
      </button>
      <button
        type="button"
        role="menuitem"
        disabled={!hasTarget}
        onClick={onReveal}
      >
        <Icon name="folderOpen" />폴더에서 보기
      </button>
      <div className="materials-context-menu__separator" role="separator" />
      <button
        type="button"
        role="menuitem"
        disabled={!hasTarget}
        onClick={onRename}
      >
        <Icon name="pencil" />이름 변경
      </button>
      <button
        type="button"
        className="materials-context-menu__danger"
        role="menuitem"
        disabled={!hasTarget}
        onClick={onDelete}
      >
        <Icon name="trash" />삭제
      </button>
    </div>
  )
}
