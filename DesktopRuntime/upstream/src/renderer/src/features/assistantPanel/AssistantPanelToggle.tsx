import { Tooltip } from '../../components/Tooltip'
import { usePanelAssistant } from './panelContext'

/** The browser shares its navigation row with AI; documents keep their launchbar. */
export function AssistantPanelToggle({ className = '' }: { className?: string }): JSX.Element | null {
  const assistant = usePanelAssistant()
  if (assistant === null) return null
  const label = assistant.open ? 'AI 보조 사이드바 접기' : 'AI 보조 사이드바 펼치기'
  return <Tooltip label={label} placement="bottom">
    <button
      type="button"
      className={`tab-assistant-toggle ${className}`}
      data-tour="assistant-panel-toggle"
      aria-expanded={assistant.open}
      aria-label={label}
      onClick={assistant.toggle}
    ><span aria-hidden="true">✦</span><span className="tab-assistant-toggle__label">AI</span></button>
  </Tooltip>
}
