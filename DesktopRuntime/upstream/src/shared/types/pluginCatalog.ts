/**
 * [v0.40] Plugin catalog: a static index.json per source (the official one is
 * served from bandal.io) listing installable extensions (zip) and workflow
 * packs (json). The app never runs anything from a catalog entry until the
 * existing installFromFolder / packs import path has sanitized it; the catalog
 * only adds "download + verify sha256" in front.
 */
import type { PluginSummary } from './plugin'
import type { WorkflowPack } from './workflowPack'

export const OFFICIAL_CATALOG_URL = 'https://bandal.io/plugins/index.json'
export const CATALOG_INDEX_FORMAT = 'bandal-plugin-catalog'
export const CATALOG_INDEX_VERSION = 1
/** Hard cap on a downloaded artifact (zip or pack json). */
export const CATALOG_ARTIFACT_MAX_BYTES = 8 * 1024 * 1024
export const CATALOG_SOURCES_MAX = 20

export type CatalogEntryKind = 'extension' | 'pack'

export interface CatalogEntry {
  /** Plugin id (extension) or pack id; unique within a source. */
  id: string
  kind: CatalogEntryKind
  name: string
  publisher: string
  description: string
  tags: readonly string[]
  version: string
  minAppVersion: string | null
  /** Absolute https URL of the zip (extension) or json (pack). */
  url: string
  /** Lowercase hex sha256 of the artifact at `url`. */
  sha256: string
  /** Source index this entry came from. */
  sourceUrl: string
  /** True only for entries from OFFICIAL_CATALOG_URL. */
  verified: boolean
  /** Derived by main only for the configured marketplace origin. */
  marketplaceReleaseId?: string
}

export interface CatalogSource {
  url: string
  official: boolean
  status: 'ok' | 'error'
  error: string | null
  fetchedAt: string | null
  entryCount: number
}

export interface PluginCatalog {
  sources: CatalogSource[]
  entries: CatalogEntry[]
  /** ISO of the newest successful fetch across sources; null = never. */
  fetchedAt: string | null
}

export type CatalogInstallResult =
  | { kind: 'extension'; plugin: PluginSummary; warnings: string[] }
  | { kind: 'pack'; pack: WorkflowPack; warnings: string[] }
