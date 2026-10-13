/**
 * Pure settings sanitizers, split from settingsStore.ts so tests can import
 * them without pulling in the electron runtime (`app`, `BrowserWindow`).
 * settingsStore supplies the environment-dependent defaults.
 */

import { sanitizeTabPreferences } from '../shared/tabPreferences'
import { isPaletteId, normalizeThemePreference } from '../shared/theme'
import { isSearchEngineId } from '../shared/search'
import { parseChord, SHORTCUT_SPECS } from '../shared/keymap'
import { sanitizeUniversitySettings } from '../shared/universities/sanitize'
import { isZoomLevel } from '../shared/browserZoom'
import { isAbsolute, normalize } from 'node:path'
import { isAgentProvider } from '../shared/types/agent-events'
import {
  CATALOG_SOURCES_MAX,
  OFFICIAL_CATALOG_URL
} from '../shared/types/pluginCatalog'
import {
  DEFAULT_BROWSER_SETTINGS,
  DEFAULT_EXPERIMENTAL,
  DEFAULT_NOTIFICATIONS,
  EXPERIMENTAL_FLAGS,
  isDeadlineLeadDays,
  isLinkRouting,
  isPopupBehavior,
  isTrackingProtection,
  isShortcutPriority,
  DEFAULT_MILESTONES,
  DEFAULT_ONBOARDING,
  DEFAULT_TUTORIAL,
  DEFAULT_WIDGETS,
  isWidgetId,
  isDensity,
  isEditorFont,
  isFontScale
} from '../shared/types/settings'
import type {
  BrowserSettings,
  DeadlineLeadDays,
  ExperimentalSettings,
  NotificationSettings,
  Milestones,
  OnboardingState,
  Settings,
  TutorialState,
  WidgetSettings
} from '../shared/types/settings'

const CUSTOMIZABLE_SHORTCUT_IDS: ReadonlySet<string> = new Set(
  SHORTCUT_SPECS.filter((spec) => spec.customizable).map((spec) => spec.id)
)

/** Accept old palette settings for compatibility without applying them. */
function isPalette(value: unknown): value is Settings['palette'] {
  return isPaletteId(value)
}

/** Only renderer locales shipped by this build are accepted from disk/IPC. */
function isLocale(value: unknown): value is Settings['locale'] {
  return value === 'ko-KR' || value === 'en-US'
}

/** [M6-A] Validates the persisted onboarding record, key by key. */
export function sanitizeOnboarding(raw: unknown): OnboardingState {
  if (typeof raw !== 'object' || raw === null) {
    return { ...DEFAULT_ONBOARDING }
  }
  const record = raw as Record<string, unknown>
  return {
    flowVersion:
      typeof record.flowVersion === 'number' &&
      Number.isInteger(record.flowVersion) &&
      record.flowVersion >= 0
        ? record.flowVersion
        : DEFAULT_ONBOARDING.flowVersion,
    closedAt: typeof record.closedAt === 'string' ? record.closedAt : null,
    lastCompletedStep:
      typeof record.lastCompletedStep === 'number' &&
      Number.isInteger(record.lastCompletedStep) &&
      record.lastCompletedStep >= 0
        ? record.lastCompletedStep
        : DEFAULT_ONBOARDING.lastCompletedStep
  }
}

export function sanitizeTutorial(raw: unknown): TutorialState {
  if (typeof raw !== 'object' || raw === null) {
    return { ...DEFAULT_TUTORIAL }
  }
  const record = raw as Record<string, unknown>
  return {
    seenVersion:
      typeof record.seenVersion === 'number' &&
      Number.isInteger(record.seenVersion) &&
      record.seenVersion >= 0
        ? record.seenVersion
        : DEFAULT_TUTORIAL.seenVersion,
    activeCourseId:
      typeof record.activeCourseId === 'string' && record.activeCourseId !== ''
        ? record.activeCourseId
        : null
  }
}

export function sanitizeKeybindings(
  raw: unknown
): Record<string, string | null> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return {}
  const sanitized: Record<string, string | null> = {}
  for (const [id, value] of Object.entries(raw)) {
    if (!CUSTOMIZABLE_SHORTCUT_IDS.has(id)) continue
    if (value === null) {
      sanitized[id] = null
    } else if (typeof value === 'string' && parseChord(value) !== null) {
      sanitized[id] = value
    }
  }
  return sanitized
}

export function sanitizeMilestones(raw: unknown): Milestones {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return { ...DEFAULT_MILESTONES }
  }
  const record = raw as Record<string, unknown>
  return {
    pipUsedAt:
      typeof record.pipUsedAt === 'string' ? record.pipUsedAt : null
  }
}

function bool(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback
}

/** Keeps only `<taskId>:<days>` → ISO string entries; anything else is noise. */
function sanitizeSentLedger(raw: unknown): Record<string, string> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return {}
  const ledger: Record<string, string> = {}
  for (const [key, value] of Object.entries(raw)) {
    if (
      typeof value === 'string' &&
      key.length <= 128 &&
      /^[^:]+:(1|3|7)$/.test(key) &&
      !Number.isNaN(Date.parse(value))
    ) {
      ledger[key] = value
    }
  }
  return ledger
}

export function sanitizeNotifications(raw: unknown): NotificationSettings {
  const d = DEFAULT_NOTIFICATIONS
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return { ...d, deadlineLeadDays: [...d.deadlineLeadDays], sent: {} }
  }
  const r = raw as Record<string, unknown>
  const leadDays = Array.isArray(r.deadlineLeadDays)
    ? [...new Set(r.deadlineLeadDays.filter(isDeadlineLeadDays))].sort(
        (a, b) => b - a
      )
    : [...d.deadlineLeadDays]
  return {
    enabled: bool(r.enabled, d.enabled),
    deadlines: bool(r.deadlines, d.deadlines),
    deadlineLeadDays: leadDays as DeadlineLeadDays[],
    agentComplete: bool(r.agentComplete, d.agentComplete),
    downloads: bool(r.downloads, d.downloads),
    pluginNotices: bool(r.pluginNotices, d.pluginNotices),
    sound: bool(r.sound, d.sound),
    suppressWhileFocused: bool(r.suppressWhileFocused, d.suppressWhileFocused),
    sent: sanitizeSentLedger(r.sent)
  }
}

/** '' (new-tab page) or an absolute http(s) URL up to 2048 chars. */
export function sanitizeHomePage(raw: unknown): string {
  if (typeof raw !== 'string' || raw === '' || raw.length > 2048) return ''
  try {
    const url = new URL(raw)
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.href : ''
  } catch {
    return ''
  }
}

export function sanitizeBrowserSettings(raw: unknown): BrowserSettings {
  const d = DEFAULT_BROWSER_SETTINGS
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return { ...d }
  }
  const r = raw as Record<string, unknown>
  const extensions = Array.isArray(r.extensions)
    ? r.extensions.flatMap((entry) => {
        if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) return []
        const value = entry as Record<string, unknown>
        if (
          typeof value.path !== 'string' ||
          value.path.length === 0 ||
          value.path.length > 4096 ||
          !isAbsolute(value.path)
        ) return []
        return [{ path: normalize(value.path), enabled: bool(value.enabled, true) }]
      }).filter((entry, index, all) =>
        all.findIndex((candidate) => candidate.path === entry.path) === index
      ).slice(0, 20)
    : []
  return {
    swipeNavigation: bool(r.swipeNavigation, d.swipeNavigation),
    agentUse: bool(r.agentUse, d.agentUse),
    homePage: sanitizeHomePage(r.homePage),
    defaultZoomLevel: isZoomLevel(r.defaultZoomLevel)
      ? r.defaultZoomLevel
      : d.defaultZoomLevel,
    linkRouting: isLinkRouting(r.linkRouting) ? r.linkRouting : d.linkRouting,
    popupBehavior: isPopupBehavior(r.popupBehavior)
      ? r.popupBehavior
      : d.popupBehavior,
    trackingProtection: isTrackingProtection(r.trackingProtection)
      ? r.trackingProtection
      : d.trackingProtection,
    doNotTrack: bool(r.doNotTrack, d.doNotTrack),
    extensions
  }
}

/** Unknown (graduated) flags are dropped; missing ones take the default. */
export function sanitizeExperimental(raw: unknown): ExperimentalSettings {
  const record =
    typeof raw === 'object' && raw !== null && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {}
  const result = { ...DEFAULT_EXPERIMENTAL }
  for (const flag of EXPERIMENTAL_FLAGS) {
    result[flag] = bool(record[flag], DEFAULT_EXPERIMENTAL[flag])
  }
  return result
}

export function sanitizeWidgets(raw: unknown): WidgetSettings {
  const d = DEFAULT_WIDGETS
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return { ...d, enabled: [...d.enabled] }
  }
  const r = raw as Record<string, unknown>
  const enabled = Array.isArray(r.enabled)
    ? [...new Set(r.enabled.filter(isWidgetId))]
    : [...d.enabled]
  const active = isWidgetId(r.active) && enabled.includes(r.active)
    ? r.active
    : (enabled[0] ?? d.active)
  const ratio =
    typeof r.heightRatio === 'number' && Number.isFinite(r.heightRatio)
      ? Math.min(0.65, Math.max(0.25, r.heightRatio))
      : d.heightRatio
  return {
    enabled,
    collapsed: Array.isArray(r.collapsed) ? [...new Set(r.collapsed.filter(isWidgetId))] : [],
    active,
    heightRatio: ratio,
    mailServiceId:
      typeof r.mailServiceId === 'string' && r.mailServiceId.length <= 128
        ? r.mailServiceId
        : null,
    mailUrl: sanitizeHomePage(r.mailUrl),
    lastMailOpenedAt:
      typeof r.lastMailOpenedAt === 'string' &&
      !Number.isNaN(Date.parse(r.lastMailOpenedAt))
        ? r.lastMailOpenedAt
        : null
  }
}

/** Distinct absolute https index URLs, official one excluded, capped. */
export function sanitizePluginSources(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  const sources: string[] = []
  for (const value of raw) {
    if (typeof value !== 'string' || value.length > 2048) continue
    let href: string
    try {
      const url = new URL(value)
      if (url.protocol !== 'https:') continue
      href = url.href
    } catch {
      continue
    }
    if (href === OFFICIAL_CATALOG_URL || sources.includes(href)) continue
    sources.push(href)
    if (sources.length >= CATALOG_SOURCES_MAX) break
  }
  return sources
}

/**
 * Validates unknown JSON into Settings, falling back to `defaults` per key.
 * `defaults` carries the environment-dependent values (dataRoot).
 */
export function sanitizeSettings(raw: unknown, defaults: Settings): Settings {
  if (typeof raw !== 'object' || raw === null) {
    return defaults
  }
  const record = raw as Record<string, unknown>
  return {
    theme: normalizeThemePreference(record.theme, defaults.theme),
    palette: isPalette(record.palette) ? record.palette : defaults.palette,
    pluginTheme: typeof record.pluginTheme === 'string' && record.pluginTheme.length <= 180 && /^[a-z0-9.-]+:[a-z0-9-]+$/.test(record.pluginTheme) ? record.pluginTheme : null,
    // Only the registered steps: an arbitrary multiplier from disk (1.05, '1',
    // NaN) would produce a font-size the picker cannot show as selected.
    fontScale: isFontScale(record.fontScale)
      ? record.fontScale
      : defaults.fontScale,
    editorFont: isEditorFont(record.editorFont)
      ? record.editorFont
      : defaults.editorFont,
    density: isDensity(record.density) ? record.density : defaults.density,
    browserSearchEngine: isSearchEngineId(record.browserSearchEngine)
      ? record.browserSearchEngine
      : defaults.browserSearchEngine,
    agentProvider: isAgentProvider(record.agentProvider)
      ? record.agentProvider
      : defaults.agentProvider,
    dataRoot:
      typeof record.dataRoot === 'string' && record.dataRoot.length > 0
        ? record.dataRoot
        : defaults.dataRoot,
    locale: isLocale(record.locale) ? record.locale : defaults.locale,
    onboarding: sanitizeOnboarding(record.onboarding),
    tutorial: sanitizeTutorial(record.tutorial),
    keybindings: sanitizeKeybindings(record.keybindings),
    milestones: sanitizeMilestones(record.milestones),
    university: sanitizeUniversitySettings(record.university),
    openAdjacentTab:
      typeof record.openAdjacentTab === 'boolean'
        ? record.openAdjacentTab
        : defaults.openAdjacentTab,
    restoreLastCourse:
      typeof record.restoreLastCourse === 'boolean'
        ? record.restoreLastCourse
        : defaults.restoreLastCourse,
    lastActiveCourseId:
      typeof record.lastActiveCourseId === 'string' &&
      record.lastActiveCourseId !== ''
        ? record.lastActiveCourseId
        : null,
    notifications: sanitizeNotifications(record.notifications),
    browser: sanitizeBrowserSettings(record.browser),
    shortcutPriority: isShortcutPriority(record.shortcutPriority)
      ? record.shortcutPriority
      : defaults.shortcutPriority,
    experimental: sanitizeExperimental(record.experimental),
    widgets: sanitizeWidgets(record.widgets),
    tabs: sanitizeTabPreferences(record.tabs),
    pluginSources: sanitizePluginSources(record.pluginSources)
  }
}
