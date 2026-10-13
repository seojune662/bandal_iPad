import { BrowserProfileSelect } from '../browser/BrowserProfileSelect'
import { useEffect, useRef, useState } from 'react'
import type {
  CredentialsAvailability,
  SavedLoginSummary,
} from '../../../../shared/types/credentials'
import { useLocale } from '../../i18n'
import { invoke } from '../../lib/ipc'

function formatUpdatedAt(value: string, locale: string): string {
  const date = new Date(value)
  return Number.isFinite(date.getTime())
    ? new Intl.DateTimeFormat(locale, {
        dateStyle: 'medium',
        timeStyle: 'short',
      }).format(date)
    : value
}

export function SavedLoginsSettings(): JSX.Element {
  const [profileId, setProfileId] = useState('default')
  return (
    <>
      <BrowserProfileSelect value={profileId} onChange={setProfileId} />
      <ProfileSavedLogins key={profileId} profileId={profileId} />
    </>
  )
}
function ProfileSavedLogins({ profileId }: { profileId: string }): JSX.Element {
  const locale = useLocale()
  const korean = locale === 'ko-KR'
  const mountedRef = useRef(true)
  const [availability, setAvailability] =
    useState<CredentialsAvailability | null>(null)
  const [logins, setLogins] = useState<SavedLoginSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)
  const [loadFailed, setLoadFailed] = useState(false)
  const [pendingOrigin, setPendingOrigin] = useState<string | null>(null)

  const load = (): void => {
    setLoading(true)
    setError(false)
    setLoadFailed(false)
    void Promise.all([
      invoke('credentials:availability', { profileId }),
      invoke('credentials:list', { profileId }),
    ])
      .then(([nextAvailability, nextLogins]) => {
        if (!mountedRef.current) return
        setAvailability(nextAvailability)
        setLogins(nextLogins)
      })
      .catch(() => {
        if (mountedRef.current) { setError(true); setLoadFailed(true) }
      })
      .finally(() => {
        if (mountedRef.current) setLoading(false)
      })
  }

  useEffect(() => {
    mountedRef.current = true
    load()
    return () => {
      mountedRef.current = false
    }
  }, [])

  const toggleAutoSubmit = async (
    login: SavedLoginSummary,
    autoSubmit: boolean,
  ): Promise<void> => {
    if (pendingOrigin !== null) return
    setError(false)
    setPendingOrigin(login.id)
    try {
      // Main treats an empty password as metadata-only only when this exact
      // origin already exists. The password never returns to this window.
      const saved = await invoke('credentials:save', {
        profileId,
        id: login.id,
        origin: login.origin,
        username: login.username,
        password: '',
        autoSubmit,
      })
      if (mountedRef.current) {
        setLogins((current) =>
          current.map((item) => (item.id === saved.id ? saved : item)),
        )
      }
    } catch {
      if (mountedRef.current) setError(true)
    } finally {
      if (mountedRef.current) setPendingOrigin(null)
    }
  }

  const forget = async (login: SavedLoginSummary): Promise<void> => {
    if (pendingOrigin !== null) return
    const confirmed = window.confirm(
      korean
        ? `${login.origin}의 저장된 로그인을 삭제할까요?`
        : `Delete the saved login for ${login.origin}?`,
    )
    if (!confirmed) return

    setError(false)
    setPendingOrigin(login.id)
    try {
      await invoke('credentials:forget', {
        profileId,
        origin: login.origin,
        credentialId: login.id,
      })
      if (mountedRef.current) {
        setLogins((current) => current.filter((item) => item.id !== login.id))
      }
    } catch {
      if (mountedRef.current) setError(true)
    } finally {
      if (mountedRef.current) setPendingOrigin(null)
    }
  }

  return (
    <section className="settings-card saved-logins-card">
      <div className="settings-card__header saved-logins-card__heading">
        <div>
          <h2>{korean ? '저장된 로그인' : 'Saved logins'}</h2>
          <p>
            {korean
              ? '내장 브라우저가 학교 포털 로그인 폼을 안전하게 채웁니다.'
              : 'Securely fill university portal forms in the in-app browser.'}
          </p>
        </div>
        {!loading && availability?.state === 'ready' && (
          <span className="count-badge">{logins.length}</span>
        )}
      </div>

      {loading ? (
        <div
          className="saved-login-loading"
          aria-label={korean ? '불러오는 중' : 'Loading'}
        >
          <span />
          <span />
        </div>
      ) : loadFailed ? (
        <div className="settings-feedback settings-feedback--error" role="alert">
          <span>{korean ? '저장된 로그인을 불러오지 못했습니다.' : 'Could not load saved logins.'}</span>
          <button type="button" className="secondary-button" onClick={load}>
            {korean ? '다시 불러오기' : 'Reload'}
          </button>
        </div>
      ) : availability?.state === 'unavailable' ? (
        <div className="saved-login-unavailable" role="status">
          <strong>
            {korean
              ? '저장된 로그인을 사용할 수 없습니다.'
              : 'Saved logins are disabled.'}
          </strong>
          <span>{availability.reason}</span>
          <span>
            {korean
              ? '비밀번호를 평문으로 저장하지 않습니다.'
              : 'Passwords are never stored without OS-backed encryption.'}
          </span>
        </div>
      ) : logins.length === 0 ? (
        <div className="saved-login-empty">
          <strong>
            {korean ? '저장된 로그인이 없습니다.' : 'No saved logins.'}
          </strong>
          <span>
            {korean
              ? '내장 브라우저에서 로그인 폼을 직접 작성한 뒤 저장할 수 있습니다.'
              : 'Enter a login in the in-app browser, then choose to save it.'}
          </span>
        </div>
      ) : (
        <div className="saved-login-list">
          {logins.map((login) => (
            <div className="saved-login-item" key={login.id}>
              <div className="saved-login-item__copy">
                <strong>{login.origin}</strong>
                <span>{login.username}</span>
                <small>
                  {korean ? '마지막 변경 ' : 'Updated '}
                  {formatUpdatedAt(login.updatedAt, locale)}
                </small>
              </div>
              <div className="saved-login-item__actions">
                <label className="saved-login-auto-submit">
                  <span>{korean ? '자동 제출' : 'Auto-submit'}</span>
                  <button
                    type="button"
                    role="switch"
                    aria-checked={login.autoSubmit}
                    aria-label={
                      korean
                        ? `${login.origin} 자동 제출`
                        : `Auto-submit ${login.origin}`
                    }
                    className={`toggle${login.autoSubmit ? ' toggle--checked' : ''}`}
                    disabled={pendingOrigin !== null}
                    onClick={() =>
                      void toggleAutoSubmit(login, !login.autoSubmit)
                    }
                  >
                    <span className="toggle__thumb" />
                  </button>
                </label>
                <button
                  type="button"
                  className="saved-login-delete"
                  disabled={pendingOrigin !== null}
                  onClick={() => void forget(login)}
                >
                  {korean ? '삭제' : 'Delete'}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      <p
        className={`settings-feedback${error ? ' settings-feedback--error' : ''}`}
        aria-live="polite"
      >
        {error
          ? korean
            ? '저장된 로그인 작업을 완료하지 못했습니다.'
            : 'Could not complete the saved login action.'
          : korean
            ? '자동 제출은 기본으로 꺼져 있으며 사이트별로 직접 켜야 합니다.'
            : 'Auto-submit is off by default and must be enabled per site.'}
      </p>
    </section>
  )
}
