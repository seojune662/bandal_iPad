import { LEARNING_RUN_STARTED_EVENT, takeStartedLearningRuns, startLearningRun, retryLearningRun } from './learningStartedRuns'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { IDockviewPanelProps } from 'dockview'
import { isTabDescriptor, type LearningTabPayload, type LearningView } from '../../../../shared/tabs'
import type { LearningArticleSnapshot, LearningArtifact, LearningDraft, LearningProjectSnapshot, LearningRunKind } from '../../../../shared/types/learning'
import type { MaterialNode } from '../../../../shared/types/materials'
import { Icon } from '../../app/icons'
import { invoke, onPush } from '../../lib/ipc'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { MarkdownView } from '../chat/MarkdownView'
import { usePanelActive } from '../workspace/usePanelActive'
import { LearningProjectsHome } from './LearningProjects'
import { LearningCreateDialog } from './LearningCreateDialog'
import { LearningProjectHome, ReviewCreateActions } from './LearningProjectHome'
import { LearningRunStatus } from './LearningRunStatus'
import { learningNeedsSettings, learningPurposeLabel } from './learningPurpose'
import { useUiStore } from '../../stores/uiStore'
import { LearningReader } from './LearningReader'
import { EnglishReadingGuide } from './EnglishReadingGuide'
import { dismissEnglishReadingGuide, useEnglishReadingGuideSeen } from './englishReadingGuideState'
import { LearningQuiz, LearningCards, dueLearningCards } from './LearningReview'
import { LearningSources } from './LearningSources'
import { LearningDraftPreview } from './LearningDraftPreview'
import { LearningMaterialImportDialog } from './LearningMaterialImportDialog'
import { learningError, notifyLearningChanged, openLearningHome } from './learningNavigation'
import { filterLearningArticles, type LearningArticleFilter, type LearningArticleDateFilter } from './learningMetrics'
import { findMovedLearningBinding, rebindLearningPanel } from './learningRelocation'
import { learningDisplayName } from './learningPresentation'
import { useCoursesStore } from '../../stores/coursesStore'
import { isLearningRunActive, visibleLearningRuns } from './learningRunPresentation'
import type { LearningRun } from '../../../../shared/types/learning'
import './learning.css'

const NAVIGATION: { view: LearningView; label: string; symbol: string }[] = [
  { view: 'home', label: '오늘의 학습', symbol: '◒' }, { view: 'reader', label: '읽기', symbol: 'Aa' },
  { view: 'vocabulary', label: '나의 단어', symbol: 'W' }, { view: 'articles', label: '읽은 글과 다음 글', symbol: '↗' },
  { view: 'review', label: '퀴즈 · 카드', symbol: '▤' }
]

function markdownFiles(nodes: MaterialNode[]): MaterialNode[] {
  return nodes.flatMap(node => node.kind === 'dir' ? markdownFiles(node.children ?? []) : /\.md$/i.test(node.relPath) ? [node] : [])
}

export default function LearningTab(props: IDockviewPanelProps): JSX.Element {
  const raw = props.params.descriptor
  if (!isTabDescriptor(raw) || raw.kind !== 'learning') return <p className="learning-error">학습 공간 정보를 찾을 수 없어요.</p>
  return raw.payload.rootRelPath === undefined ? <LearningProjectsHome courseId={raw.payload.courseId} /> : <LearningProjectTab key={JSON.stringify([raw.payload.courseId, raw.payload.rootRelPath])} {...props} payload={raw.payload} />
}

function LearningProjectTab({ payload, ...props }: IDockviewPanelProps & { payload: LearningTabPayload }): JSX.Element {
  const binding = { courseId: payload.courseId, rootRelPath: payload.rootRelPath! }
  const active = usePanelActive(props.api)
  const courses = useCoursesStore(state => state.courses)
  const historicalRuns = useRef<Set<string> | null>(null)
  const [project, setProject] = useState<LearningProjectSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [view, setView] = useState<LearningView>(payload.view ?? 'home')
  const [itemId, setItemId] = useState<string | undefined>(payload.itemId)
  const [article, setArticle] = useState<LearningArticleSnapshot | null>(null)
  const [artifact, setArtifact] = useState<LearningArtifact | null>(null)
  const [articleLoading, setArticleLoading] = useState(false)
  const [artifactLoading, setArtifactLoading] = useState(false)
  const contentLoading = articleLoading || artifactLoading
  const [pending, setPending] = useState(false)
  const [showSettings, setShowSettings] = useState(false)
  const [showGuide, setShowGuide] = useState(false)
  const guideSeen = useEnglishReadingGuideSeen()
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const [url, setUrl] = useState('')
  const [showImport, setShowImport] = useState(false)
  const [importFiles, setImportFiles] = useState<MaterialNode[]>([])
  const [importPath, setImportPath] = useState('')
  const [wordQuery, setWordQuery] = useState('')
  const [articleFilter, setArticleFilter] = useState<LearningArticleFilter>('all')
  const [articleDateFilter, setArticleDateFilter] = useState<LearningArticleDateFilter>('all')
  const [wordFilter, setWordFilter] = useState<'all' | 'new' | 'learning' | 'known'>('all')
  const sequence = useRef(0)
  const projectId = useRef(payload.projectId)
  const currentPayload = useRef(payload); currentPayload.current = payload
  const update = useCallback((next: LearningProjectSnapshot) => {
    projectId.current = next.projectId
    historicalRuns.current ??= new Set(next.runs.filter(run => !isLearningRunActive(run)).map(run => run.id))
    for (const id of takeStartedLearningRuns(next.binding, next.runs)) historicalRuns.current.delete(id)
    setProject(current => current && current.revision > next.revision ? current : next)
  }, [])
  const refresh = useCallback(async () => {
    const request = ++sequence.current
    try { const next = await invoke('learning:get', { binding: { courseId: payload.courseId, rootRelPath: payload.rootRelPath! } }); if (request === sequence.current) { update(next); setError(null) } }
    catch (caught) {
      if (projectId.current) {
        try {
          const result = await invoke('learning:list', { courseId: payload.courseId, includeDeleted: true })
          const removed = result.projects.find(item => item.projectId === projectId.current && item.binding.rootRelPath === binding.rootRelPath && item.deletedAt)
          if (removed && request === sequence.current) {
            const workspace = useWorkspaceStore.getState()
            const wasActive = workspace.activePanelSource()?.panelId === props.api.id
            const owner = useCoursesStore.getState().courses.find(course => course.id === binding.courseId)
            await workspace.closeLearningSpace(binding, binding.rootRelPath === '' && owner?.workspaceKind === 'study-space')
            if (wasActive) openLearningHome()
            return
          }
          const moved = findMovedLearningBinding(binding, projectId.current, result.projects)
          if (moved && request === sequence.current) { rebindLearningPanel(props, { ...currentPayload.current, ...moved, projectId: projectId.current }); return }
        } catch { /* Retain the original error when rediscovery is unavailable. */ }
      }
      if (request === sequence.current) setError(learningError(caught))
    }
    finally { if (request === sequence.current) setLoading(false) }
  }, [payload.courseId, payload.rootRelPath, update])

  useEffect(() => {
    setLoading(true); setProject(null); historicalRuns.current = null; void refresh()
    const stop = onPush('learning:changed', event => { if (event.binding.courseId === binding.courseId) void refresh() })
    const stopMaterials = onPush('materials:changed', event => { if (event.courseId === binding.courseId) void refresh() })
    const handleStarted = (): void => { void refresh() }
    window.addEventListener(LEARNING_RUN_STARTED_EVENT, handleStarted)
    return () => { sequence.current += 1; stop(); stopMaterials(); window.removeEventListener(LEARNING_RUN_STARTED_EVENT, handleStarted) }
  }, [refresh])
  useEffect(() => {
    if (project && payload.projectId !== project.projectId) { props.api.updateParameters({ descriptor: { kind: 'learning', payload: { ...payload, projectId: project.projectId } } }); useWorkspaceStore.getState().notifyLayoutChanged() }
  }, [project?.projectId, payload.projectId])
  useEffect(() => { setView(payload.view ?? 'home'); setItemId(payload.itemId) }, [payload.view, payload.itemId])
  useEffect(() => { if (project) props.api.setTitle(learningDisplayName(project, courses)) }, [project?.name, project?.linkedCourseId, courses, props.api])
  const running = project?.runs.some(run => ['queued', 'running', 'validating'].includes(run.status)) ?? false
  useEffect(() => { if (!active || !running) return; const timer = setInterval(() => void refresh(), 2500); return () => clearInterval(timer) }, [active, running, refresh])

  const navigate = (nextView: LearningView, nextItem?: string): void => {
    setView(nextView); setItemId(nextItem); setError(null)
    props.api.updateParameters({ descriptor: { kind: 'learning', payload: { ...binding, ...(projectId.current ? { projectId: projectId.current } : {}), view: nextView, ...(nextItem ? { itemId: nextItem } : {}) } } })
    useWorkspaceStore.getState().notifyLayoutChanged()
  }
  const articleId = view === 'reader' ? itemId ?? project?.articles.find(item => item.status === 'reading')?.id ?? project?.articles.find(item => item.status === 'unread')?.id ?? project?.articles.at(-1)?.id : undefined
  useEffect(() => {
    if (!articleId) { setArticle(null); setArticleLoading(false); return }
    let cancelled = false; setArticleLoading(true); setArticle(null)
    void invoke('learning:getArticle', { binding, id: articleId }).then(next => { if (!cancelled) setArticle(next) }).catch(caught => { if (!cancelled) setError(learningError(caught)) }).finally(() => { if (!cancelled) setArticleLoading(false) })
    return () => { cancelled = true }
  }, [articleId, binding.courseId, binding.rootRelPath])
  const artifactId = view === 'review' ? itemId : undefined
  useEffect(() => {
    if (!artifactId) { setArtifact(null); setArtifactLoading(false); return }
    let cancelled = false; setArtifactLoading(true); setArtifact(null)
    void invoke('learning:getArtifact', { binding, id: artifactId }).then(next => { if (!cancelled) setArtifact(next) }).catch(caught => { if (!cancelled) setError(learningError(caught)) }).finally(() => { if (!cancelled) setArtifactLoading(false) })
    return () => { cancelled = true }
  }, [artifactId, binding.courseId, binding.rootRelPath])

  const perform = async (action: () => Promise<unknown>): Promise<void> => { setPending(true); setError(null); try { await action(); await refresh(); notifyLearningChanged() } catch (caught) { setError(learningError(caught)) } finally { setPending(false) } }
  const run = (kind: LearningRunKind, sourceArticleIds?: string[], sourceWordIds?: string[]): void => { if (project && learningNeedsSettings(project)) { setShowSettings(true); return }; void perform(() => startLearningRun({ binding, kind, ...(['find-articles', 'explain-word'].includes(kind) && project?.packId ? { packId: project.packId } : {}), ...(sourceArticleIds ? { articleIds: sourceArticleIds } : {}), ...(sourceWordIds ? { wordIds: sourceWordIds } : {}) })) }
  const startImport = async (): Promise<void> => { setShowImport(true); try { const tree = await invoke('materials:tree', { courseId: project?.linkedCourseId ?? binding.courseId }); setImportFiles(markdownFiles(tree)) } catch (caught) { setError(learningError(caught)) } }
  const importSave = (draft: LearningDraft, runId: string): void => { void perform(async () => { update(await invoke('learning:importSave', { binding, draft, runId })); navigate(draft.words?.length && !draft.artifacts?.length ? 'vocabulary' : 'review') }) }
  if (loading) return <div className="learning-panel learning-centered" role="status">학습 공간 불러오는 중…</div>
  if (!project) return <div className="learning-panel learning-page"><p className="learning-error" role="alert">{error ?? '학습 자료를 찾을 수 없어요.'}</p><button className="button button--secondary" type="button" onClick={() => void refresh()}>다시 불러오기</button></div>
  const english = project.purpose === 'english-reading'
  const navigation = english || !project.purpose || project.purpose === 'unclassified' ? NAVIGATION : NAVIGATION.filter(item => ['home', 'review'].includes(item.view) || item.view === 'vocabulary' && project.words.length > 0 || ['articles', 'reader'].includes(item.view) && project.articles.length > 0).map(item => item.view === 'articles' ? { ...item, label: '저장한 원문' } : item)
  const due = dueLearningCards(project)
  const displayedArticles = filterLearningArticles(project.articles, articleFilter, articleDateFilter)
  const displayedWords = project.words.filter(word => (wordFilter === 'all' || word.status === wordFilter) && `${word.surface} ${word.lemma} ${word.meaning}`.toLowerCase().includes(wordQuery.toLowerCase()))
  const previewRuns = project.runs.filter(run => run.status === 'awaiting-confirmation' && run.draft)

  const renderRun = (item: LearningRun, dismiss = false): JSX.Element => <LearningRunStatus key={item.id} run={item} ai={project.ai} pending={pending} {...(!english && item.kind === 'find-articles' ? { retryUnavailableReason: '영어 글 찾기는 영어 이어읽기 공간에서 시작해 주세요.' } : {})} onRetry={() => void perform(() => retryLearningRun({ binding, runId: item.id }))} onCancel={() => void perform(async () => update(await invoke('learning:runCancel', { binding, runId: item.id })))} onSettings={() => setShowSettings(true)} onConnection={() => useUiStore.getState().openSettings('ai')} {...(dismiss && !isLearningRunActive(item) ? { onDismiss: () => void perform(async () => update(await invoke('learning:dismissRun', { binding, runId: item.id }))) } : {})} {...(item.resultArtifactIds?.[0] ? { onOpenResult: () => navigate('review', item.resultArtifactIds![0]) } : item.resultArticleIds?.[0] ? { onOpenResult: () => navigate('reader', item.resultArticleIds![0]) } : {})} />

  return <div className="learning-panel">
    <header className="learning-topbar"><div><span className="learning-project-dot" /><strong>{learningDisplayName(project, courses)}</strong><span className="learning-topbar-topic">{learningPurposeLabel(project)}{english ? ` · ${project.topic}` : ''}</span></div><button className="learning-text-button" type="button" onClick={() => setShowSettings(true)}><Icon name="settings" /> 공간 설정</button>{project.ai && <button className="learning-text-button learning-topbar-ai" type="button" aria-label="학습 AI 변경" onClick={() => setShowSettings(true)}>{project.ai.provider === 'codex' ? 'Codex' : project.ai.provider === 'gemini' ? 'Gemini' : 'Claude'} · {project.ai.model}</button>}<button className="learning-text-button" type="button" disabled={pending} onClick={() => void startImport()}><Icon name="fileText" /> 기존 자료 가져오기</button></header>
    <nav className="learning-navigation" aria-label="학습 화면">{english && <button type="button" aria-label="영어 읽기 사용 방법" onClick={() => setShowGuide(true)}><Icon name="help" /> 사용 방법</button>}{navigation.map(item => <button key={item.view} type="button" aria-current={view === item.view ? 'page' : undefined} onClick={() => navigate(item.view)}><span aria-hidden="true">{item.symbol}</span>{item.label}{item.view === 'review' && due.length > 0 && <small>{due.length}</small>}</button>)}</nav>
    {error && <div className="learning-error learning-error-banner" role="alert"><span>{error}</span><button className="learning-text-button" type="button" onClick={() => setError(null)}>닫기</button></div>}
    {project.warnings.length > 0 && <div className="learning-notice" role="status">{project.warnings.join(' ')}</div>}
    {learningNeedsSettings(project) && <div className="learning-notice" role="status">{!project.purpose || project.purpose === 'unclassified' ? '기존 자료는 그대로 보존되어 있어요. 학습 공간 종류와 AI를 확인해 주세요.' : english ? '첫 글을 찾기 전에 주제와 읽기 설정, 사용할 AI를 확인해 주세요.' : '새 퀴즈나 카드를 만들 때 사용할 AI를 선택해 주세요. 저장된 자료는 바로 복습할 수 있어요.'} <button type="button" className="learning-text-button" onClick={() => setShowSettings(true)}>설정 확인</button></div>}
    {visibleLearningRuns(project.runs, historicalRuns.current ?? new Set()).map(item => renderRun(item, true))}
    {project.runs.length > 0 && <details className="learning-work-history"><summary>작업 기록 <small>{project.runs.length}</small></summary><div>{[...project.runs].reverse().map(item => <div className="learning-work-history-item" key={item.id}><small>{new Date(item.createdAt).toLocaleString('ko-KR')} · {item.status === 'complete' ? '완료' : item.status === 'cancelled' ? '취소' : item.status === 'failed' ? '실패' : item.status === 'interrupted' ? '중단' : item.status === 'awaiting-confirmation' ? '확인 대기' : '진행 중'}</small>{renderRun(item)}</div>)}</div></details>}
    {previewRuns.length > 0 ? <div className="learning-content-scroll"><div className="learning-page">{previewRuns.map(item => <LearningDraftPreview key={item.id} run={item} pending={pending} onSave={draft => importSave(draft, item.id)} onCancel={() => void perform(async () => update(await invoke('learning:runCancel', { binding, runId: item.id })))} />)}</div></div> : view === 'reader' && article ? <LearningReader key={article.id} project={project} article={article} active={active} onUpdate={update} onComplete={() => navigate('articles')} onArticle={id => navigate('reader', id)} /> : <div className="learning-content-scroll"><div className="learning-page">
      {contentLoading ? <p role="status" className="learning-muted">자료 불러오는 중…</p> : view === 'home' ? <LearningProjectHome project={project} pending={pending} running={running} onNavigate={navigate} onRun={run} onSettings={() => setShowSettings(true)} /> : view === 'articles' || view === 'reader' ? <><div className="learning-section-heading"><div><h1>{english ? '읽은 글과 다음 글' : '저장한 원문'}</h1></div>{english && <button className="button button--primary" type="button" disabled={pending || running} onClick={() => run('find-articles')}>다음 글 찾기</button>}</div><p className="learning-muted">{english ? '관심 주제와 내 단어가 실제로 등장하는 문장을 함께 확인해 글을 찾아요.' : '복습에 사용한 원문을 다시 확인할 수 있어요.'}</p><div className="learning-vocabulary-filter"><select aria-label="글 상태" value={articleFilter} onChange={event => setArticleFilter(event.target.value as LearningArticleFilter)}><option value="all">모든 글</option><option value="unread">읽기 전</option><option value="reading">읽는 중</option><option value="completed">읽은 글</option></select><select aria-label="글 기록 기간" value={articleDateFilter} onChange={event => setArticleDateFilter(event.target.value as LearningArticleDateFilter)}><option value="all">전체 기간</option><option value="week">최근 7일</option><option value="month">최근 30일</option></select></div><form className="learning-url-form" onSubmit={event => { event.preventDefault(); void perform(async () => { update(await invoke('learning:addArticle', { binding, url })); setUrl('') }) }}><label className="sr-only" htmlFor={`${props.api.id}-article-url`}>직접 추가할 기사 주소</label><input id={`${props.api.id}-article-url`} className="text-field" type="url" placeholder="읽고 싶은 영어 글의 주소를 붙여넣으세요" value={url} onChange={event => setUrl(event.target.value)} required /><button className="button button--secondary" type="submit" disabled={pending || !url.trim()}>글 추가</button></form><div className="learning-article-list">{displayedArticles.map(item => <button type="button" key={item.id} className="learning-article-card" onClick={() => navigate('reader', item.id)}><div className="learning-article-card__status" data-status={item.status}>{item.status === 'completed' ? '읽음' : item.status === 'reading' ? '읽는 중' : '다음 글'}</div><h2>{item.title}</h2><span>{new URL(item.sourceUrl).hostname} · 약 {item.estimatedMinutes}분</span><small>내 단어 {item.matchedWordIds.length}개 다시 만나기</small></button>)}</div>{displayedArticles.length === 0 && <div className="learning-empty">{project.articles.length ? '선택한 조건에 맞는 글이 없어요.' : '아직 글이 없어요.'}<p>AI가 첫 글을 찾게 하거나 직접 주소를 추가하세요.</p></div>}</> : view === 'vocabulary' ? <><div className="learning-section-heading"><div><h1>나의 단어</h1></div><span className="learning-pill">{project.words.length}개</span></div><div className="learning-vocabulary-filter"><input className="text-field" type="search" aria-label="단어 검색" placeholder="단어나 뜻 찾기" value={wordQuery} onChange={event => setWordQuery(event.target.value)} /><select value={wordFilter} aria-label="단어 상태" onChange={event => setWordFilter(event.target.value as typeof wordFilter)}><option value="all">모든 단어</option><option value="new">처음 만난 단어</option><option value="learning">공부 중</option><option value="known">익숙한 단어</option></select></div><div className="learning-vocabulary-list">{displayedWords.map(word => <details key={word.id} className="learning-vocabulary-word"><summary><div><strong>{word.surface}</strong>{word.lemma !== word.surface && <small>{word.lemma}</small>}<span>{word.meaning || '뜻을 아직 적지 않았어요'}</span></div><span className="learning-pill">{word.status === 'known' ? '익숙함' : word.status === 'learning' ? '공부 중' : '새 단어'} · {project.occurrences.filter(item => item.wordId === word.id).length}개 문맥</span></summary><div className="learning-vocabulary-detail"><p className="learning-muted">{[word.pronunciation, word.partOfSpeech].filter(Boolean).join(' · ')}</p><form className="learning-word-edit" onSubmit={event => { event.preventDefault(); const form = new FormData(event.currentTarget); void perform(async () => update(await invoke('learning:updateWord', { binding, wordId: word.id, lemma: String(form.get('lemma') ?? ''), partOfSpeech: String(form.get('partOfSpeech') ?? ''), meaning: String(form.get('meaning') ?? '') }))) }}><label className="learning-field"><span>원형·표현</span><input className="text-field" name="lemma" defaultValue={word.lemma} required /></label><label className="learning-field"><span>품사</span><input className="text-field" name="partOfSpeech" defaultValue={word.partOfSpeech} placeholder="예: noun, verb" /></label><label className="learning-field"><span>나의 뜻 정리</span><input className="text-field" name="meaning" defaultValue={word.meaning} /></label><button className="button button--secondary" type="submit" disabled={pending}>저장</button></form><div className="learning-word-status-actions" aria-label={`${word.surface} 학습 상태`}>{(['new', 'learning', 'known'] as const).map(status => <button type="button" className="button button--secondary" aria-pressed={word.status === status} disabled={pending} key={status} onClick={() => void perform(async () => update(await invoke('learning:updateWord', { binding, wordId: word.id, status })))}>{status === 'known' ? '이제 알아요' : status === 'learning' ? '공부 중' : '아직 몰라요'}</button>)}</div>{project.occurrences.filter(item => item.wordId === word.id).map(occurrence => <blockquote className="learning-word-example" key={occurrence.id}><p>{occurrence.sentence}</p><form className="learning-occurrence-edit" onSubmit={event => { event.preventDefault(); const form = new FormData(event.currentTarget); void perform(async () => update(await invoke('learning:updateOccurrence', { binding, occurrenceId: occurrence.id, meaning: String(form.get('meaning') ?? '') }))) }}><label className="learning-field"><span>이 문장에서 쓰인 뜻</span><input className="text-field" name="meaning" defaultValue={occurrence.meaning} /></label><button className="learning-text-button" type="submit" disabled={pending}>예문 뜻 저장</button></form><LearningSources sources={[occurrence.sourceRef]} binding={binding} onArticle={id => navigate('reader', id)} /></blockquote>)}</div></details>)}</div>{displayedWords.length === 0 && <div className="learning-empty">{project.words.length ? '일치하는 단어가 없어요.' : '읽기 화면에서 모르는 단어를 담아보세요.'}</div>}</> : view === 'review' ? artifact ? artifact.kind === 'quiz' ? <LearningQuiz key={artifact.id} artifact={artifact} project={project} onUpdate={update} onArticle={id => navigate('reader', id)} /> : artifact.kind === 'cards' ? <LearningCards key={artifact.id} artifact={artifact} project={project} onUpdate={update} onArticle={id => navigate('reader', id)} /> : <><h1>{artifact.title}</h1><MarkdownView text={artifact.markdown} /><LearningSources sources={artifact.sourceRefs} binding={binding} onArticle={id => navigate('reader', id)} /></> : <><div className="learning-section-heading"><div><h1>퀴즈와 플래시카드</h1></div><span className="learning-pill">오늘의 카드 {due.length}</span></div><p className="learning-muted">{english ? '나의 단어와 원문 예문으로 확인해요. 원할 때 복습하세요.' : '과목 자료에서 만든 퀴즈와 카드를 풀고, 결과를 다시 확인해요.'}</p>{english && <div className="learning-form-row"><button type="button" className="button button--primary" disabled={pending || running || project.words.length === 0} onClick={() => run('create-quiz', undefined, project.words.map(word => word.id))}>내 단어로 퀴즈 만들기</button><button type="button" className="button button--secondary" disabled={pending || running || project.words.length === 0} onClick={() => run('create-cards', undefined, project.words.map(word => word.id))}>내 단어로 카드 만들기</button></div>}{!english && project.purpose === 'course-review' && <ReviewCreateActions project={project} />}<div className="learning-artifact-list">{[...project.artifacts].reverse().map(item => <button className="learning-artifact-card" type="button" key={item.id} onClick={() => navigate('review', item.id)}><span className="learning-artifact-symbol">{item.kind === 'quiz' ? '?' : item.kind === 'cards' ? '▤' : 'Aa'}</span><div><strong>{item.title}</strong><span>{item.kind === 'quiz' ? '퀴즈 풀기' : item.kind === 'cards' ? '플래시카드 복습' : '단어와 예문 정리'}</span></div><Icon name="chevronRight" /></button>)}</div>{project.artifacts.length === 0 && <div className="learning-empty">아직 복습 자료가 없어요.<p>{english ? '단어를 모아 만들거나, 기존 자료의 AI 학습 도구에서 퀴즈와 카드를 만들어 보세요.' : '위에서 원본 자료를 선택해 퀴즈나 카드를 만들어 보세요. 결과와 출처가 이곳에 쌓입니다.'}</p></div>}</> : null}
    </div></div>}
    {english && active && !settingsOpen && !showSettings && !showImport && (showGuide || !guideSeen) && <EnglishReadingGuide onClose={() => { dismissEnglishReadingGuide(); setShowGuide(false) }} onContinue={() => { dismissEnglishReadingGuide(); setShowGuide(false) }} />}
    {showSettings && <LearningCreateDialog project={project} onClose={() => setShowSettings(false)} onCreated={() => void refresh()} />}
    {showImport && <LearningMaterialImportDialog files={importFiles} relPath={importPath} pending={pending} onSelect={setImportPath} onClose={() => setShowImport(false)} onPreview={() => void perform(async () => { await invoke('learning:importPreview', { binding, relPath: importPath, sourceCourseId: project.linkedCourseId ?? binding.courseId }); setShowImport(false) })} />}
  </div>
}
