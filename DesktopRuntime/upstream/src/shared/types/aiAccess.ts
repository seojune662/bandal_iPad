export type AiAccessMode = 'ask' | 'auto' | 'full'
export interface AiAccessPolicy {
  mode: AiAccessMode
  /** Full access only suppresses prompts within these explicitly chosen scopes. */
  scope: { course: boolean; browser: boolean; screen: boolean }
}
export const DEFAULT_AI_ACCESS: AiAccessPolicy = { mode: 'full', scope: { course: true, browser: true, screen: false } }
export function parseAiAccess(value: unknown): AiAccessPolicy {
  if (!value || typeof value !== 'object') return structuredClone(DEFAULT_AI_ACCESS)
  const v = value as Partial<AiAccessPolicy>
  return { mode: v.mode === 'ask' || v.mode === 'full' ? v.mode : 'auto', scope: { course: v.scope?.course !== false, browser: v.scope?.browser === true, screen: v.scope?.screen === true } }
}
