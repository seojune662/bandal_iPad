import {
  EXPERIMENTAL_FLAGS,
  type ExperimentalFlag,
  type Settings
} from '../../../../../shared/types/settings'
import type { MessageKey } from '../../../i18n/messages/ko-KR'
import { useT } from '../../../i18n'
import { savePreference } from '../savePreference'
import { SettingsCard, ToggleRow } from '../primitives'
import './advanced-panel.css'

const FLAG_MESSAGES: Record<
  ExperimentalFlag,
  { label: MessageKey; description: MessageKey }
> = {
  extensionRuntime: {
    label: 'settings.experimental.extensionRuntime.label',
    description: 'settings.experimental.extensionRuntime.description'
  }
}

export function ExperimentalPanel({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()

  return (
    <div className="settings-stack">
      <SettingsCard description={t('settings.experimental.description')}>
        <div className="settings-card__rows">
          {EXPERIMENTAL_FLAGS.map((flag) => (
            <ToggleRow
              key={flag}
              label={t(FLAG_MESSAGES[flag].label)}
              description={t(FLAG_MESSAGES[flag].description)}
              checked={settings?.experimental[flag] ?? false}
              disabled={settings === null}
              onChange={(next) => {
                if (settings === null) return
                void savePreference({ experimental: { [flag]: next } })
              }}
            />
          ))}
        </div>
      </SettingsCard>
    </div>
  )
}
