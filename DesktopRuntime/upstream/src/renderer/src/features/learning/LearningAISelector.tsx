import { useCallback, useEffect, useRef, useState } from 'react'
import type { AgentAvailability, AgentProvider } from '../../../../shared/types/agent-events'
import { isAgentReady } from '../../../../shared/agentProviderSelection'
import type { AgentModelOption } from '../../../../shared/types/chat'
import type { LearningAiSettings } from '../../../../shared/types/learning'
import { useUiStore } from '../../stores/uiStore'
import { invoke } from '../../lib/ipc'

interface CatalogState {
  models: AgentModelOption[]
  source?: 'live' | 'cache' | 'fallback'
  status?: 'ready' | 'unverified' | 'unavailable'
  error?: string
  blockedModelIds?: string[]
}

export function LearningAISelector({ value, disabled = false, onChange, onValidityChange }: {
  value: LearningAiSettings | null
  disabled?: boolean
  onChange: (value: LearningAiSettings | null) => void
  onValidityChange: (valid: boolean) => void
}): JSX.Element {
  const [provider, setProvider] = useState<AgentProvider | ''>(value?.provider ?? '')
  const [model, setModel] = useState(value?.model ?? '')
  const [effort, setEffort] = useState(value?.effort ?? '')
  const [availability, setAvailability] = useState<AgentAvailability | null>(null)
  const [catalog, setCatalog] = useState<CatalogState | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const settingsWereOpen = useRef(settingsOpen)
  const sequence = useRef(0)
  const models = catalog?.models.filter(item => item.id.trim() && !['default', 'auto'].includes(item.id.toLowerCase()) && !catalog?.blockedModelIds?.includes(item.id)) ?? []
  const selected = models.find(item => item.id === model)
  const connected = isAgentReady(availability ?? undefined)
  const effortValid = !effort || selected?.supportedEfforts?.includes(effort) === true
  const valid = !!provider && connected && !!selected && effortValid && catalog?.status !== 'unavailable' && !loading && !error
  const validity = useRef(onValidityChange); validity.current = onValidityChange
  useEffect(() => { validity.current(valid) }, [valid])
  const change = (nextProvider: AgentProvider | '', nextModel: string, nextEffort: string): void => {
    setProvider(nextProvider); setModel(nextModel); setEffort(nextEffort)
    onChange(nextProvider && nextModel ? { provider: nextProvider, model: nextModel, effort: nextEffort || null } : null)
  }
  const load = useCallback(async (refresh = false) => {
    const request = ++sequence.current
    if (!provider) { setAvailability(null); setCatalog(null); setError(null); setLoading(false); return }
    setLoading(true); setError(null)
    const results = await Promise.allSettled([invoke('agent:availability', { provider, ...(refresh ? { refresh: true } : {}) }), invoke('agent:models', { provider, ...(refresh ? { refresh: true } : {}) })])
    if (request !== sequence.current) return
    if (results[0].status === 'fulfilled') setAvailability(results[0].value)
    else setAvailability(null)
    if (results[1].status === 'fulfilled') setCatalog(results[1].value)
    else setCatalog(null)
    if (results.some(result => result.status === 'rejected')) setError('AI 연결과 모델 목록을 확인하지 못했어요. 다시 확인해 주세요.')
    setLoading(false)
  }, [provider])
  useEffect(() => { void load(); return () => { sequence.current += 1 } }, [load])
  useEffect(() => { const reopened = settingsWereOpen.current && !settingsOpen; settingsWereOpen.current = settingsOpen; if (reopened) void load(true) }, [settingsOpen, load])
  return <fieldset className="learning-ai-settings" disabled={disabled}>
    <legend>이 공간에서 사용할 AI</legend>
    <div className="learning-form-row">
      <label className="learning-field"><span>AI 제공자</span><select aria-label="학습 AI 제공자" value={provider} onChange={event => { setAvailability(null); setCatalog(null); change(event.target.value as AgentProvider | '', '', '') }}><option value="">제공자 선택</option><option value="claude-code">Claude</option><option value="codex">Codex</option><option value="gemini">Gemini</option></select></label>
      <label className="learning-field"><span>모델</span><select aria-label="학습 AI 모델" value={model} disabled={disabled || loading || !connected || models.length === 0} onChange={event => {
        const next = models.find(item => item.id === event.target.value)
        change(provider, event.target.value, next?.supportedEfforts?.includes(effort) ? effort : '')
      }}><option value="">모델 선택</option>{model && !selected && <option value={model} disabled>{model} · 목록에서 확인 필요</option>}{models.map(item => <option key={item.id} value={item.id}>{item.displayName} · {item.id}</option>)}</select></label>
    </div>
    {selected && (selected.supportedEfforts?.length || effort) ? <label className="learning-field"><span>생각하는 깊이 <small>(선택)</small></span><select aria-label="학습 AI Effort" value={effort} onChange={event => change(provider, model, event.target.value)}><option value="">모델 기본값</option>{effort && !effortValid && <option value={effort} disabled>{effort} · 현재 지원하지 않음</option>}{selected.supportedEfforts?.map(item => <option key={item} value={item}>{item}</option>)}</select></label> : null}
    <div className="learning-ai-status">
      <p role={error ? 'alert' : 'status'}>{loading ? '연결과 모델 목록 확인 중…' : error ?? (!provider ? '연결된 AI와 사용할 모델을 직접 선택해 주세요.' : !connected ? availability?.reason ?? '이 AI에 연결한 뒤 사용할 수 있어요.' : catalog?.status === 'unavailable' || models.length === 0 ? catalog?.error ?? '선택할 수 있는 실제 모델을 확인하지 못했어요.' : catalog?.source === 'cache' || catalog?.status === 'unverified' ? '이전에 확인한 모델 후보입니다. 계정에서 사용할 수 있는지는 실행할 때 확인합니다.' : 'AI 연결과 모델 목록을 확인했어요.')}</p>
      {provider && <button className="learning-text-button" type="button" disabled={disabled || loading} onClick={() => void load(true)}>연결 · 모델 새로고침</button>}
      {provider && !loading && !connected && <button className="learning-text-button" type="button" onClick={() => useUiStore.getState().openSettings('ai')}>AI 연결 설정 열기</button>}
    </div>
  </fieldset>
}
