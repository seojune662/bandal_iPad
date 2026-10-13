import type { AgentProvider } from '../../../shared/types/agent-events'
import type { AgentModelCatalog, AgentModelOption } from '../../../shared/types/chat'
import type { LearningAiSettings } from '../../../shared/types/learning'
import { createBinaryLocator } from './binaryLocator'
import { FALLBACK_MODELS, probeModels, type CliModel } from './claude/modelProbe'
import { createCodexBinaryLocator } from './codex/binaryLocator'
import {
  CODEX_FALLBACK_MODELS,
  discoverCodexModels
} from './codex/modelCatalog'
import { augmentedPathEnv } from './platform'

const locator = createBinaryLocator()
const codexLocator = createCodexBinaryLocator()
const GEMINI_MODELS: readonly CliModel[] = [
  { value: 'auto', displayName: 'Gemini 자동 선택' },
  { value: 'pro', displayName: 'Gemini Pro' },
  { value: 'flash', displayName: 'Gemini Flash' },
  { value: 'flash-lite', displayName: 'Gemini Flash Lite' }
]
const modelCache = new Map<
  AgentProvider,
  { expiresAt: number; pending: Promise<AgentModelCatalog> }
>()
const blockedModels = new Map<AgentProvider, Set<string>>()
const CACHE_TTL_MS = 5 * 60 * 1_000

function toOptions(models: readonly CliModel[]): AgentModelOption[] {
  return models.map((model) => ({
    id: model.value,
    displayName: model.displayName,
    isDefault: model.value === 'default' || model.value === 'auto',
    ...(model.resolvedModel ? { resolvedModel: model.resolvedModel } : {}),
    ...(model.supportedEfforts ? { supportedEfforts: model.supportedEfforts } : {}),
    ...(model.defaultEffort ? { defaultEffort: model.defaultEffort } : {})
  }))
}

const fallbackResult = (
  provider: AgentProvider
): AgentModelCatalog => ({
  models: toOptions(
    provider === 'codex'
      ? CODEX_FALLBACK_MODELS
      : provider === 'gemini'
        ? GEMINI_MODELS
        : FALLBACK_MODELS
  ), source: 'fallback', status: provider === 'codex' ? 'unavailable' : 'unverified',
  error: '실시간 모델 목록을 받지 못했어요. 이 목록의 실행 가능 여부는 제공자가 확인합니다.'
})

async function discoverModels(
  provider: AgentProvider
): Promise<AgentModelCatalog> {
  if (provider === 'gemini') {
    return { models: toOptions(GEMINI_MODELS), source: 'fallback', status: 'unverified' }
  }
  if (provider === 'codex') {
    const binary = await codexLocator.locate()
    const loginPath = await codexLocator.loginShellPath()
    const result = await discoverCodexModels({
        binaryPath: binary.path,
        env: augmentedPathEnv(binary.path, loginPath)
      })
    return { ...result, models: toOptions(result.models) }
  }
  try {
    const binary = await locator.locate()
    const loginPath = await locator.loginShellPath()
    const models = await probeModels({ binaryPath: binary.path, env: augmentedPathEnv(binary.path, loginPath) })
    return models === FALLBACK_MODELS ? fallbackResult(provider) : { models: toOptions(models), source: 'live', status: 'ready', fetchedAt: new Date().toISOString() }
  } catch {
    return fallbackResult(provider)
  }
}

/** Bounded cache; refresh rechecks the connected CLI without changing its configuration. */
export function getAgentModels(
  provider: AgentProvider, refresh = false
): Promise<AgentModelCatalog> {
  if (refresh) {
    modelCache.delete(provider)
    blockedModels.delete(provider)
    if (provider === 'codex') codexLocator.reset()
    if (provider === 'claude-code') locator.reset()
  }
  const cached = modelCache.get(provider)
  const pending = cached && cached.expiresAt > Date.now() ? cached.pending : discoverModels(provider).catch(() => fallbackResult(provider))
  if (pending !== cached?.pending) modelCache.set(provider, { expiresAt: Date.now() + CACHE_TTL_MS, pending })
  return pending.then(result => ({ ...result, ...(blockedModels.get(provider)?.size ? { blockedModelIds: [...blockedModels.get(provider)!] } : {}) }))
}

/** Only a real execution rejection blocks a candidate; discovery flags never imply account access. */
export function rejectAgentModel(provider: AgentProvider, model: string): void {
  const rejected = blockedModels.get(provider) ?? new Set<string>()
  rejected.add(model); blockedModels.set(provider, rejected)
}

export async function validateLearningAi(ai: LearningAiSettings): Promise<LearningAiSettings> {
  if (!['claude-code', 'codex', 'gemini'].includes(ai.provider) || !ai.model?.trim() || ['default', 'auto'].includes(ai.model)) throw new Error('학습 공간에서 AI 제공자와 모델을 직접 선택하세요.')
  const catalog = await getAgentModels(ai.provider)
  const selected = catalog.models.find(model => !model.isDefault && (model.id === ai.model || model.resolvedModel === ai.model))
  if (!selected || catalog.blockedModelIds?.includes(ai.model)) throw new Error('현재 연결에서 사용할 모델을 다시 선택하세요. 필요하면 모델 목록을 새로고침하세요.')
  if (ai.effort !== null && !selected.supportedEfforts?.includes(ai.effort)) throw new Error('선택한 모델에서 지원하지 않는 사고 수준입니다.')
  return { provider: ai.provider, model: ai.model, effort: ai.effort }
}

/** Resolve model defaults explicitly so a user's unrelated CLI effort cannot leak into learning. */
export async function resolveLearningAi(ai: LearningAiSettings): Promise<LearningAiSettings> {
  const validated = await validateLearningAi(ai)
  if (validated.effort !== null || validated.provider === 'gemini') return validated
  const { models } = await getAgentModels(validated.provider)
  const selected = models.find(model => !model.isDefault && (model.id === validated.model || model.resolvedModel === validated.model))!
  const effort = selected.defaultEffort ?? (selected.supportedEfforts?.includes('medium') ? 'medium' : selected.supportedEfforts?.[0])
  if (!effort && validated.provider === 'codex') throw new Error('이 모델의 기본 사고 수준을 확인하지 못했어요. 목록을 새로고침하고 지원하는 사고 수준을 선택하세요.')
  return { ...validated, effort: effort ?? null }
}
