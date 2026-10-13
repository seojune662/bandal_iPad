import { applyTheme } from '../features/settings/settingsTheme'
import { ensureSettingsLoaded } from '../stores/settingsSnapshot'
import { DEFAULT_SETTINGS } from '../../../shared/types/settings'

export async function bootstrapAppearance(): Promise<void> {
  document.documentElement.dataset['platform'] =
    window.bandal?.platform ?? 'unknown'
  try {
    applyTheme(await ensureSettingsLoaded())
  } catch (error) {
    applyTheme(DEFAULT_SETTINGS)
    console.error('[Bandal] Initial appearance unavailable', error)
  }
}
