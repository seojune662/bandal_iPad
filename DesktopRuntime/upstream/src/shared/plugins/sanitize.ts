/**
 * Manifest sanitizer for third-party extensions. Pure (no node/electron
 * imports) so main and the renderer's install preview share one truth.
 *
 * Contract: `manifest === null` means "reject the install"; every recoverable
 * problem is fixed in place (truncate, drop, default) and reported through
 * `warnings` in the same style as `workflowPacks/sanitize.ts`.
 */

import {
  PLUGIN_CONTRIBUTION_ID_PATTERN,
  PLUGIN_ID_MAX_LENGTH,
  PLUGIN_ID_PATTERN,
  PLUGIN_LIMITS,
  PLUGIN_MANIFEST_VERSION,
  PLUGIN_NET_PERMISSION_PREFIX,
  type PluginCommandContribution,
  type PluginManifest,
  type PluginPanelContribution,
  type PluginPermission
} from '../types/plugin'
import { isStaticPermission } from './permissions'
import { isValidSemver } from './semver'
import { parseSettingsSchema } from './configuration'
import { parseV2Contributions } from './contributions'

export interface SanitizedPluginManifest {
  manifest: PluginManifest | null
  warnings: string[]
}

const DEFAULT_MAIN = 'main.js'
const STYLES_FILE = 'styles.css'
const IGNORED_MANIFEST_KEYS = ['menus', 'themes'] as const

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function truncateCharacters(
  value: string,
  maxLength: number
): { value: string; truncated: boolean } {
  const characters = Array.from(value)
  if (characters.length <= maxLength) return { value, truncated: false }
  return { value: characters.slice(0, maxLength).join(''), truncated: true }
}

function cappedString(
  raw: unknown,
  field: string,
  maxLength: number,
  warnings: string[],
  fallback: string
): string {
  if (typeof raw !== 'string' || raw.trim().length === 0) {
    if (raw !== undefined) {
      warnings.push(`${field} must be a non-empty string; using "${fallback}".`)
    }
    return fallback
  }
  const trimmed = raw.trim()
  const { value, truncated } = truncateCharacters(trimmed, maxLength)
  if (truncated) {
    warnings.push(`${field} was truncated to ${maxLength} characters.`)
  }
  return value
}

/** Single path segment: no separators, no `.`/`..`, no NUL, not empty. */
export function isSafeSegment(value: string): boolean {
  return (
    value !== '' &&
    value !== '.' &&
    value !== '..' &&
    !value.includes('/') &&
    !value.includes('\\') &&
    !value.includes('\u0000')
  )
}

/** Relative path under `ui/`: every segment safe, no leading slash. */
export function isSafeRelativeEntry(value: string): boolean {
  if (value === '' || value.startsWith('/') || value.includes('\\')) return false
  if (value.includes('\u0000')) return false
  return value.split('/').every(isSafeSegment)
}

/** Lower-cased exact hostname or null. Round-trips through `URL`. */
export function normalizeNetHost(raw: string): string | null {
  const host = raw.trim().toLowerCase()
  if (host === '' || host.includes('/') || host.includes(':')) return null
  if (host.includes('*') || host.includes('@') || /\s/.test(host)) return null
  let parsed: URL
  try {
    parsed = new URL(`https://${host}`)
  } catch {
    return null
  }
  if (parsed.hostname !== host || parsed.port !== '') return null
  if (parsed.pathname !== '/' || parsed.search !== '' || parsed.hash !== '') {
    return null
  }
  if (parsed.username !== '' || parsed.password !== '') return null
  return host
}

function sanitizePermissions(
  raw: unknown,
  warnings: string[]
): PluginPermission[] {
  if (raw === undefined) return []
  if (!Array.isArray(raw)) {
    warnings.push('permissions must be an array; ignoring it.')
    return []
  }
  const seen = new Set<string>()
  const result: PluginPermission[] = []
  for (const entry of raw) {
    if (typeof entry !== 'string') {
      warnings.push('permissions entries must be strings; dropped one.')
      continue
    }
    let permission: PluginPermission | null = null
    if (isStaticPermission(entry)) {
      permission = entry
    } else if (entry.startsWith(PLUGIN_NET_PERMISSION_PREFIX)) {
      const host = normalizeNetHost(
        entry.slice(PLUGIN_NET_PERMISSION_PREFIX.length)
      )
      if (host === null) {
        warnings.push(
          `permission "${entry}" is not a valid net:<hostname> grant; dropped.`
        )
        continue
      }
      permission = `${PLUGIN_NET_PERMISSION_PREFIX}${host}`
    } else {
      warnings.push(`unknown permission "${entry}" dropped.`)
      continue
    }
    if (seen.has(permission)) continue
    seen.add(permission)
    result.push(permission)
  }
  return result
}

function sanitizeContributionId(
  raw: unknown,
  kind: 'command' | 'panel',
  warnings: string[]
): string | null {
  if (typeof raw !== 'string' || !PLUGIN_CONTRIBUTION_ID_PATTERN.test(raw)) {
    warnings.push(`${kind} id ${JSON.stringify(raw)} is invalid; dropped.`)
    return null
  }
  return raw
}

function sanitizeCommands(
  raw: unknown,
  warnings: string[]
): PluginCommandContribution[] {
  if (raw === undefined) return []
  if (!Array.isArray(raw)) {
    warnings.push('contributes.commands must be an array; ignoring it.')
    return []
  }
  const seen = new Set<string>()
  const result: PluginCommandContribution[] = []
  for (const entry of raw) {
    if (result.length >= PLUGIN_LIMITS.commands) {
      warnings.push(
        `contributes.commands is capped at ${PLUGIN_LIMITS.commands}; extra dropped.`
      )
      break
    }
    if (!isRecord(entry)) {
      warnings.push('contributes.commands entries must be objects; dropped one.')
      continue
    }
    const id = sanitizeContributionId(entry['id'], 'command', warnings)
    if (id === null) continue
    if (seen.has(id)) {
      warnings.push(`duplicate command id "${id}" dropped.`)
      continue
    }
    seen.add(id)
    const title = cappedString(
      entry['title'],
      `command "${id}" title`,
      PLUGIN_LIMITS.nameLength,
      warnings,
      id
    )
    const rawChord = entry['defaultChord']
    let defaultChord: string | null = null
    if (typeof rawChord === 'string' && rawChord.trim() !== '') {
      defaultChord = rawChord.trim().toLowerCase()
    } else if (rawChord !== undefined && rawChord !== null) {
      warnings.push(`command "${id}" defaultChord must be a string or null.`)
    }
    result.push({ id, title, defaultChord })
  }
  return result
}

function sanitizePanels(
  raw: unknown,
  warnings: string[]
): PluginPanelContribution[] {
  if (raw === undefined) return []
  if (!Array.isArray(raw)) {
    warnings.push('contributes.panels must be an array; ignoring it.')
    return []
  }
  const seen = new Set<string>()
  const result: PluginPanelContribution[] = []
  for (const entry of raw) {
    if (result.length >= PLUGIN_LIMITS.panels) {
      warnings.push(
        `contributes.panels is capped at ${PLUGIN_LIMITS.panels}; extra dropped.`
      )
      break
    }
    if (!isRecord(entry)) {
      warnings.push('contributes.panels entries must be objects; dropped one.')
      continue
    }
    const id = sanitizeContributionId(entry['id'], 'panel', warnings)
    if (id === null) continue
    if (seen.has(id)) {
      warnings.push(`duplicate panel id "${id}" dropped.`)
      continue
    }
    const entryPath = entry['entry']
    if (typeof entryPath !== 'string' || !isSafeRelativeEntry(entryPath)) {
      warnings.push(`panel "${id}" entry must be a relative path under ui/; dropped.`)
      continue
    }
    seen.add(id)
    const title = cappedString(
      entry['title'],
      `panel "${id}" title`,
      PLUGIN_LIMITS.nameLength,
      warnings,
      id
    )
    result.push({ id, title, entry: entryPath })
  }
  return result
}

export function sanitizePluginManifest(raw: unknown): SanitizedPluginManifest {
  const warnings: string[] = []
  if (!isRecord(raw)) {
    return { manifest: null, warnings: ['manifest must be a JSON object.'] }
  }
  if (raw['manifestVersion'] !== 1 && raw['manifestVersion'] !== PLUGIN_MANIFEST_VERSION) {
    return {
      manifest: null,
      warnings: [`manifestVersion must be 1 or ${PLUGIN_MANIFEST_VERSION}.`]
    }
  }

  const id = raw['id']
  if (
    typeof id !== 'string' ||
    id.length > PLUGIN_ID_MAX_LENGTH ||
    !PLUGIN_ID_PATTERN.test(id)
  ) {
    return {
      manifest: null,
      warnings: [
        `id must match ${String(PLUGIN_ID_PATTERN)} and be at most ${PLUGIN_ID_MAX_LENGTH} characters.`
      ]
    }
  }

  const version = raw['version']
  if (!isValidSemver(version)) {
    return { manifest: null, warnings: ['version must be a semver string.'] }
  }
  const minAppVersion = raw['minAppVersion']
  if (!isValidSemver(minAppVersion)) {
    return {
      manifest: null,
      warnings: ['minAppVersion must be a semver string.']
    }
  }

  const name = cappedString(
    raw['name'],
    'name',
    PLUGIN_LIMITS.nameLength,
    warnings,
    id
  )
  const description = cappedString(
    raw['description'],
    'description',
    PLUGIN_LIMITS.descriptionLength,
    warnings,
    ''
  )
  const author = cappedString(
    raw['author'],
    'author',
    PLUGIN_LIMITS.authorLength,
    warnings,
    ''
  )

  let main = DEFAULT_MAIN
  const rawMain = raw['main']
  if (rawMain !== undefined) {
    if (typeof rawMain !== 'string' || !isSafeSegment(rawMain)) {
      return {
        manifest: null,
        warnings: ['main must be a single file name inside the plugin folder.']
      }
    }
    main = rawMain
  }

  const permissions = sanitizePermissions(raw['permissions'], warnings)

  const contributesRaw = raw['contributes']
  let commands: PluginCommandContribution[] = []
  let panels: PluginPanelContribution[] = []
  if (contributesRaw !== undefined) {
    if (!isRecord(contributesRaw)) {
      warnings.push('contributes must be an object; ignoring it.')
    } else {
      commands = sanitizeCommands(contributesRaw['commands'], warnings)
      panels = sanitizePanels(contributesRaw['panels'], warnings)
    }
  }

  let styles: 'styles.css' | null = null
  const rawStyles = raw['styles']
  if (rawStyles === STYLES_FILE) {
    styles = STYLES_FILE
  } else if (rawStyles !== undefined && rawStyles !== null) {
    warnings.push(`styles must be exactly "${STYLES_FILE}" or null; ignored.`)
  }

  for (const key of IGNORED_MANIFEST_KEYS) {
    if (raw[key] !== undefined) {
      warnings.push(`${key} is not supported in manifestVersion 1; ignored.`)
    }
  }

  let additions: Partial<PluginManifest['contributes']> = {}
  if (raw['manifestVersion'] === 2 && isRecord(contributesRaw)) {
    try {
      additions = { settings: parseSettingsSchema(contributesRaw['settings']), ...parseV2Contributions(contributesRaw, commands) }
    } catch (error) {
      return { manifest: null, warnings: [error instanceof Error ? error.message : 'invalid contributions'] }
    }
  }
  return {
    manifest: {
      manifestVersion: raw['manifestVersion'],
      id,
      name,
      version: version.trim(),
      minAppVersion: minAppVersion.trim(),
      description,
      author,
      main,
      permissions,
      contributes: { commands, panels, ...additions },
      styles
    },
    warnings
  }
}
