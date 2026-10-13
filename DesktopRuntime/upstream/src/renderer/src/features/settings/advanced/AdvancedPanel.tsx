import { useEffect, useState } from 'react'
import type { Settings } from '../../../../../shared/types/settings'
import { showToast } from '../../../app/toast'
import { useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import { SettingsCard } from '../primitives'
import { Icon } from '../SettingsIcon'
import './advanced-panel.css'

function displayDataRoot(path: string | undefined): string {
  if (
    path === undefined ||
    path.length === 0 ||
    path.endsWith('/Documents/Bandal')
  ) {
    return '~/Documents/Bandal'
  }
  return path
}

function rejectedMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message
  }
  if (typeof error === 'string' && error.trim().length > 0) return error
  return fallback
}

export function AdvancedPanel({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  const [pickedDataRoot, setPickedDataRoot] = useState<string | null>(null)
  const [pickingDataRoot, setPickingDataRoot] = useState(false)
  const [dataRootError, setDataRootError] = useState<string | null>(null)
  const [clearingCache, setClearingCache] = useState(false)
  const [confirmingReset, setConfirmingReset] = useState(false)
  const [resetting, setResetting] = useState(false)

  useEffect(() => setPickedDataRoot(null), [settings?.dataRoot])

  const handlePickDataRoot = (): void => {
    if (pickingDataRoot) return
    setPickingDataRoot(true)
    setDataRootError(null)
    void invoke('settings:pickDataRoot', {})
      .then((result) => {
        if (result !== null) setPickedDataRoot(result.dataRoot)
      })
      .catch((error: unknown) => {
        setDataRootError(
          rejectedMessage(error, t('settings.general.workspace.pickFailed'))
        )
      })
      .finally(() => setPickingDataRoot(false))
  }

  const handleClearCache = (): void => {
    if (clearingCache) return
    setClearingCache(true)
    void invoke('app:clearCache', {})
      .then(() => showToast(t('settings.advanced.cache.cleared')))
      .catch(() => showToast(t('settings.advanced.cache.clearFailed'), 'danger'))
      .finally(() => setClearingCache(false))
  }

  const handleReset = (): void => {
    if (resetting) return
    setResetting(true)
    void invoke('settings:reset', {})
      .then(() => {
        setConfirmingReset(false)
        showToast(t('settings.advanced.reset.done'))
      })
      .catch(() => showToast(t('settings.advanced.reset.failed'), 'danger'))
      .finally(() => setResetting(false))
  }

  return (
    <div className="settings-stack">
      <SettingsCard
        title={t('settings.general.workspace.title')}
        description={t('settings.general.workspace.description')}
      >
        <div
          className="directory-field"
          aria-label={t('settings.general.workspace.directoryLabel')}
        >
          <Icon name="folder" size={17} />
          <input
            type="text"
            value={displayDataRoot(pickedDataRoot ?? settings?.dataRoot)}
            aria-label={t('settings.general.workspace.pathLabel')}
            readOnly
          />
        </div>
        <div className="settings-card__rows">
          <div className="setting-row">
            <span
              className={`setting-row__description${dataRootError === null ? '' : ' settings-feedback--error'}`}
              role={dataRootError === null ? undefined : 'alert'}
            >
              {dataRootError ?? t('settings.general.workspace.moveNotice')}
            </span>
            <button
              type="button"
              className="secondary-button"
              disabled={pickingDataRoot}
              onClick={handlePickDataRoot}
            >
              {t(
                pickingDataRoot
                  ? 'settings.general.workspace.picking'
                  : 'settings.general.workspace.change'
              )}
            </button>
          </div>
        </div>
      </SettingsCard>

      <SettingsCard title={t('settings.advanced.maintenance.title')}>
        <div className="settings-card__rows">
          <div className="setting-row">
            <div className="setting-row__copy">
              <span className="setting-row__label">
                {t('settings.advanced.logs.label')}
              </span>
              <span className="setting-row__description">
                {t('settings.advanced.logs.description')}
              </span>
            </div>
            <button
              type="button"
              className="secondary-button"
              onClick={() => {
                void invoke('app:openLogs', {}).catch(() =>
                  showToast(t('settings.advanced.logs.openFailed'), 'danger')
                )
              }}
            >
              {t('settings.advanced.logs.open')}
            </button>
          </div>
          <div className="setting-row">
            <div className="setting-row__copy">
              <span className="setting-row__label">
                {t('settings.advanced.cache.label')}
              </span>
              <span className="setting-row__description">
                {t('settings.advanced.cache.description')}
              </span>
            </div>
            <button
              type="button"
              className="secondary-button"
              disabled={clearingCache}
              onClick={handleClearCache}
            >
              {t(
                clearingCache
                  ? 'settings.advanced.cache.clearing'
                  : 'settings.advanced.cache.clear'
              )}
            </button>
          </div>
        </div>

        <div className="settings-danger-row settings-advanced-danger-row">
          <div className="setting-row__copy">
            <span className="setting-row__label">
              {confirmingReset
                ? t('settings.advanced.reset.confirm')
                : t('settings.advanced.reset.label')}
            </span>
            {!confirmingReset && (
              <span className="setting-row__description">
                {t('settings.advanced.reset.description')}
              </span>
            )}
          </div>
          {confirmingReset ? (
            <div className="settings-advanced-confirm-actions">
              <button
                type="button"
                className="secondary-button"
                disabled={resetting}
                onClick={() => setConfirmingReset(false)}
              >
                {t('settings.advanced.reset.cancel')}
              </button>
              <button
                type="button"
                className="secondary-button settings-advanced-danger-button"
                disabled={resetting}
                onClick={handleReset}
              >
                {t(
                  resetting
                    ? 'settings.advanced.reset.resetting'
                    : 'settings.advanced.reset.action'
                )}
              </button>
            </div>
          ) : (
            <button
              type="button"
              className="secondary-button settings-advanced-danger-button"
              onClick={() => setConfirmingReset(true)}
            >
              {t('settings.advanced.reset.action')}
            </button>
          )}
        </div>
      </SettingsCard>
    </div>
  )
}
