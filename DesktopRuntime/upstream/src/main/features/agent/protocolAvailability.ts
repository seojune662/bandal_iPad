import type { AgentAvailability } from '../../../shared/types/agent-events'
/** Versions exercised against the bidirectional transports shipped in 0.60. */
export function requireProtocolVersion(availability: AgentAvailability, provider: 'codex' | 'gemini'): AgentAvailability {
  const minimum = provider === 'codex' ? [0, 158, 0] : [0, 58, 0]
  const actual = availability.version?.match(/\d+/g)?.slice(0, 3).map(Number)
  if (!availability.installed) return availability
  if (!actual || actual.length !== 3) return { ...availability, code: 'version-too-old', reason: 'CLI 버전을 확인하지 못했어요. 설정 → AI에서 업데이트해 주세요.' }
  const older = actual.some((part, index) => actual.slice(0, index).every((p, i) => p === minimum[i]) && part < minimum[index]!)
  return older ? { ...availability, code: 'version-too-old', reason: `${provider === 'codex' ? 'Codex' : 'Gemini'} ${minimum.join('.')} 이상이 필요해요. 설정 → AI에서 CLI를 업데이트해 주세요.` } : availability
}
