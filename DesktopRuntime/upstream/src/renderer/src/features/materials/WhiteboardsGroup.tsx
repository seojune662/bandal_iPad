import { useViewportBounds } from '../../lib/useViewportBounds'
import { useCallback, useEffect, useId, useRef, useState } from 'react'
import type { PersonalBoard } from '../../../../shared/types/whiteboard'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { Tooltip } from '../../components/Tooltip'
import { invoke } from '../../lib/ipc'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { MaterialRowAffordance } from './MaterialAffordances'

interface BoardMenuState {
  board: PersonalBoard
  x: number
  y: number
  placement: 'top' | 'bottom'
  align: 'start' | 'end'
  returnFocus: HTMLElement
}

interface BoardRenameState extends BoardMenuState {
  title: string
}

function operationError(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback
}

export function sortPersonalBoards(
  boards: readonly PersonalBoard[]
): PersonalBoard[] {
  return [...boards].sort(
    (left, right) =>
      left.sortOrder - right.sortOrder ||
      left.createdAt.localeCompare(right.createdAt)
  )
}

function WhiteboardIcon(): JSX.Element {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      width="1em"
      height="1em"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x="4" y="4" width="16" height="16" rx="2" />
      <path d="M8 9h8M8 13h5M8 17h7" />
    </svg>
  )
}

function enabledMenuItems(menu: HTMLElement): HTMLButtonElement[] {
  return Array.from(
    menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not(:disabled)')
  )
}

export function WhiteboardsGroup(props: { courseId: string }): JSX.Element {
  const { courseId } = props
  const [expanded, setExpanded] = useState(true)
  const [boards, setBoards] = useState<PersonalBoard[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [renamingId, setRenamingId] = useState<string | null>(null)
  const [removingId, setRemovingId] = useState<string | null>(null)
  const [menu, setMenu] = useState<BoardMenuState | null>(null)
  const [renameDraft, setRenameDraft] = useState<BoardRenameState | null>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  useViewportBounds(menuRef)
  const renamePopoverRef = useRef<HTMLFormElement>(null)
  useViewportBounds(renamePopoverRef)
  const activeCourseIdRef = useRef<string | null>(courseId)
  const renameInputId = useId()

  const closeMenu = useCallback(() => setMenu(null), [])
  const closeRename = useCallback(() => setRenameDraft(null), [])

  useEffect(() => {
    return () => {
      activeCourseIdRef.current = null
    }
  }, [])

  useEffect(() => {
    activeCourseIdRef.current = courseId
    let cancelled = false
    setBoards(null)
    setError(null)
    setMenu(null)
    setRenameDraft(null)
    setCreating(false)
    setRenamingId(null)
    setRemovingId(null)
    void invoke('canvas:list', { courseId })
      .then((result) => {
        if (!cancelled) setBoards(sortPersonalBoards(result))
      })
      .catch((loadError: unknown) => {
        if (cancelled) return
        setBoards([])
        setError(
          operationError(loadError, '화이트보드 목록을 불러오지 못했어요.')
        )
      })
    return () => {
      cancelled = true
    }
  }, [courseId])

  useEffect(() => {
    if (menu === null) return
    const frame = window.requestAnimationFrame(() => {
      menuRef.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus()
    })
    const dismissOnPointerDown = (event: PointerEvent): void => {
      if (!menuRef.current?.contains(event.target as Node)) closeMenu()
    }
    const dismissOnEscape = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') closeMenu()
    }
    window.addEventListener('pointerdown', dismissOnPointerDown)
    window.addEventListener('keydown', dismissOnEscape)
    window.addEventListener('blur', closeMenu)
    return () => {
      window.cancelAnimationFrame(frame)
      window.removeEventListener('pointerdown', dismissOnPointerDown)
      window.removeEventListener('keydown', dismissOnEscape)
      window.removeEventListener('blur', closeMenu)
      if (menu.returnFocus.isConnected) menu.returnFocus.focus()
    }
  }, [closeMenu, menu])

  const renamingBoardId = renameDraft?.board.id ?? null
  useEffect(() => {
    if (renamingBoardId === null) return
    const dismissOnPointerDown = (event: PointerEvent): void => {
      if (!renamePopoverRef.current?.contains(event.target as Node)) {
        closeRename()
      }
    }
    const dismissOnEscape = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      closeRename()
    }
    window.addEventListener('pointerdown', dismissOnPointerDown)
    window.addEventListener('keydown', dismissOnEscape)
    window.addEventListener('blur', closeRename)
    return () => {
      window.removeEventListener('pointerdown', dismissOnPointerDown)
      window.removeEventListener('keydown', dismissOnEscape)
      window.removeEventListener('blur', closeRename)
      if (renameDraft?.returnFocus.isConnected === true) {
        renameDraft.returnFocus.focus()
      }
    }
  }, [closeRename, renameDraft?.returnFocus, renamingBoardId])

  const openBoard = useCallback(
    (boardId: string): void => {
      useWorkspaceStore
        .getState()
        .openTab(descriptorFor('whiteboard', { courseId, boardId }))
    },
    [courseId]
  )

  const createBoard = async (): Promise<void> => {
    if (creating) return
    setCreating(true)
    setError(null)
    try {
      const created = await invoke('canvas:create', { courseId })
      if (activeCourseIdRef.current !== courseId) return
      setBoards((current) => sortPersonalBoards([...(current ?? []), created]))
      openBoard(created.id)
    } catch (createError: unknown) {
      if (activeCourseIdRef.current === courseId) {
        setError(
          operationError(createError, '새 화이트보드를 만들지 못했어요.')
        )
      }
    } finally {
      if (activeCourseIdRef.current === courseId) setCreating(false)
    }
  }

  const renameBoard = async (
    event: React.FormEvent<HTMLFormElement>
  ): Promise<void> => {
    event.preventDefault()
    if (renameDraft === null || renamingId !== null) return
    const { board } = renameDraft
    const title = renameDraft.title.trim()
    if (title.length === 0) {
      setError('화이트보드 이름을 입력해 주세요.')
      return
    }
    if (title === board.title) {
      closeRename()
      return
    }

    setRenamingId(board.id)
    setError(null)
    try {
      const renamed = await invoke('canvas:rename', { id: board.id, title })
      if (activeCourseIdRef.current !== courseId) return
      setBoards((current) =>
        current?.map((entry) =>
          entry.id === renamed.id ? renamed : entry
        ) ?? null
      )
      closeRename()
    } catch (renameError: unknown) {
      if (activeCourseIdRef.current === courseId) {
        setError(
          operationError(renameError, '화이트보드 이름을 바꾸지 못했어요.')
        )
      }
    } finally {
      if (activeCourseIdRef.current === courseId) setRenamingId(null)
    }
  }

  const removeBoard = async (board: PersonalBoard): Promise<void> => {
    closeMenu()
    if (!window.confirm(`“${board.title}” 화이트보드를 삭제할까요?`)) return

    setRemovingId(board.id)
    setError(null)
    try {
      await invoke('canvas:remove', { id: board.id })
      if (activeCourseIdRef.current !== courseId) return
      setBoards((current) =>
        current?.filter((entry) => entry.id !== board.id) ?? null
      )
      useWorkspaceStore.getState().closeTabsMatching(
        descriptorFor('whiteboard', { courseId, boardId: board.id })
      )
      showToast('화이트보드를 삭제했어요.')
    } catch (removeError: unknown) {
      if (activeCourseIdRef.current === courseId) {
        setError(operationError(removeError, '화이트보드를 삭제하지 못했어요.'))
      }
    } finally {
      if (activeCourseIdRef.current === courseId) setRemovingId(null)
    }
  }

  const handleMenuKeyDown = (
    event: React.KeyboardEvent<HTMLDivElement>
  ): void => {
    const menuElement = menuRef.current
    if (menuElement === null) return
    const items = enabledMenuItems(menuElement)
    if (items.length === 0) return
    const current = items.indexOf(document.activeElement as HTMLButtonElement)
    let next: number | null = null
    if (event.key === 'ArrowDown') {
      next = current < 0 ? 0 : (current + 1) % items.length
    }
    if (event.key === 'ArrowUp') {
      next = current < 0 ? items.length - 1 : (current - 1 + items.length) % items.length
    }
    if (event.key === 'Home') next = 0
    if (event.key === 'End') next = items.length - 1
    if (event.key === 'Tab') {
      next = event.shiftKey
        ? current <= 0
          ? items.length - 1
          : current - 1
        : current >= items.length - 1
          ? 0
          : current + 1
    }
    if (next === null) return
    event.preventDefault()
    items[next]?.focus()
  }

  return (
    <section className="whiteboards-group" aria-label="화이트보드">
      <div className="materials-group-heading">
        <button className="materials-section-toggle" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}><span aria-hidden="true">{expanded ? '⌄' : '›'}</span>화이트보드 <small>{boards?.length ?? 0}</small></button>
        <Tooltip label="새 화이트보드 만들기">
          <button
            type="button"
            className="whiteboards-group__create"
            aria-label="새 화이트보드 만들기"
            disabled={creating}
            onClick={() => void createBoard()}
          >
            <Icon name="plus" />
          </button>
        </Tooltip>
      </div>

      <div hidden={!expanded}>
      {boards === null && (
        <p className="whiteboards-group__status" role="status">
          불러오는 중…
        </p>
      )}

      {boards !== null && boards.length > 0 && (
        <ul className="whiteboards-group__list">
          {boards.map((board) => {
            const pending = renamingId === board.id || removingId === board.id
            return (
              <li key={board.id}>
                <MaterialRowAffordance target={{ courseId, board }}>
                  <button
                    type="button"
                    className="whiteboards-group__row"
                    disabled={pending}
                    onClick={() => openBoard(board.id)}
                    onContextMenu={(event) => {
                      event.preventDefault()
                      event.stopPropagation()
                      setMenu({
                        board,
                        x: event.clientX,
                        y: event.clientY,
                        placement:
                          event.clientY > window.innerHeight / 2
                            ? 'top'
                            : 'bottom',
                        align:
                          event.clientX > window.innerWidth / 2 ? 'end' : 'start',
                        returnFocus: event.currentTarget
                      })
                    }}
                  >
                    <WhiteboardIcon />
                    <span>{board.title}</span>
                  </button>
                </MaterialRowAffordance>
              </li>
            )
          })}
        </ul>
      )}

      {boards !== null && boards.length === 0 && error === null && (
        <p className="whiteboards-group__empty">새 보드를 만들어 생각을 펼쳐보세요.</p>
      )}

      {error !== null && (
        <p className="whiteboards-group__error" role="alert">
          {error}
        </p>
      )}

      </div>
      {menu !== null && (
        <div
          ref={menuRef}
          className="context-menu whiteboard-context-menu"
          role="menu"
          aria-label={`${menu.board.title} 메뉴`}
          data-placement={menu.placement}
          data-align={menu.align}
          style={{ left: menu.x, top: menu.y }}
          onKeyDown={handleMenuKeyDown}
        >
          <button
            type="button"
            role="menuitem"
            disabled={renamingId !== null || removingId !== null}
            onClick={() => {
              setRenameDraft({ ...menu, title: menu.board.title })
              setMenu(null)
            }}
          >
            <Icon name="pencil" />이름 변경
          </button>
          <button
            type="button"
            className="context-menu__danger"
            role="menuitem"
            disabled={renamingId !== null || removingId !== null}
            onClick={() => void removeBoard(menu.board)}
          >
            <Icon name="trash" />삭제
          </button>
        </div>
      )}

      {renameDraft !== null && (
        <form
          ref={renamePopoverRef}
          className="whiteboard-rename-popover"
          data-placement={renameDraft.placement}
          data-align={renameDraft.align}
          style={{ left: renameDraft.x, top: renameDraft.y }}
          onSubmit={(event) => void renameBoard(event)}
        >
          <label htmlFor={renameInputId}>화이트보드 이름</label>
          <div className="whiteboard-rename-popover__row">
            <input
              id={renameInputId}
              type="text"
              autoComplete="off"
              autoFocus
              value={renameDraft.title}
              disabled={renamingId !== null}
              onFocus={(event) => event.currentTarget.select()}
              onChange={(event) =>
                setRenameDraft((current) =>
                  current === null
                    ? null
                    : { ...current, title: event.target.value }
                )
              }
            />
            <button
              type="button"
              disabled={renamingId !== null}
              onClick={closeRename}
            >
              취소
            </button>
            <button
              type="submit"
              disabled={
                renamingId !== null || renameDraft.title.trim().length === 0
              }
            >
              {renamingId !== null ? '저장 중…' : '저장'}
            </button>
          </div>
        </form>
      )}
    </section>
  )
}
