import type { PluginManifest } from './plugin'

export interface MarketplaceRelease {
  id: string
  plugin_id: string
  version: string
  manifest: PluginManifest
  sha256: string
  changelog: string
  status: 'pending' | 'approved' | 'rejected' | 'withdrawn'
  review_reason: string
  created_at: string
}

export interface MarketplaceDashboard {
  configured: boolean
  signedIn: boolean
  publisher: { id: string; display_name: string } | null
  reviewer: boolean
  releases: MarketplaceRelease[]
  reports?: Array<{
    id: string
    release_id: string
    reason: string
    created_at: string
  }>
}
