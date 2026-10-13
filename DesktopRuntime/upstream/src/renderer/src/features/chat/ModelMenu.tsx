import { useCallback, useRef, useState } from 'react'
import type { AgentProvider } from '../../../../shared/types/agent-events'
import type { AgentModelOption } from '../../../../shared/types/chat'
import { ComposerPopover } from './ComposerPopover'

export function ModelMenu({ provider, models, model, effort, disabled, saving, error, onProvider, onChange }: {
  provider: AgentProvider; models: AgentModelOption[]; model: string | null; effort: string | null
  disabled: boolean; saving: boolean; error: string | null
  onProvider: (provider: AgentProvider) => void; onChange: (model: string, effort: string | null) => Promise<void>
}): JSX.Element {
  const [open, setOpen] = useState(false)
  const anchor = useRef<HTMLButtonElement>(null)
  const close = useCallback(() => setOpen(false), [])
  const selected = models.find((item) => item.id === model || item.resolvedModel === model) ?? (model ? undefined : models.find((item) => item.isDefault) ?? models[0])
  const selectedId = selected?.id ?? model ?? ''
  const change = (id: string, level: string | null): void => { void onChange(id, level).catch(() => undefined) }
  return <>
    <button ref={anchor} type="button" className="chat-model-trigger" aria-label="모델 및 Effort 설정" aria-haspopup="dialog" aria-expanded={open} onClick={() => setOpen(!open)}>
      <span>{selected?.displayName ?? model ?? '모델 선택'}</span><small>{effort ?? '기본'}</small><span aria-hidden="true">⌄</span>
    </button>
    {open && <ComposerPopover anchor={anchor} label="AI 실행 설정" onClose={close}>
      <div className="chat-menu-heading">AI 설정 {saving && <small role="status">저장 중…</small>}</div>
      <label className="chat-setting-row"><span>제공자</span><select aria-label="AI 제공자 선택" value={provider} disabled={disabled || saving} onChange={(event) => onProvider(event.target.value as AgentProvider)}>
        <option value="claude-code">Claude</option><option value="codex">Codex</option><option value="gemini">Gemini</option>
      </select></label>
      <label className="chat-setting-row"><span>Model</span><select aria-label="AI 모델 선택" value={selectedId} disabled={disabled || saving || models.length === 0} onChange={(event) => {
        const next = models.find((item) => item.id === event.target.value)
        change(event.target.value, effort && next?.supportedEfforts?.includes(effort) ? effort : null)
      }}>
        {!selected && selectedId && <option value={selectedId}>{selectedId}</option>}
        {models.map((item) => <option key={item.id} value={item.id}>{item.displayName}</option>)}
      </select></label>
      <label className="chat-setting-row"><span>Effort</span><select aria-label="AI Effort 선택" value={effort ?? ''} disabled={disabled || saving || !selected?.supportedEfforts?.length} onChange={(event) => change(selectedId, event.target.value || null)}>
        <option value="">기본값{selected?.defaultEffort ? ` (${selected.defaultEffort})` : ''}</option>
        {selected?.supportedEfforts?.map((level) => <option key={level} value={level}>{level}</option>)}
      </select></label>
      {!selected?.supportedEfforts?.length && <p className="chat-menu-note">이 모델은 기본 Effort를 사용해요. 설치된 AI가 지원하는 설정만 표시합니다.</p>}
      {disabled && <p className="chat-menu-note">응답과 승인 처리가 끝난 뒤 바꿀 수 있어요.</p>}
      {error && <p className="chat-menu-error" role="alert">{error} 다시 선택해 주세요.</p>}
    </ComposerPopover>}
  </>
}
