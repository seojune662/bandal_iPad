import { useState } from 'react'
import { showToast } from '../../../app/toast'
import { useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import {
  DEADLINE_LEAD_DAYS,
  type DeadlineLeadDays,
  type NotificationSettings,
  type Settings
} from '../../../../../shared/types/settings'
import { Icon } from '../SettingsIcon'
import { SettingsCard, ToggleRow } from '../primitives'
import './notifications-panel.css'

const LEAD_DAY_OPTIONS: readonly DeadlineLeadDays[] = [
  ...DEADLINE_LEAD_DAYS
].reverse()

type SaveNotifications = (patch: Partial<NotificationSettings>) => void

export function toggleLeadDay(
  current: readonly DeadlineLeadDays[],
  day: DeadlineLeadDays
): readonly DeadlineLeadDays[] {
  const selected = new Set(current)
  if (selected.has(day)) selected.delete(day)
  else selected.add(day)
  return LEAD_DAY_OPTIONS.filter((option) => selected.has(option))
}

function NotificationsLoading(): JSX.Element {
  const t = useT()
  return (
    <div className="settings-stack">
      <div
        className="availability-skeleton"
        aria-label={t('settings.notifications.loading')}
      >
        <span />
        <span />
        <span />
      </div>
    </div>
  )
}

function NotificationStatus({ enabled }: { enabled: boolean }): JSX.Element {
  const t = useT()
  return (
    <div
      className={`inline-notice settings-notifications-notice${
        enabled ? ' settings-notifications-notice--success' : ''
      }`}
      role="status"
    >
      {enabled && <Icon name="check" />}
      <div>
        <strong>
          {t(
            enabled
              ? 'settings.notifications.status.enabled'
              : 'settings.notifications.status.disabled'
          )}
        </strong>
        {enabled && (
          <span>{t('settings.notifications.status.enabledDescription')}</span>
        )}
      </div>
    </div>
  )
}

function DeadlineSettings({
  notifications,
  onSave
}: {
  notifications: NotificationSettings
  onSave: SaveNotifications
}): JSX.Element {
  const t = useT()
  return (
    <>
      <ToggleRow
        label={t('settings.notifications.deadlines.label')}
        description={t('settings.notifications.deadlines.description')}
        checked={notifications.deadlines}
        disabled={!notifications.enabled}
        onChange={(deadlines) => onSave({ deadlines })}
      />
      {notifications.enabled && notifications.deadlines && (
        <div
          className="settings-notifications-lead-days"
          role="group"
          aria-label={t('settings.notifications.deadlines.leadDaysLabel')}
        >
          {LEAD_DAY_OPTIONS.map((day) => (
            <button
              key={day}
              type="button"
              className="settings-notifications-lead-day"
              aria-pressed={notifications.deadlineLeadDays.includes(day)}
              onClick={() =>
                onSave({
                  deadlineLeadDays: toggleLeadDay(
                    notifications.deadlineLeadDays,
                    day
                  )
                })
              }
            >
              {t(`settings.notifications.deadlines.leadDay.${day}`)}
            </button>
          ))}
        </div>
      )}
    </>
  )
}

function AlertsCard({
  notifications,
  onSave
}: {
  notifications: NotificationSettings
  onSave: SaveNotifications
}): JSX.Element {
  const t = useT()
  return (
    <SettingsCard title={t('settings.notifications.alerts.title')}>
      <div className="settings-card__rows">
        <ToggleRow
          label={t('settings.notifications.enabled.label')}
          description={t('settings.notifications.enabled.description')}
          checked={notifications.enabled}
          onChange={(enabled) => onSave({ enabled })}
        />
        <DeadlineSettings notifications={notifications} onSave={onSave} />
        <ToggleRow
          label={t('settings.notifications.agentComplete.label')}
          description={t('settings.notifications.agentComplete.description')}
          checked={notifications.agentComplete}
          disabled={!notifications.enabled}
          onChange={(agentComplete) => onSave({ agentComplete })}
        />
        <ToggleRow
          label={t('settings.notifications.downloads.label')}
          description={t('settings.notifications.downloads.description')}
          checked={notifications.downloads}
          disabled={!notifications.enabled}
          onChange={(downloads) => onSave({ downloads })}
        />
        <ToggleRow
          label={t('settings.notifications.pluginNotices.label')}
          description={t('settings.notifications.pluginNotices.description')}
          checked={notifications.pluginNotices}
          disabled={!notifications.enabled}
          onChange={(pluginNotices) => onSave({ pluginNotices })}
        />
      </div>
    </SettingsCard>
  )
}

function BehaviorCard({
  notifications,
  testing,
  onSave,
  onTest
}: {
  notifications: NotificationSettings
  testing: boolean
  onSave: SaveNotifications
  onTest: () => void
}): JSX.Element {
  const t = useT()
  return (
    <SettingsCard title={t('settings.notifications.behavior.title')}>
      <div className="settings-card__rows">
        <ToggleRow
          label={t('settings.notifications.sound.label')}
          description={t('settings.notifications.sound.description')}
          checked={notifications.sound}
          onChange={(sound) => onSave({ sound })}
        />
        <ToggleRow
          label={t('settings.notifications.suppressWhileFocused.label')}
          description={t(
            'settings.notifications.suppressWhileFocused.description'
          )}
          checked={notifications.suppressWhileFocused}
          onChange={(suppressWhileFocused) => onSave({ suppressWhileFocused })}
        />
      </div>
      <div className="settings-notifications-actions">
        <button
          type="button"
          className="secondary-button"
          disabled={testing}
          onClick={onTest}
        >
          {t(
            testing
              ? 'settings.notifications.test.sending'
              : 'settings.notifications.test.send'
          )}
        </button>
      </div>
    </SettingsCard>
  )
}

export function NotificationsPanel({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  const [testing, setTesting] = useState(false)
  if (settings === null) return <NotificationsLoading />

  const save: SaveNotifications = (patch) => {
    void invoke('settings:set', {
      notifications: patch
    }).catch(() => showToast(t('settings.notifications.saveFailed'), 'danger'))
  }
  const sendTestNotification = (): void => {
    if (testing) return
    setTesting(true)
    void invoke('notifications:test', {})
      .then((result) => {
        if (result.ok) showToast(t('settings.notifications.test.sent'))
        else if (result.reason === 'unsupported') {
          showToast(t('settings.notifications.test.unsupported'), 'danger')
        } else showToast(t('settings.notifications.test.failed'), 'danger')
      })
      .catch(() => showToast(t('settings.notifications.test.failed'), 'danger'))
      .finally(() => setTesting(false))
  }

  return (
    <div className="settings-stack">
      <NotificationStatus enabled={settings.notifications.enabled} />
      <AlertsCard notifications={settings.notifications} onSave={save} />
      <BehaviorCard
        notifications={settings.notifications}
        testing={testing}
        onSave={save}
        onTest={sendTestNotification}
      />
    </div>
  )
}
