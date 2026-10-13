import { useState } from 'react'
import type { DiagnosticsBundle } from '../../../../../shared/types/permissions'
import { OPEN_FEEDBACK_EVENT } from '../../help/FeedbackDialog'
import { showToast } from '../../../app/toast'
import { useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import { SettingsCard } from '../primitives'
import { Icon } from '../SettingsIcon'
import './privacy-panel.css'

export function PrivacyPanel(): JSX.Element {
  const t = useT()
  const [creating, setCreating] = useState(false)
  const [bundle, setBundle] = useState<DiagnosticsBundle | null>(null)

  const createDiagnostics = (): void => {
    if (creating) return
    setCreating(true)
    void invoke('app:diagnostics', {})
      .then(setBundle)
      .catch(() => showToast(t('settings.privacy.diagnostics.failed'), 'danger'))
      .finally(() => setCreating(false))
  }

  return (
    <div className="settings-stack">
      <SettingsCard title={t('settings.privacy.data.title')}>
        <div className="settings-privacy-statement">
          <strong>{t('settings.privacy.data.promise')}</strong>
          <p>{t('settings.privacy.data.description')}</p>
        </div>
      </SettingsCard>

      <SettingsCard title={t('settings.privacy.diagnostics.title')}>
        <div className="settings-card__rows">
          <div className="setting-row">
            <div className="setting-row__copy">
              <span className="setting-row__label">
                {t('settings.privacy.diagnostics.label')}
              </span>
              <span className="setting-row__description">
                {t('settings.privacy.diagnostics.description')}
              </span>
            </div>
            <button
              type="button"
              className="secondary-button"
              disabled={creating}
              onClick={createDiagnostics}
            >
              {t(
                creating
                  ? 'settings.privacy.diagnostics.creating'
                  : 'settings.privacy.diagnostics.create'
              )}
            </button>
          </div>
        </div>
        {bundle !== null && (
          <div className="settings-privacy-diagnostics" aria-live="polite">
            <h3>{t('settings.privacy.diagnostics.contents')}</h3>
            <ul>
              {bundle.contents.map((item, index) => (
                <li key={`${index}-${item}`}>{item}</li>
              ))}
            </ul>
            <div
              className="directory-field settings-privacy-diagnostics__path"
              aria-label={t('settings.privacy.diagnostics.pathLabel')}
            >
              <Icon name="folder" size={17} />
              <input
                type="text"
                value={bundle.path}
                aria-label={t('settings.privacy.diagnostics.pathLabel')}
                readOnly
              />
              <span className="badge">
                {t('settings.privacy.diagnostics.revealed')}
              </span>
            </div>
          </div>
        )}
      </SettingsCard>

      <SettingsCard title={t('settings.privacy.feedback.title')}>
        <div className="settings-card__rows">
          <div className="setting-row">
            <div className="setting-row__copy">
              <span className="setting-row__label">
                {t('settings.privacy.feedback.label')}
              </span>
              <span className="setting-row__description">
                {t('settings.privacy.feedback.description')}
              </span>
            </div>
            <button
              type="button"
              className="secondary-button"
              onClick={() =>
                window.dispatchEvent(new CustomEvent(OPEN_FEEDBACK_EVENT))
              }
            >
              {t('settings.privacy.feedback.send')}
            </button>
          </div>
        </div>
      </SettingsCard>
    </div>
  )
}
