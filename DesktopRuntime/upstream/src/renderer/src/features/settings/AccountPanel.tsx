import { useCallback, useEffect, useId, useRef, useState } from 'react'
import {
  isValidNickname,
  NICKNAME_MAX_LENGTH
} from '../../../../shared/account/nickname'
import type { AuthState } from '../../../../shared/types/auth'
import { AccountAvatar } from '../account/AccountAvatar'
import { useT } from '../../i18n'
import { invoke, onPush } from '../../lib/ipc'
import './account-panel.css'

type PendingAction = 'nickname' | 'sign-out' | 'sign-in'

interface Feedback {
  tone: 'success' | 'error'
  message: string
}

export function AccountPanel(): JSX.Element {
  const t = useT()
  const [auth, setAuth] = useState<AuthState | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadFailed, setLoadFailed] = useState(false)
  const [nickname, setNickname] = useState('')
  const [confirmingNickname, setConfirmingNickname] = useState(false)
  const [pending, setPending] = useState<PendingAction | null>(null)
  const [feedback, setFeedback] = useState<Feedback | null>(null)
  const mountedRef = useRef(true)
  const authRevision = useRef(0)
  const nicknameInputRef = useRef<HTMLInputElement>(null)
  const nicknameId = useId()

  const readAuth = useCallback(async (): Promise<AuthState> => {
    const revision = authRevision.current
    const next = await invoke('auth:getState', {})
    if (mountedRef.current && revision === authRevision.current) {
      setAuth(next)
      setLoadFailed(false)
    }
    return next
  }, [])

  const loadAuth = useCallback((): void => {
    setLoading(true)
    setLoadFailed(false)
    void readAuth()
      .catch(() => {
        if (mountedRef.current) setLoadFailed(true)
      })
      .finally(() => {
        if (mountedRef.current) setLoading(false)
      })
  }, [readAuth])

  useEffect(() => {
    mountedRef.current = true
    const off = onPush('auth:changed', next => {
      authRevision.current += 1
      setAuth(next)
      setLoadFailed(false)
      setLoading(false)
    })
    loadAuth()
    return () => {
      mountedRef.current = false
      authRevision.current += 1
      off()
    }
  }, [loadAuth])

  const profile = auth?.phase === 'signed-in' ? auth.profile : null
  const email = auth?.email ?? null

  useEffect(() => {
    setNickname(profile?.nickname ?? '')
    setConfirmingNickname(false)
  }, [profile?.nickname])

  const runMutation = async (
    action: PendingAction,
    mutate: () => Promise<unknown>,
    successMessage: string,
    failureMessage: string
  ): Promise<void> => {
    if (pending !== null) return
    setPending(action)
    setFeedback(null)
    try {
      await mutate()
      await readAuth()
      if (mountedRef.current) {
        setFeedback({ tone: 'success', message: successMessage })
      }
    } catch {
      if (mountedRef.current) {
        setFeedback({ tone: 'error', message: failureMessage })
      }
    } finally {
      if (mountedRef.current) setPending(null)
    }
  }

  if (loading) {
    return (
      <div className="account-panel-state" role="status">
        <span>{t('settings.account.loading')}</span>
      </div>
    )
  }

  if (loadFailed) {
    return (
      <div className="account-panel-state" role="alert">
        <strong>{t('settings.account.loadFailed')}</strong>
        <button type="button" className="secondary-button" onClick={loadAuth}>
          {t('settings.account.retry')}
        </button>
      </div>
    )
  }

  if (profile === null) {
    return (
      <div className="account-panel-state">
        <strong>{t('settings.account.signedOut')}</strong>
        {auth?.phase !== 'unconfigured' && <div className="account-sign-in-actions">
          {(['google', 'kakao'] as const).map(provider => <button key={provider} type="button" className="secondary-button" disabled={pending !== null} onClick={() => void runMutation('sign-in', async () => { const result = await invoke('auth:signIn', { provider }); if (!result.ok) throw new Error('로그인 실패') }, '브라우저에서 로그인을 완료해 주세요.', '로그인을 시작하지 못했어요.')}>{provider === 'google' ? 'Google' : 'Kakao'}로 로그인</button>)}
        </div>}
        {feedback && <p role={feedback.tone === 'error' ? 'alert' : 'status'}>{feedback.message}</p>}
      </div>
    )
  }

  const displayName = profile.nickname ?? t('settings.account.unnamed')
  const trimmedNickname = nickname.trim()
  const nicknameChanged = trimmedNickname !== (profile.nickname ?? '')

  const saveNickname = (): void => {
    setConfirmingNickname(false)
    void runMutation(
      'nickname',
      () => invoke('auth:setNickname', { nickname: trimmedNickname }),
      t('settings.account.nickname.saved'),
      t('settings.account.nickname.saveFailed')
    )
  }

  const submitNickname = (event: React.FormEvent): void => {
    event.preventDefault()
    if (!isValidNickname(trimmedNickname)) {
      setFeedback({
        tone: 'error',
        message: t('settings.account.nickname.rule')
      })
      nicknameInputRef.current?.focus()
      return
    }
    if (!nicknameChanged) return
    // A renamed account frees the old nickname. First-time setup skips confirmation.
    if (profile.nickname !== null) {
      setConfirmingNickname(true)
      return
    }
    saveNickname()
  }

  return (
    <div className="settings-stack account-panel">
      <section className="settings-card account-profile-card">
        <AccountAvatar
          avatarUrl={auth?.avatarUrl ?? null}
          nickname={displayName}
          size="lg"
        />
        <div>
          <h2>{displayName}</h2>
          {email !== null && (
            <p className="account-profile-card__email">{email}</p>
          )}
          <p>{t('settings.account.profile.description')}</p>
        </div>
      </section>

      <section className="settings-card">
        <div className="settings-card__header">
          <h2>{t('settings.account.nickname.title')}</h2>
          <p>{t('settings.account.nickname.description')}</p>
        </div>
        <form className="account-nickname-form" onSubmit={submitNickname}>
          <label htmlFor={nicknameId}>{t('settings.account.nickname.label')}</label>
          <div className="account-nickname-form__row">
            <input
              ref={nicknameInputRef}
              id={nicknameId}
              value={nickname}
              placeholder={t('settings.account.nickname.placeholder')}
              maxLength={NICKNAME_MAX_LENGTH}
              autoComplete="off"
              autoCorrect="off"
              spellCheck={false}
              disabled={pending !== null}
              aria-describedby={`${nicknameId}-rule`}
              onChange={(event) => {
                setNickname(event.target.value)
                setConfirmingNickname(false)
                if (feedback?.tone === 'error') setFeedback(null)
              }}
            />
            <button
              type="submit"
              className="secondary-button"
              disabled={
                pending !== null ||
                !nicknameChanged ||
                !isValidNickname(trimmedNickname)
              }
            >
              {pending === 'nickname'
                ? t('settings.account.nickname.saving')
                : t('settings.account.nickname.save')}
            </button>
          </div>
          <p id={`${nicknameId}-rule`} className="account-field-help">
            {t('settings.account.nickname.rule')}
          </p>

          {confirmingNickname && (
            <div
              className="account-nickname-confirm"
              role="alertdialog"
              aria-label={t('settings.account.nickname.confirm.title')}
            >
              <p>{t('settings.account.nickname.confirm.message')}</p>
              <div className="account-nickname-confirm__actions">
                <button
                  type="button"
                  className="secondary-button"
                  disabled={pending !== null}
                  onClick={() => setConfirmingNickname(false)}
                >
                  {t('settings.account.nickname.confirm.cancel')}
                </button>
                <button
                  type="button"
                  className="secondary-button account-nickname-confirm__accept"
                  disabled={pending !== null}
                  onClick={saveNickname}
                >
                  {t('settings.account.nickname.confirm.change')}
                </button>
              </div>
            </div>
          )}
        </form>
      </section>

      {feedback !== null && (
        <p
          className="account-panel__feedback"
          data-tone={feedback.tone}
          role={feedback.tone === 'error' ? 'alert' : 'status'}
        >
          {feedback.message}
        </p>
      )}

      <section className="settings-card account-sign-out-card">
        <div>
          <h2>{t('settings.account.signOut.title')}</h2>
          <p>{t('settings.account.signOut.description')}</p>
        </div>
        <button
          type="button"
          className="account-sign-out-button"
          disabled={pending !== null}
          onClick={() => {
            void runMutation(
              'sign-out',
              () => invoke('auth:signOut', {}),
              t('settings.account.signOut.done'),
              t('settings.account.signOut.failed')
            )
          }}
        >
          {pending === 'sign-out'
            ? t('settings.account.signOut.pending')
            : t('settings.account.signOut.button')}
        </button>
      </section>
    </div>
  )
}
