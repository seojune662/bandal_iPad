import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { StudyToolId } from '../../../../shared/types/study'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { restoreFocus, useFocusTrap } from '../../components/useFocusTrap'
import { useUiStore } from '../../stores/uiStore'
import { useWorkflowPacksStore } from '../../stores/workflowPacksStore'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { requestFeatureAction, featureActionDisabledReason, studyToolFeatureEntry, type FeatureActionScope } from '../launcher/featureActions'
import { LearningGenerationForm, type LearningGenerationRequest } from '../learning/LearningGenerationForm'
import { StudyToolIcon, StudyToolsIcon } from './StudyToolIcons'
import { type PackStudyToolDefinition, useStudyToolsStore } from './studyToolsStore'
import type { StudyPaletteRequest } from './studyPaletteEvents'
import {
  FEATURED_STUDY_TOOLS, STUDY_TOOL_GROUPS, isPackFollowUpAvailable,
  studyToolDescription, studyToolFollowUpLabel, studyToolGroup, studyToolLabel,
  studyToolMatches, studyToolOutput
} from './studyPaletteModel'
import './study.css'

export { isPackFollowUpAvailable } from './studyPaletteModel'

const BUILTIN_TOOL_IDS: readonly StudyToolId[] = ['summary', 'quiz', 'flashcards', 'mindmap', 'structured-notes', 'exam-predictions', 'explain']
function ToolIcon({ id }: { id: string }): JSX.Element {
  return BUILTIN_TOOL_IDS.includes(id as StudyToolId) ? <StudyToolIcon tool={id as StudyToolId} /> : <StudyToolsIcon />
}

export interface StudyToolMenuProps {
  request: StudyPaletteRequest
  onClose: () => void
  /** Stable snapshot override used by non-interactive renderers and tests. */
  toolsOverride?: readonly PackStudyToolDefinition[]
}

/** A single surface owns tool discovery and the existing validated setup form. */
export function StudyToolMenu({ request, onClose, toolsOverride }: StudyToolMenuProps): JSX.Element {
  const { context, returnFocus } = request
  const scope: FeatureActionScope = context.selection.trim() ? 'selection' : context.material ? 'material' : 'course'
  const relPath = context.material?.relPath ?? null
  const root = useRef<HTMLElement>(null)
  const search = useRef<HTMLInputElement>(null)
  const setupHeading = useRef<HTMLHeadingElement>(null)
  const id = useId()
  const [query, setQuery] = useState('')
  const [generation, setGeneration] = useState<LearningGenerationRequest | null>(null)
  const [pending, setPending] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const storedTools = useStudyToolsStore(state => state.tools)
  const hasLoaded = useStudyToolsStore(state => state.hasLoaded)
  const isLoading = useStudyToolsStore(state => state.isLoading)
  const error = useStudyToolsStore(state => state.error)
  const running = useStudyToolsStore(state => state.running)
  const loadTools = useStudyToolsStore(state => state.loadTools)
  const tools = toolsOverride ?? storedTools
  const loading = toolsOverride === undefined && (isLoading || !hasLoaded && !error)
  const loadError = toolsOverride === undefined ? error : null
  const visibleTools = useMemo(() => tools.filter(tool => tool.experience !== 'article-vocabulary' && studyToolMatches(tool, query)), [tools, query])
  const featured = FEATURED_STUDY_TOOLS.flatMap(toolId => visibleTools.filter(tool => tool.id === toolId && tool.source !== 'user'))
  const remaining = visibleTools.filter(tool => !featured.includes(tool))

  useEffect(() => { if (toolsOverride === undefined) void loadTools() }, [loadTools, toolsOverride])
  useFocusTrap(root, { active: !settingsOpen, initialFocus: search, returnFocus: false, onEscape: pending ? undefined : onClose })
  useEffect(() => { if (!settingsOpen) return acquirePointerPassthrough() }, [settingsOpen])
  useEffect(() => () => restoreFocus(returnFocus), [returnFocus])
  useEffect(() => {
    if (settingsOpen) return
    // A step transition replaces controls, but keeps one modal and focus trap.
    if (generation) setupHeading.current?.focus({ preventScroll: true })
    else search.current?.focus({ preventScroll: true })
  }, [generation, settingsOpen])

  const chooseTool = async (tool: PackStudyToolDefinition, followUp = false): Promise<void> => {
    setActionError(null)
    try {
      const result = await requestFeatureAction(studyToolFeatureEntry(tool), context, {
        scope, followUp, presentGeneration: setGeneration,
        onResult: result => {
          if (result.status === 'started' || result.status === 'dispatched' || result.status === 'completed') showToast(result.message)
        }
      })
      if (result.status === 'failed' || result.status === 'needs-course') setActionError(result.message)
    } catch (caught) {
      setActionError(caught instanceof Error ? caught.message : '학습 도구를 열지 못했어요.')
    }
  }

  const card = (tool: PackStudyToolDefinition, prominent = false): JSX.Element => {
    const reason = featureActionDisabledReason(studyToolFeatureEntry(tool), context, scope)
      ?? ((running[tool.id] ?? 0) > 0 ? '이미 만들고 있어요.' : null)
    const descriptionId = `${id}-${tool.id}-description`
    return <article className="study-palette__card" key={tool.id} data-featured={prominent || undefined} data-disabled={!!reason || undefined}>
      <button type="button" className="study-palette__tool" aria-label={studyToolLabel(tool)} aria-describedby={descriptionId} disabled={!!reason} onClick={() => void chooseTool(tool)}>
        <span className="study-palette__tool-icon" aria-hidden="true"><ToolIcon id={tool.id} /></span>
        <span className="study-palette__tool-copy">
          <strong>{studyToolLabel(tool)}</strong>
          <span id={descriptionId} className="study-palette__description">{reason ?? studyToolDescription(tool)}</span>
          <span className="study-palette__badges"><span>{studyToolOutput(tool)}</span>{tool.usesWeb && <span>웹 검색</span>}</span>
        </span>
      </button>
      {isPackFollowUpAvailable(tool, relPath) && <button type="button" className="study-palette__follow-up" disabled={!!reason} onClick={() => void chooseTool(tool, true)}>{studyToolFollowUpLabel(tool)}<Icon name="chevronRight" /></button>}
    </article>
  }

  const targetName = context.material?.title || relPath?.split('/').at(-1) || context.courseName || '선택한 과목'
  const scopeLabel = scope === 'selection' ? '선택한 부분' : scope === 'course' ? '과목 전체' : '자료 전체'
  return createPortal(<div className="dialog-backdrop study-palette-backdrop" style={settingsOpen ? { display: 'none' } : undefined} onMouseDown={event => { if (event.target === event.currentTarget && !pending) onClose() }}>
    <section ref={root} className="course-dialog study-palette" role="dialog" aria-modal="true" aria-label="이 자료로 학습하기">
      <header className="study-palette__header">
        <div>{generation ? <button type="button" className="study-palette__back" aria-label="도구 선택으로 돌아가기" disabled={pending} onClick={() => { setGeneration(null); setPending(false) }}><Icon name="chevronLeft" />도구 선택</button> : <p className="study-palette__eyebrow">AI 학습 도구</p>}
          <h2 ref={setupHeading} tabIndex={-1}>{generation ? `${generation.label} ${generation.entry.kind === 'plugin-command' ? '실행' : '만들기'}` : '어떤 방식으로 공부할까요?'}</h2>
          {!generation && <p className="study-palette__intro">원하는 결과를 고르고, 바로 학습을 시작하세요.</p>}
        </div>
        <button className="bare-icon-button" type="button" aria-label="학습 도구 닫기" disabled={pending} onClick={onClose}><Icon name="x" /></button>
      </header>
      <div className="study-palette__target" aria-label="선택한 학습 자료">
        <Icon name={context.material ? 'fileText' : 'folderOpen'} />
        <div><strong>{targetName}</strong><span>{[context.courseName, relPath && relPath !== targetName ? relPath : null, scopeLabel].filter(Boolean).join(' · ')}</span></div>
      </div>
      {generation ? <LearningGenerationForm request={generation} sourceLocked onClose={onClose} onPendingChange={setPending} /> : <>
        <label className="study-palette__search"><Icon name="search" /><input ref={search} value={query} onChange={event => setQuery(event.target.value)} placeholder="어떤 도움이 필요한가요?" aria-label="학습 도구 검색" />{query && <button type="button" className="bare-icon-button" aria-label="검색 지우기" onClick={() => { setQuery(''); search.current?.focus() }}><Icon name="x" /></button>}</label>
        <div className="study-palette__body">
          {loadError && <div className="study-palette__error" role="alert"><span>{loadError}</span><button type="button" onClick={() => void useWorkflowPacksStore.getState().refresh()}>다시 불러오기</button></div>}
          {actionError && <p className="study-palette__error" role="alert">{actionError}</p>}
          {loading && <p className="study-palette__empty" role="status">학습 도구를 불러오는 중이에요.</p>}
          {featured.length > 0 && <section aria-label="학습 바로가기"><h3>바로 시작하기</h3><div className="study-palette__featured">{featured.map(tool => card(tool, true))}</div></section>}
          {STUDY_TOOL_GROUPS.map(group => {
            const grouped = remaining.filter(tool => studyToolGroup(tool) === group)
            return grouped.length > 0 ? <section key={group} aria-label={group}><h3>{group}</h3><div className="study-palette__grid">{grouped.map(tool => card(tool))}</div></section> : null
          })}
          {!loading && !loadError && visibleTools.length === 0 && <div className="study-palette__empty" role="status"><StudyToolsIcon /><strong>{query.trim() ? '일치하는 학습 도구가 없어요.' : '사용 가능한 학습 도구가 없어요.'}</strong><span>{query.trim() ? '다른 단어나 만들고 싶은 결과로 검색해 보세요.' : '설정의 플러그인 관리에서 학습 도구를 확인해 주세요.'}</span></div>}
        </div>
        <footer className="study-palette__footer"><span>도구를 고르면 원본과 저장할 곳을 확인할 수 있어요.</span><kbd>Esc</kbd><span>닫기</span></footer>
      </>}
    </section>
  </div>, document.body)
}
