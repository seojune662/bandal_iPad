import { useViewportBounds } from '../../lib/useViewportBounds'
import { useEffect, useId, useRef, useState } from 'react'
import { v4 as uuidv4 } from 'uuid'
import type { Favorite } from '../../../../shared/types/favorite'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { useT } from '../../i18n'
import {
  favoriteScopeKey,
  useFavoritesStore
} from '../../stores/favoritesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { tabTitle } from '../workspace/tabIdentity'
import { TabKindIcon } from '../workspace/workspaceIcons'
import { matchesWorkspaceMoveData } from '../workspace/tabDrag'
import { tabDragSession } from '../workspace/tabDragSession'
import { acceptWorkspaceCourseCopyDrop } from '../workspace/courseTabMoveNavigation'
import {
  canAcceptFavoriteDrop,
  descriptorFromDrop,
  FAVORITE_ITEM_MIME,
  FAVORITE_TAB_MIME,
  moveFavoriteBefore,
  moveFavoriteToEnd,
  serializeFavoriteTabDrag
} from './favoriteDrop'
import { buildLinkFavoriteInput } from './linkFavorite'
import { favoriteDisplayLabel } from '../browser/browserStartPageModel'

interface FavoritesSectionProps {
  courseId: string | null
}

interface FavoriteRenameState {
  id: string
  label: string
  originalLabel: string
  x: number
  y: number
  placement: 'top' | 'bottom'
}

export function FavoritesSection(props: FavoritesSectionProps): JSX.Element {
  return <FavoritesSectionBody key={favoriteScopeKey(props.courseId)} {...props} />
}

function FavoritesSectionBody({ courseId }: FavoritesSectionProps): JSX.Element {
  const key = favoriteScopeKey(courseId)
  const t = useT()
  const linkFormId = useId()
  const favorites = useFavoritesStore((state) => state.byCourse[key])
  const loading = useFavoritesStore(
    (state) => state.loadingByCourse[key] === true
  )
  const error = useFavoritesStore((state) => state.errorScopeKey === key ? state.error : null)
  const load = useFavoritesStore((state) => state.load)
  const add = useFavoritesStore((state) => state.add)
  const rename = useFavoritesStore((state) => state.rename)
  const remove = useFavoritesStore((state) => state.remove)
  const reorder = useFavoritesStore((state) => state.reorder)
  const [dragOver, setDragOver] = useState(false)
  const [isAddingLink, setAddingLink] = useState(false)
  const [linkUrl, setLinkUrl] = useState('')
  const [linkLabel, setLinkLabel] = useState('')
  const [linkError, setLinkError] = useState<string | null>(null)
  const [isSavingLink, setSavingLink] = useState(false)
  const [renameDraft, setRenameDraft] =
    useState<FavoriteRenameState | null>(null)
  const [isSavingRename, setSavingRename] = useState(false)
  const dragDepth = useRef(0)
  const savingLink = useRef(false)
  const renameSequence = useRef(0)
  const requestedScope = useRef<string | null>(null)
  const linkUrlRef = useRef<HTMLInputElement>(null)
  const renamePopoverRef = useRef<HTMLFormElement>(null)
  useViewportBounds(renamePopoverRef)
  const renameTriggerRef = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    if (
      favorites === undefined &&
      !loading &&
      requestedScope.current !== key
    ) {
      requestedScope.current = key
      void load(courseId)
    }
  }, [courseId, favorites, key, load, loading])

  useEffect(() => {
    if (isAddingLink) linkUrlRef.current?.focus()
  }, [isAddingLink])

  const renamingFavoriteId = renameDraft?.id ?? null
  useEffect(() => {
    if (renamingFavoriteId === null) return
    const closeOutside = (event: MouseEvent): void => {
      if (
        event.target instanceof Node &&
        renamePopoverRef.current?.contains(event.target) === true
      ) {
        return
      }
      setRenameDraft(null)
    }
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      setRenameDraft(null)
    }
    document.addEventListener('mousedown', closeOutside)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('mousedown', closeOutside)
      document.removeEventListener('keydown', closeOnEscape)
      if (renameTriggerRef.current?.isConnected === true) {
        renameTriggerRef.current.focus()
      }
    }
  }, [renamingFavoriteId])

  useEffect(() => {
    setRenameDraft(null)
    setSavingRename(false)
  }, [key])

  const closeLinkForm = (): void => {
    setAddingLink(false)
    setLinkUrl('')
    setLinkLabel('')
    setLinkError(null)
  }

  const handleAddLink = async (
    event: React.FormEvent<HTMLFormElement>
  ): Promise<void> => {
    event.preventDefault()
    if (savingLink.current) return

    let input
    try {
      input = buildLinkFavoriteInput(
        courseId,
        linkUrl,
        linkLabel,
        uuidv4()
      )
    } catch (validationError) {
      setLinkError(
        validationError instanceof Error
          ? validationError.message
          : '링크 정보를 확인해 주세요.'
      )
      return
    }

    savingLink.current = true
    setSavingLink(true)
    setLinkError(null)
    try {
      await add(input)
      showToast('링크를 즐겨찾기에 추가했어요.')
      closeLinkForm()
    } catch {
      setLinkError('링크를 저장하지 못했어요. 다시 시도해 주세요.')
    } finally {
      savingLink.current = false
      setSavingLink(false)
    }
  }

  const saveOrder = (ids: string[]): void => {
    if (favorites?.every((favorite, index) => favorite.id === ids[index])) return
    void reorder(ids).catch(() => {
      showToast('즐겨찾기 순서를 저장하지 못했어요.', 'danger')
    })
  }

  const openRenamePopover = (
    event: React.MouseEvent<HTMLButtonElement>,
    favorite: Favorite
  ): void => {
    renameSequence.current++
    setSavingRename(false)
    const bounds = event.currentTarget.getBoundingClientRect()
    renameTriggerRef.current = event.currentTarget
    setRenameDraft({
      id: favorite.id,
      label: favorite.label,
      originalLabel: favorite.label,
      x: bounds.right,
      y: bounds.top > window.innerHeight / 2 ? bounds.top : bounds.bottom,
      placement: bounds.top > window.innerHeight / 2 ? 'top' : 'bottom'
    })
  }

  const handleRename = async (
    event: React.FormEvent<HTMLFormElement>
  ): Promise<void> => {
    event.preventDefault()
    if (renameDraft === null || isSavingRename) return
    const label = renameDraft.label.trim()
    if (label.length === 0) return
    if (label === renameDraft.originalLabel) {
      setRenameDraft(null)
      return
    }

    const sequence = ++renameSequence.current
    const sent = renameDraft
    setSavingRename(true)
    try {
      await rename({ id: renameDraft.id, label })
      if (renameSequence.current === sequence) setRenameDraft(current => current === sent ? null : current)
    } catch {
      showToast('즐겨찾기 이름을 바꾸지 못했어요.', 'danger')
    } finally {
      if (renameSequence.current === sequence) setSavingRename(false)
    }
  }

  const handleRemove = (favorite: Favorite): void => {
    if (renameDraft?.id === favorite.id) setRenameDraft(null)
    void remove(favorite.id).catch(() => {
      showToast('즐겨찾기를 제거하지 못했어요.', 'danger')
    })
  }

  const handleDragEnter = (event: React.DragEvent<HTMLElement>): void => {
    if (!canAcceptFavoriteDrop(event.dataTransfer)) return
    event.preventDefault()
    dragDepth.current += 1
    setDragOver(true)
  }

  const handleDragLeave = (event: React.DragEvent<HTMLElement>): void => {
    if (!canAcceptFavoriteDrop(event.dataTransfer)) return
    dragDepth.current = Math.max(0, dragDepth.current - 1)
    if (dragDepth.current === 0) setDragOver(false)
  }

  const handleDragOver = (event: React.DragEvent<HTMLElement>): void => {
    if (!canAcceptFavoriteDrop(event.dataTransfer)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = event.dataTransfer.types.includes(
      FAVORITE_ITEM_MIME
    )
      ? 'move'
      : 'copy'
  }

  const handleDrop = (event: React.DragEvent<HTMLElement>): void => {
    if (!canAcceptFavoriteDrop(event.dataTransfer)) return
    event.preventDefault()
    dragDepth.current = 0
    setDragOver(false)

    const favoriteId = event.dataTransfer.getData(FAVORITE_ITEM_MIME)
    if (favoriteId.length > 0 && favorites !== undefined) {
      saveOrder(moveFavoriteToEnd(favorites.map((favorite) => favorite.id), favoriteId))
      return
    }

    const descriptor = descriptorFromDrop(event.dataTransfer)
    if (descriptor === null) {
      showToast('이 항목은 즐겨찾기에 추가할 수 없어요.', 'danger')
      return
    }
    const source = tabDragSession.getSource()
    if (source && matchesWorkspaceMoveData(event.dataTransfer, source)) acceptWorkspaceCourseCopyDrop(source.nonce)
    void add({ courseId, label: tabTitle(descriptor), descriptor })
      .then(() => showToast('즐겨찾기에 추가했어요.'))
      .catch(() => showToast('즐겨찾기를 추가하지 못했어요.', 'danger'))
  }

  return (
    <section
      className="favorites-section"
      data-tour="favorites-section"
      data-empty={favorites?.length === 0 || undefined}
      data-drag-over={dragOver || undefined}
      aria-label="즐겨찾기"
      onDragEnter={handleDragEnter}
      onDragLeave={handleDragLeave}
      onDragOver={handleDragOver}
      onDrop={handleDrop}
    >
      <div className="favorites-section__heading">
        <span>{favorites?.length === 0 && !isAddingLink ? t('favorites.emptyHelp') : '즐겨찾기'}</span>
        <button
          type="button"
          className="favorites-section__add-link"
          aria-label="링크 추가"
          title="링크 추가"
          aria-expanded={isAddingLink}
          disabled={isSavingLink}
          onClick={() => {
            if (isAddingLink) closeLinkForm()
            else {
              setLinkError(null)
              setAddingLink(true)
            }
          }}
        >
          <Icon name="plus" />
        </button>
      </div>

      {isAddingLink && (
        <form
          className="favorite-link-form"
          onSubmit={(event) => void handleAddLink(event)}
        >
          <label htmlFor={`${linkFormId}-url`}>URL</label>
          <input
            ref={linkUrlRef}
            id={`${linkFormId}-url`}
            type="text"
            inputMode="url"
            autoComplete="url"
            placeholder="주소 입력"
            value={linkUrl}
            disabled={isSavingLink}
            onChange={(event) => setLinkUrl(event.target.value)}
          />
          <label htmlFor={`${linkFormId}-label`}>이름</label>
          <input
            id={`${linkFormId}-label`}
            type="text"
            autoComplete="off"
            placeholder="강의실"
            value={linkLabel}
            disabled={isSavingLink}
            onChange={(event) => setLinkLabel(event.target.value)}
          />
          {linkError !== null && (
            <p className="favorite-link-form__error" role="alert">
              {linkError}
            </p>
          )}
          <div className="favorite-link-form__actions">
            <button type="button" disabled={isSavingLink} onClick={closeLinkForm}>
              취소
            </button>
            <button type="submit" disabled={isSavingLink}>
              {isSavingLink ? '추가 중…' : '추가'}
            </button>
          </div>
        </form>
      )}

      {!isAddingLink && dragOver && (
        <p className="favorites-section__drop-copy" aria-hidden="true">
          여기에 놓아 추가
        </p>
      )}

      {loading && favorites === undefined ? (
        <p className="favorites-section__status">불러오는 중…</p>
      ) : favorites !== undefined && favorites.length > 0 ? (
        <ul className="favorites-list">
          {favorites.map((favorite) => (
            <li
              key={favorite.id}
              className="favorite-row"
              draggable={renameDraft?.id !== favorite.id}
              onDragStart={(event) => {
                event.dataTransfer.effectAllowed = 'copyMove'
                event.dataTransfer.setData(FAVORITE_ITEM_MIME, favorite.id)
                event.dataTransfer.setData(
                  FAVORITE_TAB_MIME,
                  serializeFavoriteTabDrag(favorite.descriptor)
                )
              }}
              onDragEnd={() => {
                dragDepth.current = 0
                setDragOver(false)
              }}
              onDragOver={(event) => {
                if (!event.dataTransfer.types.includes(FAVORITE_ITEM_MIME)) return
                event.preventDefault()
                event.stopPropagation()
                event.dataTransfer.dropEffect = 'move'
              }}
              onDrop={(event) => {
                const sourceId = event.dataTransfer.getData(FAVORITE_ITEM_MIME)
                if (sourceId.length === 0) return
                event.preventDefault()
                event.stopPropagation()
                dragDepth.current = 0
                setDragOver(false)
                saveOrder(
                  moveFavoriteBefore(
                    favorites.map((item) => item.id),
                    sourceId,
                    favorite.id
                  )
                )
              }}
            >
              <button
                type="button"
                className="favorite-row__open"
                title={favorite.descriptor.kind === 'browser' ? `${favoriteDisplayLabel(favorite)}\n${favorite.descriptor.payload.initialUrl}` : favorite.label}
                onClick={(event) => {
                  const newInstance =
                    favorite.descriptor.kind !== 'board' &&
                    (window.bandal?.platform === 'darwin'
                      ? event.metaKey
                      : event.ctrlKey)
                  if (newInstance) {
                    useWorkspaceStore
                      .getState()
                      .openTab(favorite.descriptor, { newInstance: true })
                    return
                  }
                  useWorkspaceStore.getState().openTab(favorite.descriptor)
                }}
              >
                <TabKindIcon kind={favorite.descriptor.kind} />
                <span>{favoriteDisplayLabel(favorite)}</span>
              </button>
              <div className="favorite-row__actions">
                <button
                  type="button"
                  aria-label={`${favoriteDisplayLabel(favorite)} 이름 변경`}
                  title="이름 변경"
                  aria-expanded={renameDraft?.id === favorite.id}
                  onClick={(event) => openRenamePopover(event, favorite)}
                >
                  <Icon name="pencil" />
                </button>
                <button
                  type="button"
                  aria-label={`${favoriteDisplayLabel(favorite)} 즐겨찾기 제거`}
                  title="즐겨찾기 제거"
                  onClick={() => handleRemove(favorite)}
                >
                  <Icon name="x" />
                </button>
              </div>
            </li>
          ))}
        </ul>
      ) : null}

      {renameDraft !== null && (
        <form
          ref={renamePopoverRef}
          className="favorite-rename-popover"
          data-placement={renameDraft.placement}
          style={{ left: renameDraft.x, top: renameDraft.y }}
          onSubmit={(event) => void handleRename(event)}
        >
          <label htmlFor={`${linkFormId}-favorite-name`}>즐겨찾기 이름</label>
          <div className="favorite-rename-popover__row">
            <input
              id={`${linkFormId}-favorite-name`}
              type="text"
              autoComplete="off"
              autoFocus
              value={renameDraft.label}
              disabled={isSavingRename}
              onFocus={(event) => event.currentTarget.select()}
              onChange={(event) =>
                setRenameDraft((current) =>
                  current === null
                    ? null
                    : { ...current, label: event.target.value }
                )
              }
            />
            <button
              type="button"
              disabled={isSavingRename}
              onClick={() => setRenameDraft(null)}
            >
              취소
            </button>
            <button
              type="submit"
              disabled={isSavingRename || renameDraft.label.trim().length === 0}
            >
              {isSavingRename ? '저장 중…' : '저장'}
            </button>
          </div>
        </form>
      )}

      {error !== null && (
        <p className="favorites-section__error" role="alert">
          {error}
          <button type="button" disabled={loading} onClick={() => void load(courseId)}>다시 불러오기</button>
        </p>
      )}
    </section>
  )
}
