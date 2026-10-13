import {
  SHORTCUT_SPECS,
  formatChord,
  parseChord,
  resolveKeymap,
  type ShortcutActionId
} from '../../../../../shared/keymap'

export type KeybindingOverrides = Record<string, string | null>

const CUSTOMIZABLE_ACTIONS = new Set<string>(
  SHORTCUT_SPECS.filter((spec) => spec.customizable).map((spec) => spec.id)
)

/** Effective action -> chord view after the shared winner rules are applied. */
export function effectiveChords(
  overrides: KeybindingOverrides
): ReadonlyMap<ShortcutActionId, string> {
  const result = new Map<ShortcutActionId, string>()
  for (const [chord, action] of resolveKeymap(overrides)) {
    result.set(action, chord)
  }
  return result
}

/** The action that would be displaced by assigning `chord`, if any. */
export function conflictingAction(
  overrides: KeybindingOverrides,
  actionId: ShortcutActionId,
  chord: string
): ShortcutActionId | null {
  const owner = resolveKeymap(overrides).get(chord)
  return owner === undefined || owner === actionId ? null : owner
}

/** Assigns a chord and explicitly unbinds its previous owner. */
export function assignChord(
  overrides: KeybindingOverrides,
  actionId: ShortcutActionId,
  chord: string,
  displaced: ShortcutActionId | null
): KeybindingOverrides {
  return {
    ...overrides,
    ...(displaced === null ? {} : { [displaced]: null }),
    [actionId]: chord
  }
}

/** Removes an override so the shared default becomes authoritative again. */
export function restoreDefault(
  overrides: KeybindingOverrides,
  actionId: ShortcutActionId,
  displaced: ShortcutActionId | null
): KeybindingOverrides {
  const next: KeybindingOverrides = {
    ...overrides,
    ...(displaced === null ? {} : { [displaced]: null })
  }
  delete next[actionId]
  return next
}

/** Splits a formatted chord into visible keycaps without losing the `+` key. */
export function formattedChordParts(
  chord: string | undefined,
  platform: string
): readonly string[] {
  if (chord === undefined) return ['—']
  const parsed = parseChord(chord)
  if (parsed === null) return ['—']
  const formatted = formatChord(parsed, platform)
  const key = formatChord(
    { ...parsed, mod: false, alt: false, shift: false },
    platform
  )
  const modifierText = formatted.slice(0, formatted.length - key.length)
  const isMac = platform === 'darwin' || platform === 'mac' || platform === 'macos'
  const modifiers = isMac
    ? [...modifierText]
    : modifierText.split('+').filter((part) => part.length > 0)
  return [...modifiers, key]
}

/** Keeps only known, customizable actions with null or parseable chords. */
export function importedKeybindings(value: unknown): KeybindingOverrides | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return null
  }
  const result: KeybindingOverrides = {}
  for (const [actionId, chord] of Object.entries(value)) {
    if (!CUSTOMIZABLE_ACTIONS.has(actionId)) continue
    if (
      chord === null ||
      (typeof chord === 'string' && parseChord(chord) !== null)
    ) {
      result[actionId] = chord
    }
  }
  return result
}
