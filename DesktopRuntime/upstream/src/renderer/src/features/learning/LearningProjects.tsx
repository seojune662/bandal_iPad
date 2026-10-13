import { useCallback, useEffect, useRef, useState } from 'react'
import type { LearningProjectSummary } from '../../../../shared/types/learning'
import { Icon } from '../../app/icons'
import { invoke, onPush } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { NewLearningDialog } from './NewLearningDialog'
import { LearningSpaceMenu } from './LearningSpaceManagement'
import { learningDisplayName, learningSourceCourse } from './learningPresentation'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { learningPurpose } from './learningPurpose'
import { LEARNING_CHANGED_EVENT, learningError, openLearning, rememberEnglishBinding } from './learningNavigation'
import './learning.css'

export function useLearningProjects(courseId?: string, includeDeleted = false): { projects: LearningProjectSummary[]; loading: boolean; error: string | null; reload: () => Promise<void> } {
  const [projects, setProjects] = useState<LearningProjectSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const sequence = useRef(0)
  const reload = useCallback(async () => {
    const request = ++sequence.current
    try { const result = await invoke('learning:list', { ...(courseId ? { courseId } : {}), ...(includeDeleted ? { includeDeleted: true } : {}) }); if (request === sequence.current) { setProjects(result.projects); setError(null) } }
    catch (caught) { if (request === sequence.current) setError(learningError(caught)) }
    finally { if (request === sequence.current) setLoading(false) }
  }, [courseId, includeDeleted])
  useEffect(() => { setLoading(true); let disposed = false
    const load = (): void => { if (!disposed) void reload() }
    load(); window.addEventListener(LEARNING_CHANGED_EVENT, load)
    const stop = onPush('learning:changed', () => { load() })
    const stopCourses = onPush('courses:changed', load)
    const stopMaterials = onPush('materials:changed', event => { if (!courseId || event.courseId === courseId) load() })
    return () => { disposed = true; sequence.current += 1; stop(); stopMaterials(); stopCourses(); window.removeEventListener(LEARNING_CHANGED_EVENT, load) }
  }, [reload])
  return { projects, loading, error, reload }
}

export function LearningProjectGroups({ projects, compact = false }: { projects: LearningProjectSummary[]; compact?: boolean }): JSX.Element {
  const groups = [
    { purpose: 'english-reading', title: '영어 이어읽기', empty: '관심 있는 주제로 영어 글 읽기를 시작해 보세요.' },
    { purpose: 'course-review', title: '과목 복습', empty: '새 학습에서 자료로 퀴즈나 카드를 만들어 보세요.' },
    { purpose: 'unclassified', title: '종류 확인 필요', empty: '' }
  ]
  return <>{groups.map(group => {
    const items = projects.filter(project => !project.deletedAt && learningPurpose(project) === group.purpose).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    if (!items.length && group.purpose === 'unclassified') return null
    return <section className="learning-space-group" aria-label={group.title} key={group.purpose}><h3>{group.title}<small>{items.length}</small></h3>
      <div className={compact ? 'learning-spaces-list' : 'learning-project-grid'}>{items.map(project => <LearningProjectRow key={`${project.binding.courseId}:${project.binding.rootRelPath}`} project={project} compact={compact} />)}</div>{!items.length && <p className="learning-muted">{group.empty}</p>}
    </section>
  })}</>
}

function LearningProjectRow({ project, compact }: { project: LearningProjectSummary; compact: boolean }): JSX.Element {
  const courses = useCoursesStore(state => state.courses)
  const active = useWorkspaceStore(state => state.activeTabDescriptor())
  const [contextRequest, setContextRequest] = useState(0)
  const selected = active?.kind === 'learning' && active.payload.courseId === project.binding.courseId && active.payload.rootRelPath === project.binding.rootRelPath
  const source = learningSourceCourse(project, courses)
  const subtitle = project.purpose === 'course-review' ? source ? `${source.name}의 퀴즈와 카드` : '원본 과목 연결을 확인해 주세요' : project.purpose === 'unclassified' ? '기존 기록의 학습 종류를 확인해 주세요' : project.topic
  return <div className={`${compact ? 'learning-space-row' : 'learning-project-card'} learning-space-item`} data-selected={selected} onContextMenu={event => { event.preventDefault(); setContextRequest(value => value + 1) }}>
    <button className="learning-space-open" type="button" aria-current={selected ? 'page' : undefined} onClick={() => { if (project.purpose === 'english-reading' && project.readingSetupConfirmed) rememberEnglishBinding(project.binding); openLearning(project.binding) }}>
      <strong>{learningDisplayName(project, courses)}</strong><span>{subtitle}</span>
      {(project.completedArticleCount > 0 || project.wordCount > 0 || project.dueCardCount > 0) && <small>{[project.completedArticleCount > 0 ? `읽은 글 ${project.completedArticleCount}` : '', project.wordCount > 0 ? `표현 ${project.wordCount}` : '', project.dueCardCount > 0 ? `오늘 복습 ${project.dueCardCount}` : ''].filter(Boolean).join(' · ')}</small>}
      {project.warning && <em>{project.warning}</em>}
    </button><LearningSpaceMenu project={project} contextRequest={contextRequest} />
  </div>
}

export function LearningProjectsHome({ courseId }: { courseId: string }): JSX.Element {
  const { projects, loading, error, reload } = useLearningProjects(courseId)
  const [creating, setCreating] = useState(false)
  return <div className="learning-panel"><div className="learning-page learning-projects-home"><h1>학습 공간</h1><p className="learning-lead">읽고 싶은 글과 복습할 자료를 골라 시작하세요.</p><button className="button button--primary" type="button" onClick={() => setCreating(true)}><Icon name="plus" /> 새 학습</button>
    {loading && <p role="status" className="learning-muted">학습 공간 불러오는 중…</p>}{error && <p role="alert">{error} <button type="button" onClick={() => void reload()}>다시 시도</button></p>}
    <LearningProjectGroups projects={projects} />
  </div>{creating && <NewLearningDialog onClose={() => setCreating(false)} />}</div>
}
