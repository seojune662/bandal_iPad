import { useEffect, useState } from 'react'
import type { ScreenPermissionState } from '../../../../../shared/types/screenCapture'
import type { Settings } from '../../../../../shared/types/settings'
import { useT } from '../../../i18n'
import { invoke, onPush } from '../../../lib/ipc'
import { useUiStore } from '../../../stores/uiStore'
import { SettingsCard } from '../primitives'
import './assistant-panel.css'

function useScreenPermission(): {
  isDarwin: boolean
  screenPermission: ScreenPermissionState
} {
  const isDarwin =
    typeof window !== 'undefined' && window.bandal?.platform === 'darwin'
  const [screenPermission, setScreenPermission] =
    useState<ScreenPermissionState>('unknown')

  useEffect(() => {
    if (!isDarwin) return
    let active = true
    let receivedPush = false
    const unsubscribe = onPush('desktopAgent:permission', ({ state }) => {
      receivedPush = true
      if (active) setScreenPermission(state)
    })
    void invoke('desktopAgent:permissionStatus', {}).then(
      ({ state }) => {
        if (active && !receivedPush) setScreenPermission(state)
      },
      () => undefined
    )
    return () => {
      active = false
      unsubscribe()
    }
  }, [isDarwin])

  return { isDarwin, screenPermission }
}

export function DesktopPermissionsSlot(
  _props: { settings: Settings }
): JSX.Element | null {
  const t = useT()
  const { isDarwin, screenPermission } = useScreenPermission()
  if (!isDarwin) return null

  const visibleState =
    screenPermission === 'unsupported' ? 'unknown' : screenPermission
  const openPermissionSettings = (): void => {
    void invoke('desktopAgent:openPermissionSettings', {}).catch(() => undefined)
  }

  return (
    <div className="setting-row">
      <div className="setting-row__copy">
        <div className="setting-row__label-line">
          <span className="setting-row__label">
            {t('settings.ai.permissions.screen.label')}
          </span>
          <span
            className={`status-pill${
              visibleState === 'granted' ? ' status-pill--ready' : ''
            }`}
            data-state={visibleState}
          >
            <span className="status-pill__dot" />
            {t(`settings.ai.permissions.screen.${visibleState}`)}
          </span>
        </div>
        {visibleState === 'denied' && (
          <span className="setting-row__description">
            {t('settings.ai.permissions.screen.restartHint')}
          </span>
        )}
      </div>
      <button
        type="button"
        className="secondary-button"
        onClick={openPermissionSettings}
      >
        {t('settings.ai.permissions.screen.open')}
      </button>
    </div>
  )
}

function ScreenReadingCard({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  return (
    <SettingsCard
      title={t('settings.assistant.screen.title')}
      description={t('settings.assistant.screen.description')}
    >
      <div className="settings-card__rows">
        {settings !== null && <DesktopPermissionsSlot settings={settings} />}
        <div className="settings-assistant-permissions-footer">
          <button
            type="button"
            className="settings-assistant-permissions-button"
            onClick={() => useUiStore.getState().openSettings('permissions')}
          >
            {t('settings.assistant.permissions.open')}
          </button>
        </div>
      </div>
    </SettingsCard>
  )
}

export function AssistantPanel({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  return (
    <div className="settings-stack">
      <ScreenReadingCard settings={settings} />
    </div>
  )
}
