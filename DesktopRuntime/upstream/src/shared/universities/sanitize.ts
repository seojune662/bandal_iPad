/**
 * Boundary validation for the university slice of settings.json.
 *
 * settings.json is a plain file on disk: a newer build, a hand edit, or a
 * half-written save must never brick the app. Every field falls back to its
 * default independently, exactly like `sanitizeOnboarding` does.
 */

import {
  DEFAULT_UNIVERSITY_SETTINGS,
  SERVICE_KINDS,
  type ExternalReason,
  type ServiceKind,
  type University,
  type UniversityService,
  type UniversitySettings,
  type VerificationLevel
} from '../types/university'
import { normalizeHttpUrl } from './courseLink'

const EXTERNAL_REASONS: readonly ExternalReason[] = [
  'federated-login',
  'ua-sniffing',
  'native-plugin'
]

const VERIFICATION_LEVELS: readonly VerificationLevel[] = [
  'verified',
  'partial',
  'unverified'
]

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function asNonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

function asStringArray(value: unknown): readonly string[] {
  if (!Array.isArray(value)) return []
  return value.filter((item): item is string => typeof item === 'string')
}

/** A service survives only if id, label and an http(s) url all check out. */
export function sanitizeService(raw: unknown): UniversityService | null {
  if (!isRecord(raw)) return null
  const id = asNonEmptyString(raw['id'])
  const label = asNonEmptyString(raw['label'])
  const url = typeof raw['url'] === 'string' ? normalizeHttpUrl(raw['url']) : null
  if (id === null || label === null || url === null) return null

  const kind = SERVICE_KINDS.includes(raw['kind'] as ServiceKind)
    ? (raw['kind'] as ServiceKind)
    : 'other'
  const verification = VERIFICATION_LEVELS.includes(
    raw['verification'] as VerificationLevel
  )
    ? (raw['verification'] as VerificationLevel)
    : 'unverified'

  const service: UniversityService = {
    id: id.trim(),
    kind,
    label: label.trim(),
    url,
    verification
  }
  if (raw['opensExternally'] === true) {
    service.opensExternally = true
    if (EXTERNAL_REASONS.includes(raw['externalReason'] as ExternalReason)) {
      service.externalReason = raw['externalReason'] as ExternalReason
    }
  }
  if (raw['secondary'] === true) service.secondary = true
  const note = asNonEmptyString(raw['note'])
  if (note !== null) service.note = note
  return service
}

function sanitizeCustomUniversity(raw: unknown): University | null {
  if (!isRecord(raw)) return null
  const id = asNonEmptyString(raw['id'])
  const nameKo = asNonEmptyString(raw['nameKo'])
  if (id === null || nameKo === null) return null

  const services = Array.isArray(raw['services'])
    ? raw['services']
        .map(sanitizeService)
        .filter((service): service is UniversityService => service !== null)
    : []

  const university: University = {
    id: id.trim(),
    nameKo: nameKo.trim(),
    nameEn: typeof raw['nameEn'] === 'string' ? raw['nameEn'] : '',
    aliases: asStringArray(raw['aliases']),
    domain: typeof raw['domain'] === 'string' ? raw['domain'] : '',
    services,
    verifiedAt: typeof raw['verifiedAt'] === 'string' ? raw['verifiedAt'] : ''
  }

  const courseLink = raw['courseLink']
  if (
    isRecord(courseLink) &&
    typeof courseLink['template'] === 'string' &&
    typeof courseLink['idPattern'] === 'string'
  ) {
    university.courseLink = {
      platform:
        courseLink['platform'] === 'canvas' || courseLink['platform'] === 'moodle'
          ? courseLink['platform']
          : 'unknown',
      template: courseLink['template'],
      idPattern: courseLink['idPattern'],
      hint: typeof courseLink['hint'] === 'string' ? courseLink['hint'] : '',
      reliable: courseLink['reliable'] === true
    }
  }
  return university
}

function sanitizeOverrides(raw: unknown): Record<string, boolean> {
  if (!isRecord(raw)) return {}
  const entries = Object.entries(raw).filter(
    (entry): entry is [string, boolean] => typeof entry[1] === 'boolean'
  )
  return Object.fromEntries(entries)
}

/** Nobody has 200 shortcuts; anything past that is a runaway write. */
const MAX_SERVICE_ORDER = 200

/** Trimmed, non-empty, deduplicated string ids — first occurrence wins. */
function sanitizeServiceOrder(raw: unknown): readonly string[] {
  if (!Array.isArray(raw)) return []
  const seen = new Set<string>()
  const ids: string[] = []
  for (const item of raw) {
    if (ids.length >= MAX_SERVICE_ORDER) break
    if (typeof item !== 'string') continue
    const id = item.trim()
    if (id.length === 0 || seen.has(id)) continue
    seen.add(id)
    ids.push(id)
  }
  return ids
}

export function sanitizeUniversitySettings(raw: unknown): UniversitySettings {
  if (!isRecord(raw)) return { ...DEFAULT_UNIVERSITY_SETTINGS }
  return {
    universityId: asNonEmptyString(raw['universityId'])?.trim() ?? null,
    customUniversity: sanitizeCustomUniversity(raw['customUniversity']),
    hiddenServiceIds: asStringArray(raw['hiddenServiceIds']),
    customServices: Array.isArray(raw['customServices'])
      ? raw['customServices']
          .map(sanitizeService)
          .filter((service): service is UniversityService => service !== null)
      : [],
    openExternallyOverrides: sanitizeOverrides(raw['openExternallyOverrides']),
    serviceOrder: sanitizeServiceOrder(raw['serviceOrder']),
    secondaryOverrides: sanitizeOverrides(raw['secondaryOverrides'])
  }
}
