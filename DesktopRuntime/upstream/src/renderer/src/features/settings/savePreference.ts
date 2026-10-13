import type { Settings, SettingsPatch } from '../../../../shared/types/settings'
import { showToast } from '../../app/toast'
import { getLocale } from '../../i18n/localeStore'
import { invoke } from '../../lib/ipc'

/** For immediate controls; committed state arrives through settings:changed. */
export async function savePreference(
  patch: SettingsPatch,
): Promise<Settings | null> {
  try {
    return await invoke('settings:set', patch)
  } catch {
    showToast(
      getLocale() === 'ko-KR'
        ? '설정을 저장하지 못했습니다. 다시 시도해 주세요.'
        : 'Could not save settings. Please try again.',
      'danger',
    )
    return null
  }
}
