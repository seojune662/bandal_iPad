import { useCallback, useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { Icon } from '../../app/icons'
import { Tooltip } from '../../components/Tooltip'
import { useDismissableMenu } from '../../components/useDismissableMenu'
import { useViewportBounds } from '../../lib/useViewportBounds'
import { useAuthStore } from '../../stores/authStore'
import { useUiStore } from '../../stores/uiStore'
import { AccountIcon } from './accountIcons'
import { AccountAvatar } from './AccountAvatar'

/** Account menu; profile editing lives in Settings. */
export function SidebarAccountEntry(): JSX.Element | null {
  const auth = useAuthStore((state) => state.auth)
  const signOut = useAuthStore((state) => state.signOut)
  const [open, setOpen] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [focusedItem, setFocusedItem] = useState(0)
  const menuRef = useRef<HTMLDivElement>(null)
  const triggerRef = useRef<HTMLButtonElement>(null)
  const signOutRef = useRef<HTMLButtonElement>(null)
  const pendingRef = useRef(false)
  const requestGeneration = useRef(0)
  const popoverId = useId()
  const profile = auth.phase === 'signed-in' ? auth.profile : null
  const leftOpen = useUiStore(state => state.leftRailOpen)
  const closeMenu = useCallback(() => setOpen(false), [])
  useDismissableMenu(open, menuRef, closeMenu)
  useViewportBounds(menuRef)

  useEffect(() => {
    setOpen(false)
    pendingRef.current = false
    setPending(false)
    setError(null)
    return () => { requestGeneration.current += 1 }
  }, [profile?.id])

  useEffect(() => {
    if (!leftOpen) setOpen(false)
  }, [leftOpen])

  if (profile === null) return null

  const displayName = profile.nickname?.trim() || auth.email?.split('@')[0] || '내 계정'

  const openSettings = (account = false): void => {
    closeMenu()
    useUiStore.getState().openSettings(account ? 'account' : undefined)
  }

  const handleMenuKeys = (event: KeyboardEvent<HTMLDivElement>): void => {
    if (event.key === 'Tab') {
      closeMenu()
      triggerRef.current?.focus()
      return
    }
    const items = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not([aria-disabled="true"])')]
    if (!items.length) return
    const current = items.indexOf(document.activeElement as HTMLButtonElement)
    let next: number
    if (event.key === 'Home') next = 0
    else if (event.key === 'End') next = items.length - 1
    else if (event.key === 'ArrowDown') next = (current + 1) % items.length
    else if (event.key === 'ArrowUp') next = current < 0 ? items.length - 1 : (current - 1 + items.length) % items.length
    else return
    event.preventDefault()
    event.stopPropagation()
    items[next]?.focus()
  }

  const handleSignOut = async (): Promise<void> => {
    if (pendingRef.current) return
    pendingRef.current = true
    const generation = requestGeneration.current
    setPending(true)
    setError(null)
    try {
      await signOut()
      if (generation === requestGeneration.current) closeMenu()
    } catch {
      if (generation === requestGeneration.current) {
        setError('로그아웃하지 못했어요. 다시 시도해 주세요.')
        signOutRef.current?.focus()
      }
    } finally {
      if (generation === requestGeneration.current) {
        pendingRef.current = false
        setPending(false)
      }
    }
  }

  return (
    <div className="sidebar-account">
      <Tooltip label={displayName} placement="top">
        <button
          ref={triggerRef}
          type="button"
          className="rail-nav__item sidebar-account__trigger"
          aria-haspopup="menu"
          aria-expanded={open}
          aria-controls={open ? popoverId : undefined}
          aria-label={`계정: ${displayName}`}
          onClick={() => {
            triggerRef.current?.focus()
            setFocusedItem(0)
            setOpen(current => !current)
          }}
          onKeyDown={event => {
            if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
            event.preventDefault()
            event.stopPropagation()
            const index = event.key === 'ArrowDown' ? 0 : pending ? 1 : 2
            setFocusedItem(index)
            setOpen(true)
            menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')[index]?.focus()
          }}
        >
          <AccountAvatar
            avatarUrl={auth.avatarUrl}
            nickname={displayName}
            size="sm"
          />
        </button>
      </Tooltip>

      {open && (
        <div
          id={popoverId}
          ref={menuRef}
          className="sidebar-account__popover"
          role="menu"
          aria-label="계정 관리"
          aria-busy={pending || undefined}
          onKeyDown={handleMenuKeys}
        >
          <div className="sidebar-account__profile">
            <AccountAvatar
              avatarUrl={auth.avatarUrl}
              nickname={displayName}
            />
            <div className="sidebar-account__identity">
              <strong title={displayName}>{displayName}</strong>
              {auth.email !== null && (
                <span className="sidebar-account__email" title={auth.email}>{auth.email}</span>
              )}
            </div>
          </div>

          <div className="sidebar-account__divider" role="separator" />

          <button
            type="button"
            role="menuitem"
            className="sidebar-account__item sidebar-account__manage"
            tabIndex={focusedItem === 0 ? 0 : -1}
            onFocus={() => setFocusedItem(0)}
            onClick={() => openSettings(true)}
          >
            <Icon name="user" />
            <span>계정 설정</span>
          </button>

          <button
            type="button"
            role="menuitem"
            className="sidebar-account__item"
            tabIndex={focusedItem === 1 ? 0 : -1}
            onFocus={() => setFocusedItem(1)}
            onClick={() => openSettings()}
          >
            <Icon name="settings" />
            <span>앱 설정</span>
          </button>

          <div className="sidebar-account__divider" role="separator" />

          <button
            ref={signOutRef}
            type="button"
            role="menuitem"
            className="sidebar-account__item sidebar-account__sign-out"
            tabIndex={focusedItem === 2 ? 0 : -1}
            onFocus={() => setFocusedItem(2)}
            aria-disabled={pending || undefined}
            onClick={() => void handleSignOut()}
          >
            <AccountIcon name="logOut" />
            <span>{pending ? '로그아웃 중…' : '로그아웃'}</span>
          </button>

          {error !== null && <p className="sidebar-account__error" role="alert">{error}</p>}
        </div>
      )}
    </div>
  )
}
