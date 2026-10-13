import { getSettings } from '../upstream/src/main/settingsStore'
import { parseChord, resolveKeymap, SHORTCUT_SPECS } from '../upstream/src/shared/keymap'
import { passthroughShortcut } from '../upstream/src/main/features/browser/webviewPolicy'
import type { Settings } from '../upstream/src/shared/types/settings'

/** Keep the app's original guest ownership/priority policy; only UIKit key encoding differs. */
export function browserShortcuts(settings: Pick<Settings, 'keybindings' | 'shortcutPriority' | 'locale'>) {
  const keymap = resolveKeymap(settings.keybindings)
  const editing = new Set(['c', 'v', 'x', 'z', 'a'])
  return [...keymap].flatMap(([chord, id]) => {
    const parsed = parseChord(chord)
    if (!parsed?.mod || (!parsed.alt && editing.has(parsed.key))) return []
    const action = passthroughShortcut({ type: 'keyDown', key: parsed.key, meta: true,
      control: false, alt: parsed.alt, shift: parsed.shift }, keymap, settings.shortcutPriority)
    if (action === null) return []
    const spec = SHORTCUT_SPECS.find(spec => spec.id === id)
    return [{ chord, action, label: settings.locale === 'en-US' ? spec?.labelEn ?? id : spec?.labelKo ?? id }]
  })
}

export function installBrowserShortcuts({ handlePrivate }: { handlePrivate: (channel: string, action: () => unknown) => void }) {
  handlePrivate('nativeBrowser:shortcuts', () => browserShortcuts(getSettings()))
}
