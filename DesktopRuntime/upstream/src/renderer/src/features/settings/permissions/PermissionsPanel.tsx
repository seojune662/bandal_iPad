import { useCallback, useEffect, useState, type ReactNode } from 'react'
import {
  SYSTEM_PERMISSIONS,
  type SystemPermissionId,
  type SystemPermissionState,
  type SystemPermissionStatus
} from '../../../../../shared/types/permissions'
import { showToast } from '../../../app/toast'
import { useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import { SettingsCard } from '../primitives'
import './permissions-panel.css'

type PermissionTone = 'ok' | 'danger' | 'neutral' | 'muted'

export function permissionTone(state: SystemPermissionState): PermissionTone {
  if (state === 'granted') return 'ok'
  if (state === 'denied') return 'danger'
  if (state === 'not-applicable') return 'muted'
  return 'neutral'
}

function unknownStatus(id: SystemPermissionId): SystemPermissionStatus {
  return {
    id,
    state: 'unknown',
    canRequest: false,
    canOpenSettings: false
  }
}

function PermissionIcon({ id }: { id: SystemPermissionId }): JSX.Element {
  let content: ReactNode
  if (id === 'screen') {
    content = (
      <>
        <rect x="3" y="4" width="18" height="14" rx="2" />
        <path d="M8 21h8M12 18v3" />
      </>
    )
  } else if (id === 'accessibility') {
    content = (
      <>
        <circle cx="12" cy="5" r="2" />
        <path d="M5 9h14M12 7v6M8 21l4-8 4 8" />
      </>
    )
  } else if (id === 'notifications') {
    content = (
      <>
        <path d="M18 9a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9" />
        <path d="M10 21h4" />
      </>
    )
  } else {
    content = (
      <>
        <path d="M3 6.5h6l2 2h10v10.5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
        <path d="M3 9h18" />
      </>
    )
  }

  return (
    <span className="settings-permissions-icon" aria-hidden="true">
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.75"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        {content}
      </svg>
    </span>
  )
}

function PermissionStatusPill({
  state
}: {
  state: SystemPermissionState
}): JSX.Element {
  const t = useT()
  const tone = permissionTone(state)
  return (
    <span
      className={`status-pill settings-permissions-status settings-permissions-status--${tone}`}
    >
      <span className="status-pill__dot" />
      {t(`settings.permissions.status.${state}`)}
    </span>
  )
}

export function PermissionsPanel(): JSX.Element {
  const t = useT()
  const [statuses, setStatuses] = useState<SystemPermissionStatus[]>(() =>
    SYSTEM_PERMISSIONS.map(unknownStatus)
  )
  const [refreshing, setRefreshing] = useState(false)
  const [pendingId, setPendingId] = useState<SystemPermissionId | null>(null)
  const [errors, setErrors] = useState<
    Partial<Record<SystemPermissionId, string>>
  >({})

  const refresh = useCallback((): void => {
    setRefreshing(true)
    void invoke('permissions:status', {})
      .then((report) => {
        setStatuses(
          SYSTEM_PERMISSIONS.map(
            (id) =>
              report.permissions.find((status) => status.id === id) ??
              unknownStatus(id)
          )
        )
      })
      .catch(() => showToast(t('settings.permissions.refreshFailed'), 'danger'))
      .finally(() => setRefreshing(false))
  }, [t])

  useEffect(() => {
    refresh()
    window.addEventListener('focus', refresh)
    return () => window.removeEventListener('focus', refresh)
  }, [refresh])

  const runAction = (status: SystemPermissionStatus): void => {
    if (pendingId !== null) return
    setPendingId(status.id)
    setErrors((current) => ({ ...current, [status.id]: undefined }))
    const action = status.canRequest
      ? invoke('permissions:request', { id: status.id }).then((next) => {
          setStatuses((current) =>
            current.map((item) => (item.id === next.id ? next : item))
          )
        })
      : invoke('permissions:openSettings', { id: status.id }).then(() => undefined)

    void action
      .catch(() => {
        setErrors((current) => ({
          ...current,
          [status.id]: t('settings.permissions.actionFailed')
        }))
      })
      .finally(() => setPendingId(null))
  }

  return (
    <div className="settings-stack">
      <div className="inline-notice settings-permissions-notice" role="note">
        <div>
          <strong>{t('settings.permissions.inheritance')}</strong>
        </div>
        <button
          type="button"
          className="secondary-button"
          disabled={refreshing}
          onClick={refresh}
        >
          {t(
            refreshing
              ? 'settings.permissions.refreshing'
              : 'settings.permissions.refresh'
          )}
        </button>
      </div>

      <SettingsCard className="settings-permissions-card">
        <div className="settings-card__rows">
          {statuses.map((status) => {
            const pending = pendingId === status.id
            const canAct = status.canRequest || status.canOpenSettings
            return (
              <div
                className="setting-row settings-permissions-row"
                key={status.id}
              >
                <PermissionIcon id={status.id} />
                <div className="setting-row__copy">
                  <div className="setting-row__label-line">
                    <span className="setting-row__label">
                      {t(`settings.permissions.${status.id}.label`)}
                    </span>
                    <PermissionStatusPill state={status.state} />
                  </div>
                  <span className="setting-row__description">
                    {t(`settings.permissions.${status.id}.description`)}
                  </span>
                  {errors[status.id] !== undefined && (
                    <span className="settings-permissions-error" role="alert">
                      {errors[status.id]}
                    </span>
                  )}
                </div>
                {canAct && (
                  <button
                    type="button"
                    className="secondary-button"
                    disabled={pending}
                    onClick={() => runAction(status)}
                  >
                    {t(
                      pending && status.canRequest
                        ? 'settings.permissions.requesting'
                        : status.canRequest
                          ? 'settings.permissions.request'
                          : 'settings.permissions.openSettings'
                    )}
                  </button>
                )}
              </div>
            )
          })}
        </div>
      </SettingsCard>
    </div>
  )
}
