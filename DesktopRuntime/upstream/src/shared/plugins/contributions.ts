import type {
  PluginCommandContribution,
  PluginMenuContribution,
  PluginThemeContribution,
} from '../types/plugin'

// No arbitrary selectors, URLs, or rules can be injected into the app.
export const PLUGIN_THEME_TOKENS = [
  '--bg-app',
  '--bg-surface',
  '--bg-raised',
  '--text-primary',
  '--text-secondary',
  '--text-muted',
  '--accent',
  '--on-accent',
  '--border-subtle',
  '--border-strong',
] as const

function contrast(a: string, b: string): number {
  const luminance = (hex: string): number => {
    const rgb = [1, 3, 5]
      .map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16) / 255)
      .map((value) =>
        value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4,
      )
    return rgb[0]! * 0.2126 + rgb[1]! * 0.7152 + rgb[2]! * 0.0722
  }
  const values = [luminance(a), luminance(b)].sort((x, y) => x - y)
  return (values[1]! + 0.05) / (values[0]! + 0.05)
}

export function parseV2Contributions(
  raw: Record<string, unknown>,
  commands: readonly PluginCommandContribution[],
): {
  menus: PluginMenuContribution[]
  themes: PluginThemeContribution[]
} {
  const menus = raw['menus'] ?? []
  const themes = raw['themes'] ?? []
  if (
    !Array.isArray(menus) ||
    menus.length > 32 ||
    !Array.isArray(themes) ||
    themes.length > 8
  )
    throw new Error('too many menu or theme contributions')
  const resultMenus = menus.map((entry: PluginMenuContribution) => {
    if (
      !entry ||
      !['editor', 'materials'].includes(entry.location) ||
      !commands.some((c) => c.id === entry.command)
    )
      throw new Error(
        'menu must reference a declared command and supported location',
      )
    return { command: entry.command, location: entry.location }
  })
  const ids = new Set<string>()
  const resultThemes = themes.map((entry: PluginThemeContribution) => {
    if (
      !entry ||
      typeof entry.id !== 'string' ||
      !/^[a-z0-9][a-z0-9-]{0,47}$/.test(entry.id) ||
      ids.has(entry.id) ||
      typeof entry.title !== 'string' ||
      !entry.title.trim() ||
      entry.title.length > 80 ||
      !['light', 'dark'].includes(entry.base) ||
      !entry.tokens ||
      typeof entry.tokens !== 'object' ||
      Array.isArray(entry.tokens)
    )
      throw new Error('invalid theme contribution')
    const tokens = Object.fromEntries(
      Object.entries(entry.tokens).map(([name, value]) => {
        if (
          !(PLUGIN_THEME_TOKENS as readonly string[]).includes(name) ||
          typeof value !== 'string' ||
          !/^#[0-9a-f]{6}$/i.test(value)
        )
          throw new Error(
            'theme tokens must be allowed names with six-digit hex colors',
          )
        return [name, value]
      }),
    )
    ids.add(entry.id)
    for (const token of PLUGIN_THEME_TOKENS)
      if (!tokens[token]) throw new Error(`Missing theme token: ${token}`)
    for (const fg of [
      '--text-primary',
      '--text-secondary',
      '--text-muted',
      '--accent',
    ]) {
      for (const bg of ['--bg-app', '--bg-surface', '--bg-raised']) {
        if (contrast(tokens[fg]!, tokens[bg]!) < 4.5)
          throw new Error('Theme text contrast must be at least 4.5:1')
      }
    }
    if (contrast(tokens['--accent']!, tokens['--on-accent']!) < 4.5)
      throw new Error('Theme accent contrast must be at least 4.5:1')
    return { id: entry.id, title: entry.title, base: entry.base, tokens }
  })
  return { menus: resultMenus, themes: resultThemes }
}
