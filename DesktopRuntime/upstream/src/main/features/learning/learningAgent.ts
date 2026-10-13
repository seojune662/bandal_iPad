import type { LearningAiSettings } from '../../../shared/types/learning'
import type { SessionManager } from '../agent/SessionManager'
import type { AgentAvailability, AgentProvider } from '../../../shared/types/agent-events'
import { isAgentReady } from '../../../shared/agentProviderSelection'
import { LearningExecutionError, learningFailure } from './learningFailures'

function assertConnected(availability: AgentAvailability): void {
  if (!isAgentReady(availability)) throw new LearningExecutionError({
    message: availability.reason ?? '선택한 AI 연결을 사용할 수 없어요.',
    code: availability.code ?? (!availability.installed ? 'not-installed' : 'not-logged-in'), category: 'connection',
    actionable: '설정에서 선택한 AI 연결을 확인하고 로그인한 뒤 다시 시도하세요.'
  })
}

export async function validateConnectedLearningAi(ai: LearningAiSettings,
  availability: (provider: AgentProvider) => Promise<AgentAvailability>,
  validateAi: (ai: LearningAiSettings) => Promise<LearningAiSettings>
): Promise<LearningAiSettings> {
  assertConnected(await availability(ai.provider))
  return validateAi(ai)
}

/** Learning never inherits a CLI's global default model or skips connection preflight. */
export async function sendLearningWithSession(
  manager: SessionManager, courseId: string, sessionId: string, prompt: string,
  ai: LearningAiSettings, validateAi: (ai: LearningAiSettings) => Promise<LearningAiSettings>
): Promise<unknown> {
  const validated = await validateAi(ai).catch(error => {
    const failure = learningFailure(error)
    throw new LearningExecutionError(failure.category === 'unknown' ? { ...failure, code: 'model-selection-invalid', category: 'model' } : failure)
  })
  const { availability } = await manager.open(courseId, sessionId, 'study')
  assertConnected(availability)
  manager.setModel(courseId, sessionId, validated.model, validated.effort)
  return manager.send(courseId, sessionId, prompt)
}
