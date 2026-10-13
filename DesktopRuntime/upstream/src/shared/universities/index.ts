/**
 * The university preset catalog — a static, app-versioned module.
 *
 * Not a DB table on purpose (docs/university-sites.md §6): university URLs
 * rot on a 1–2 year cycle (SNU eTL moved Moodle → Canvas, 고려대 dropped
 * Blackboard), and shipping a fixed URL with the app beats migrating rows.
 * User-owned data (chosen school, hidden services, custom entries, per-course
 * links) lives in settings / SQLite and always wins.
 *
 * Never change a `University.id` or a `UniversityService.id` — settings
 * reference them by string. Fix the URL, keep the id.
 */

import type {
  University,
  UniversityService,
  UniversitySettings
} from '../types/university'
import { COMMON_SERVICES } from './common'
import { applyServiceOrder } from './order'
import { REGIONAL_UNIVERSITIES } from './regional'
import { SEOUL_PRIVATE_UNIVERSITIES } from './seoulPrivate'
import { SNU, VERIFIED_AT } from './snu'

export { VERIFIED_AT as CATALOG_VERIFIED_AT }
export { COMMON_SERVICES } from './common'
export {
  moveServiceBefore,
  moveServiceBy,
  moveServiceToEnd
} from './order'
export * from './courseLink'

/** 18 schools verified on 2026-08-05, 서울대 first (the reference entry). */
export const UNIVERSITIES: readonly University[] = [
  SNU,
  ...SEOUL_PRIVATE_UNIVERSITIES,
  ...REGIONAL_UNIVERSITIES
]

/** Prefix that marks a user-defined school (`custom:<uuid>`). */
export const CUSTOM_UNIVERSITY_PREFIX = 'custom:'

export function isCustomUniversityId(id: string | null): boolean {
  return id !== null && id.startsWith(CUSTOM_UNIVERSITY_PREFIX)
}

export function findUniversity(id: string | null | undefined): University | null {
  if (id === null || id === undefined) return null
  return UNIVERSITIES.find((university) => university.id === id) ?? null
}

/**
 * The school currently in effect: a preset, or the user's custom definition.
 * Returns null while onboarding has not asked yet.
 */
export function resolveUniversity(
  settings: UniversitySettings | null | undefined
): University | null {
  if (settings === null || settings === undefined) return null
  const { universityId, customUniversity } = settings
  if (universityId === null) return null
  if (isCustomUniversityId(universityId)) {
    return customUniversity !== null && customUniversity.id === universityId
      ? customUniversity
      : null
  }
  return findUniversity(universityId)
}

function normalizeQuery(query: string): string {
  return query.trim().toLocaleLowerCase().replace(/\s+/g, '')
}

/** Onboarding search: name (ko/en) + aliases + domain, whitespace-insensitive. */
export function searchUniversities(query: string): readonly University[] {
  const normalized = normalizeQuery(query)
  if (normalized.length === 0) return UNIVERSITIES
  return UNIVERSITIES.filter((university) =>
    [
      university.nameKo,
      university.nameEn,
      university.domain,
      ...university.aliases
    ].some((term) => normalizeQuery(term).includes(normalized))
  )
}

/** A preset/custom service with the user's overrides already applied. */
export interface ResolvedService extends UniversityService {
  /** Final embedded-vs-external decision (override beats the preset). */
  opensExternally: boolean
  /** Final 더보기 tier (override beats the preset). */
  secondary: boolean
  /** True for entries the user added themselves. */
  isCustom: boolean
}

type ServiceOverrides = Pick<
  UniversitySettings,
  'openExternallyOverrides' | 'secondaryOverrides'
>

function applyOverride(
  service: UniversityService,
  overrides: ServiceOverrides,
  isCustom: boolean
): ResolvedService {
  return {
    ...service,
    opensExternally:
      overrides.openExternallyOverrides[service.id] ??
      service.opensExternally ??
      false,
    secondary: overrides.secondaryOverrides[service.id] ?? service.secondary ?? false,
    isCustom
  }
}

/**
 * The sidebar's list: preset services (catalog order), then the common
 * services every school shares, then the user's own — re-sorted by the
 * user's `serviceOrder`, minus anything hidden, with per-service external
 * and 더보기-tier overrides applied.
 */
export function resolveServices(
  university: University | null,
  settings: UniversitySettings | null | undefined
): readonly ResolvedService[] {
  const hidden = new Set(settings?.hiddenServiceIds ?? [])
  const overrides: ServiceOverrides = {
    openExternallyOverrides: settings?.openExternallyOverrides ?? {},
    secondaryOverrides: settings?.secondaryOverrides ?? {}
  }
  const presets = (university?.services ?? []).map((service) =>
    applyOverride(service, overrides, false)
  )
  const common = COMMON_SERVICES.map((service) =>
    applyOverride(service, overrides, false)
  )
  const custom = (settings?.customServices ?? []).map((service) =>
    applyOverride(service, overrides, true)
  )
  return applyServiceOrder(
    [...presets, ...common, ...custom],
    settings?.serviceOrder ?? []
  ).filter((service) => !hidden.has(service.id))
}

/** Splits a resolved list into the always-visible and the 더보기 tier, in order. */
export function serviceTierIds(services: readonly ResolvedService[]): {
  primary: string[]
  secondary: string[]
} {
  return {
    primary: services.filter((service) => !service.secondary).map((s) => s.id),
    secondary: services.filter((service) => service.secondary).map((s) => s.id)
  }
}
