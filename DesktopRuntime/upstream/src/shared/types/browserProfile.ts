export interface BrowserProfile {
  id: string
  name: string
  color: string
  icon: string
}
export const DEFAULT_BROWSER_PROFILE = 'default'
export const PROFILE_COLORS = ['#4d7850', '#397db5', '#9757b0', '#c36f24', '#bc4762'] as const
