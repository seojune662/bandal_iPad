import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { LearningProjectSnapshot, LearningProjectSummary } from '../../../../shared/types/learning'
import { Icon } from '../../app/icons'
import { invoke } from '../../lib/ipc'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useUiStore } from '../../stores/uiStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { LearningCreateDialog } from './LearningCreateDialog'
import { LearningGenerationDialog, type LearningGenerationRequest } from './LearningGenerationDialog'
import { useLearningProjects } from './LearningProjects'
import { learningError, notifyLearningChanged, openLearning } from './learningNavigation'
import { StudyToolMenu } from '../study/StudyToolMenu'
import { STUDY_PALETTE_EVENT, type StudyPaletteRequest } from '../study/studyPaletteEvents'

const CREATE_EVENT = 'bandal:learning-create'
const IMPORT_EVENT = 'bandal:learning-import'
const PICK_EVENT = 'bandal:learning-pick'
const GENERATE_EVENT = 'bandal:learning-generate'
interface CreationRequest { courseId?: string; packId?: string; project?: LearningProjectSnapshot }
interface ArticleImportRequest { courseId: string; url: string; tabId?: string; packId?: string }

export function requestLearningCreation(courseId?: string, packId?: string, project?: LearningProjectSnapshot): void {
  window.dispatchEvent(new CustomEvent(CREATE_EVENT, { detail: { ...(courseId ? { courseId } : {}), ...(packId ? { packId } : {}), ...(project ? { project } : {}) } }))
}
export function requestLearningGeneration(input: LearningGenerationRequest): void { window.dispatchEvent(new CustomEvent(GENERATE_EVENT, { detail: input })) }
export function requestLearningArticleImport(input: ArticleImportRequest): void {
  window.dispatchEvent(new CustomEvent(IMPORT_EVENT, { detail: input }))
}
export function requestLearningProjectPicker(projects: LearningProjectSummary[]): void {
  window.dispatchEvent(new CustomEvent(PICK_EVENT, { detail: projects }))
}

export function LearningDialogsHost(): JSX.Element | null {
  const [creating, setCreating] = useState<CreationRequest | null>(null)
  const [generating, setGenerating] = useState<LearningGenerationRequest | null>(null)
  const [generationKey, setGenerationKey] = useState(0)
  const [importing, setImporting] = useState<ArticleImportRequest | null>(null)
  const [picking, setPicking] = useState<LearningProjectSummary[] | null>(null)
  const [studying, setStudying] = useState<StudyPaletteRequest | null>(null)
  useEffect(() => {
    const create = (event: Event): void => { if (event instanceof CustomEvent) setCreating(event.detail as CreationRequest) }
    const generate = (event: Event): void => { if (event instanceof CustomEvent) { setGenerating(event.detail as LearningGenerationRequest); setGenerationKey(key => key + 1) } }
    const importArticle = (event: Event): void => { if (event instanceof CustomEvent) setImporting(event.detail as ArticleImportRequest) }
    const pick = (event: Event): void => { if (event instanceof CustomEvent) setPicking(event.detail as LearningProjectSummary[]) }
    const study = (event: Event): void => { if (event instanceof CustomEvent) setStudying(event.detail as StudyPaletteRequest) }
    window.addEventListener(GENERATE_EVENT, generate); window.addEventListener(CREATE_EVENT, create); window.addEventListener(IMPORT_EVENT, importArticle); window.addEventListener(PICK_EVENT, pick)
    window.addEventListener(STUDY_PALETTE_EVENT, study)
    return () => { window.removeEventListener(GENERATE_EVENT, generate); window.removeEventListener(CREATE_EVENT, create); window.removeEventListener(IMPORT_EVENT, importArticle); window.removeEventListener(PICK_EVENT, pick); window.removeEventListener(STUDY_PALETTE_EVENT, study) }
  }, [])
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  useEffect(() => { if (settingsOpen || (!creating && !importing && !picking && !generating)) return; return acquirePointerPassthrough() }, [creating, importing, picking, generating, settingsOpen])
  return creating ? <LearningCreateDialog {...creating} onClose={() => setCreating(null)} /> : generating ? <LearningGenerationDialog key={generationKey} request={generating} onClose={() => setGenerating(null)} /> : importing ? <ArticleImportDialog input={importing} onClose={() => setImporting(null)} /> : picking ? <ProjectPicker projects={picking} onClose={() => setPicking(null)} /> : studying ? <StudyToolMenu request={studying} onClose={() => setStudying(null)} /> : null
}

function ProjectPicker({ projects, onClose }: { projects: LearningProjectSummary[]; onClose: () => void }): JSX.Element {
  const root = useRef<HTMLElement>(null)
  useFocusTrap(root, { active: true, onEscape: onClose })
  return createPortal(<div className="dialog-backdrop" onMouseDown={event => { if (event.target === event.currentTarget) onClose() }}>
    <section ref={root} className="course-dialog learning-create" role="dialog" aria-modal="true" aria-label="이어갈 학습 공간 선택">
      <header className="course-dialog__header"><h2>어디서 이어갈까요?</h2><button type="button" className="bare-icon-button" aria-label="닫기" onClick={onClose}><Icon name="x" /></button></header>
      <div className="learning-project-grid">{projects.map(project => <button type="button" className="learning-project-card" key={`${project.binding.courseId}:${project.binding.rootRelPath}`} onClick={() => { openLearning(project.binding); onClose() }}><strong>{project.name}</strong><span>{project.topic}</span></button>)}</div>
    </section>
  </div>, document.body)
}

function ArticleImportDialog({ input, onClose }: { input: ArticleImportRequest; onClose: () => void }): JSX.Element {
  const { projects: allProjects, loading } = useLearningProjects()
  const projects = allProjects.filter(project => project.purpose === 'english-reading')
  const courses = useCoursesStore(state => state.courses)
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const projectKey = (binding: { courseId: string; rootRelPath: string }): string => `${binding.courseId}:${binding.rootRelPath}`
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const root = useRef<HTMLElement>(null)
  useFocusTrap(root, { active: !creating, onEscape: pending ? undefined : onClose })
  const selected = selectedKey === null ? projects.find(project => project.binding.courseId === input.courseId) ?? projects[0] : projects.find(project => projectKey(project.binding) === selectedKey)
  const add = async (): Promise<void> => {
    if (!selected) return
    setPending(true); setError(null)
    try {
      const project = await invoke('learning:addArticle', { binding: selected.binding, url: input.url, ...(input.tabId ? { tabId: input.tabId } : {}), sourceCourseId: input.courseId })
      if (!project.articles.some(item => item.id === project.addedArticleId)) throw new Error('저장한 기사 식별자를 찾지 못했어요.')
      notifyLearningChanged(); openLearning(project.binding, 'reader', project.addedArticleId); onClose()
    }
    catch (caught) { setError(learningError(caught)); setPending(false) }
  }
  if (creating) return <LearningCreateDialog courseId={input.courseId} {...(input.packId ? { packId: input.packId } : {})} onCreated={binding => setSelectedKey(projectKey(binding))} onClose={() => setCreating(false)} />
  return createPortal(<div className="dialog-backdrop" onMouseDown={event => { if (event.target === event.currentTarget && !pending) onClose() }}><section ref={root} className="course-dialog learning-create" role="dialog" aria-modal="true" aria-label="기사를 학습에 추가"><header className="course-dialog__header"><div><p className="eyebrow">READ IT YOUR WAY</p><h2>이 글을 학습에 추가하기</h2></div><button className="bare-icon-button" type="button" aria-label="닫기" disabled={pending} onClick={onClose}><Icon name="x" /></button></header><p className="learning-muted">원문을 읽기 화면에 보관하고, 모르는 단어와 예문을 쌓아갈 수 있어요.</p><p className="learning-import-url">{input.url}</p>{loading ? <p role="status">학습 공간 불러오는 중…</p> : projects.length > 0 ? <label className="learning-field"><span>자료를 쌓을 학습 공간</span><select value={selected ? projectKey(selected.binding) : ''} disabled={pending} onChange={event => setSelectedKey(event.target.value)}>{projects.map(project => <option value={projectKey(project.binding)} key={projectKey(project.binding)}>{project.name}{project.binding.courseId !== input.courseId ? ` · ${courses.find(course => course.id === project.binding.courseId)?.name ?? '다른 과목'}` : ''}</option>)}</select></label> : <p className="learning-muted">먼저 이 글을 담을 학습 공간을 만들어 주세요.</p>}<button className="learning-text-button" type="button" disabled={pending} onClick={() => setCreating(true)}><Icon name="plus" /> 새 학습 공간 만들기</button>{error && <p className="learning-error" role="alert">{error}</p>}<footer className="dialog-actions"><button className="button button--secondary" type="button" disabled={pending} onClick={onClose}>취소</button><button className="button button--primary" type="button" disabled={pending || !selected} onClick={() => void add()}>{pending ? '글을 읽기 화면에 담는 중…' : '학습에 추가'}</button></footer></section></div>, document.body)
}
