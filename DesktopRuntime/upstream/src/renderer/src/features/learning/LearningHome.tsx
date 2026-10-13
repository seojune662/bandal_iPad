import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { LearningBinding, LearningProjectSummary } from '../../../../shared/types/learning'
import { showToast } from '../../app/toast'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import { invoke } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { openChosenAssistant } from '../assistantPanel/assistantController'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { LearningProjectGroups, useLearningProjects } from './LearningProjects'
import { LearningStartActions } from './NewLearningDialog'
import { restoreLearningSpace } from './LearningSpaceManagement'
import { dueLearningCards } from './LearningReview'
import { learningDisplayName } from './learningPresentation'
import { learningError, openLearning } from './learningNavigation'
import './learning.css'

export default function LearningHome(): JSX.Element {
  const { projects: all, loading, error, reload } = useLearningProjects(undefined, true)
  const courses = useCoursesStore(state => state.courses)
  const mounted = useRef(true)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  const [showDeleted, setShowDeleted] = useState(false)
  const [chooseAi, setChooseAi] = useState(false)
  const [pending, setPending] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const projects = all.filter(project => !project.deletedAt)
  const removed = all.filter(project => project.deletedAt)
  const due = projects.filter(project => project.dueCardCount > 0)
  const recent = [...projects].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)).slice(0, 3)
  useEffect(() => { const choose = (): void => setChooseAi(true); window.addEventListener('bandal:choose-ai-context', choose); return () => window.removeEventListener('bandal:choose-ai-context', choose) }, [])
  const resume = async (summary: LearningProjectSummary, review = false): Promise<void> => {
    setPending(true); setActionError(null)
    try {
      const project = await invoke('learning:get', { binding: summary.binding })
      if (!mounted.current) return
      const card = dueLearningCards(project)[0]
      const article = project.articles.find(item => item.status === 'reading') ?? project.articles.find(item => item.status === 'unread')
      const unfinished = [...project.quizAttempts].reverse().find(item => !item.completedAt)
      if (review && card) openLearning(project.binding, 'review', card.artifactId)
      else if (project.purpose === 'english-reading' && article) openLearning(project.binding, 'reader', article.id)
      else if (unfinished) openLearning(project.binding, 'review', unfinished.artifactId)
      else openLearning(project.binding)
    } catch (caught) { setActionError(learningError(caught)) }
    finally { setPending(false) }
  }
  const restore = async (project: LearningProjectSummary): Promise<void> => {
    setPending(true); setActionError(null)
    try { await restoreLearningSpace(project); await reload() }
    catch (caught) { setActionError(learningError(caught)) }
    finally { setPending(false) }
  }
  return <main id="learning-home" className="learning-panel learning-global-home" aria-label="학습 홈"><div className="learning-content-scroll"><div className="learning-page">
    <header className="learning-home-heading"><h1>학습</h1><p className="learning-lead">읽고, 풀고, 기억하는 나의 학습을 여기서 이어가세요.</p></header>
    <section aria-label="새 학습"><h2>새 학습</h2><LearningStartActions /></section>
    {loading && <p className="learning-muted" role="status">학습 기록 불러오는 중…</p>}
    {(error || actionError) && <p className="learning-error" role="alert">{error ?? actionError} <button className="learning-text-button" type="button" onClick={() => void reload()}>다시 불러오기</button></p>}
    {recent.length > 0 && <section className="learning-home-section" aria-label="이어서 학습하기"><h2>이어서 학습하기</h2><div className="learning-resume-list">{recent.map(project => <button className="learning-resume-item" type="button" key={`${project.binding.courseId}:${project.binding.rootRelPath}`} disabled={pending} onClick={() => void resume(project)}><span><strong>{learningDisplayName(project, courses)}</strong><small>{project.purpose === 'english-reading' ? project.topic : '퀴즈와 카드, 풀이 기록'}</small></span><span>{project.purpose === 'english-reading' ? '이어서 읽기' : '학습 이어가기'} <Icon name="chevronRight" /></span></button>)}</div></section>}
    {due.length > 0 && <section className="learning-home-section" aria-label="오늘 복습할 카드"><h2>오늘 복습할 카드</h2>{due.map(project => <button className="learning-resume-item" type="button" key={`${project.binding.courseId}:${project.binding.rootRelPath}`} disabled={pending} onClick={() => void resume(project, true)}><strong>{learningDisplayName(project, courses)}</strong><span>{project.dueCardCount}개 복습하기 <Icon name="chevronRight" /></span></button>)}</section>}
    <section className="learning-home-section" aria-label="모든 학습 공간"><h2>나의 학습 공간</h2><LearningProjectGroups projects={projects} /></section>
    <footer className="learning-home-footer"><button className="learning-text-button" type="button" aria-expanded={showDeleted} onClick={() => setShowDeleted(value => !value)}><Icon name="trash" /> 삭제한 학습{removed.length ? ` (${removed.length})` : ''}</button></footer>
    {showDeleted && <section className="learning-removed-list" aria-label="삭제한 학습"><p className="learning-muted">목록에서 삭제한 공간입니다. 파일과 기록은 보존되어 있어요.</p>{removed.length === 0 ? <p className="learning-muted">삭제한 학습이 없어요.</p> : removed.map(project => <div className="learning-resume-item" key={`${project.binding.courseId}:${project.binding.rootRelPath}`}><strong>{learningDisplayName(project, courses)}</strong><button type="button" className="button button--secondary" disabled={pending} onClick={() => void restore(project)}>복원</button></div>)}</section>}
  </div></div>{chooseAi && <LearningAiContextPicker projects={projects} onClose={() => setChooseAi(false)} />}</main>
}

function LearningAiContextPicker({ projects, onClose }: { projects: LearningProjectSummary[]; onClose: () => void }): JSX.Element {
  const courses = useCoursesStore(state => state.courses)
  const root = useRef<HTMLElement>(null)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useFocusTrap(root, { active: true, onEscape: pending ? undefined : onClose })
  useEffect(() => acquirePointerPassthrough(), [])
  const choose = async (courseId: string, binding?: LearningBinding): Promise<void> => {
    setPending(true); setError(null)
    try { await openChosenAssistant({ courseId, ...(binding ? { binding } : {}) }); onClose() }
    catch (caught) { setError(learningError(caught)); showToast(learningError(caught), 'danger'); setPending(false) }
  }
  const originalCourses = courses.filter(course => !course.archived && course.workspaceKind !== 'study-space')
  return createPortal(<div className="dialog-backdrop"><section ref={root} role="dialog" aria-modal="true" aria-label="AI와 대화할 곳 선택" className="course-dialog learning-start-dialog"><header className="course-dialog__header"><h2>어떤 학습에 대해 이야기할까요?</h2><button type="button" className="bare-icon-button" aria-label="닫기" disabled={pending} onClick={onClose}><Icon name="x" /></button></header><p className="learning-muted">선택한 곳의 AI 대화를 이어갑니다.</p><div className="learning-ai-context-list">
    {projects.length > 0 && <h3>학습 공간</h3>}{projects.map(project => <button type="button" className="learning-resume-item" disabled={pending} key={`${project.binding.courseId}:${project.binding.rootRelPath}`} onClick={() => void choose(project.binding.courseId, project.binding)}>{learningDisplayName(project, courses)}<Icon name="chevronRight" /></button>)}
    {originalCourses.length > 0 && <h3>과목</h3>}{originalCourses.map(course => <button type="button" className="learning-resume-item" disabled={pending} key={course.id} onClick={() => void choose(course.id)}>{course.name}<Icon name="chevronRight" /></button>)}
    {!projects.length && !originalCourses.length && <p className="learning-muted">새 학습을 만들거나 과목을 추가하면 AI와 대화할 수 있어요.</p>}
    </div>{error && <p className="learning-error" role="alert">{error}</p>}</section></div>, document.body)
}
