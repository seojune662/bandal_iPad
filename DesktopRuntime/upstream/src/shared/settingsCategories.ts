/**
 * Settings sidebar category ids. Shared so main (app menu, deep links) and
 * the renderer (SettingsApp) name the same panels. Order here is the sidebar
 * order inside each group; groups are listed in SETTINGS_GROUPS order.
 */
export const SETTINGS_GROUPS = [
  'ai',
  'setup',
  'workflows',
  'interface',
  'privacy',
  'advanced',
  'courses',
  'info'
] as const
export type SettingsGroupId = (typeof SETTINGS_GROUPS)[number]

export const SETTINGS_CATEGORIES = [
  { id: 'ai', group: 'ai' },
  { id: 'assistant', group: 'ai' },
  { id: 'account', group: 'setup' },
  { id: 'general', group: 'setup' },
  { id: 'university', group: 'setup' },
  { id: 'packs', group: 'workflows' },
  { id: 'calendar', group: 'workflows' },
  { id: 'browser', group: 'workflows' },
  { id: 'appearance', group: 'interface' },
  { id: 'tabs', group: 'interface' },
  { id: 'widgets', group: 'interface' },
  { id: 'notifications', group: 'interface' },
  { id: 'shortcuts', group: 'interface' },
  { id: 'usage', group: 'interface' },
  { id: 'permissions', group: 'privacy' },
  { id: 'privacy', group: 'privacy' },
  { id: 'advanced', group: 'advanced' },
  { id: 'experimental', group: 'advanced' },
  { id: 'courses', group: 'courses' },
  { id: 'about', group: 'info' }
] as const satisfies readonly { id: string; group: SettingsGroupId }[]

export type SettingsPanelId = (typeof SETTINGS_CATEGORIES)[number]['id']
/** Accept the former Connections destination for older IPC callers. */
export type SettingsCategoryId = SettingsPanelId | 'mcp'

export function isSettingsCategoryId(value: unknown): value is SettingsCategoryId {
  return value === 'mcp' || SETTINGS_CATEGORIES.some((category) => category.id === value)
}

export function normalizeSettingsCategoryId(value: SettingsCategoryId): SettingsPanelId {
  return value === 'mcp' ? 'packs' : value
}
