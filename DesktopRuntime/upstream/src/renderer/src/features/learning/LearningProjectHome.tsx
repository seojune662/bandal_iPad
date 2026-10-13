import { useEffect, useMemo, useState } from 'react'
import { invoke } from '../../lib/ipc'
import type { LearningSourceRef } from '../../../../shared/types/learning'
import type { LearningProjectSnapshot, LearningRunKind } from '../../../../shared/types/learning'
import type { LearningView } from '../../../../shared/tabs'
import { Icon } from '../../app/icons'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { useUiStore } from '../../stores/uiStore'
import { dueLearningCards } from './LearningReview'
import { LearningSources } from './LearningSources'
import { learningProgressMetrics } from './learningMetrics'
import { learningSourceCourse } from './learningPresentation'
import { launchNewLearning } from './learningActions'

export function ReviewCreateActions({ project }: { project: LearningProjectSnapshot }): JSX.Element {
  const courses = useCoursesStore(state => state.courses)
  const source = learningSourceCourse(project, courses)
  const options = { binding: project.binding, ...(source ? { sourceCourseId: source.id } : {}) }
  return <div className="learning-create-actions"><button type="button" className="button button--primary" onClick={() => launchNewLearning('quiz', options)}>자료 선택해서 퀴즈 만들기</button><button type="button" className="button button--secondary" onClick={() => launchNewLearning('flashcards', options)}>카드 만들기</button></div>
}

export function LearningProjectHome({ project, pending, running, onNavigate, onRun, onSettings }: {
  project: LearningProjectSnapshot
  pending: boolean
  running: boolean
  onNavigate: (view: LearningView, itemId?: string) => void
  onRun: (kind: LearningRunKind, articleIds?: string[], wordIds?: string[]) => void
  onSettings: () => void
}): JSX.Element {
  const english = project.purpose === 'english-reading'
  const review = project.purpose === 'course-review'
  const due = dueLearningCards(project)
  const metrics = learningProgressMetrics(project)
  const nextArticle = project.articles.find(item => item.status === 'reading') ?? project.articles.find(item => item.status === 'unread')
  const courses = useCoursesStore(state => state.courses)
  const linkedCourse = learningSourceCourse(project, courses)
  const latestArtifact = project.artifacts.at(-1)
  const [legacySources, setLegacySources] = useState<LearningSourceRef[]>([])
  const missingSources = useMemo(() => project.artifacts.filter(item => item.sourceRefs.length === 0).slice(-8), [project.artifacts])
  useEffect(() => {
    let stopped = false; setLegacySources([])
    void Promise.all(missingSources.map(item => invoke('learning:getArtifact', { binding: project.binding, id: item.id }).then(artifact => [...artifact.sourceRefs, ...(artifact.kind === 'quiz' ? artifact.questions.flatMap(question => question.sourceRefs) : artifact.kind === 'cards' ? artifact.cards.flatMap(card => card.sourceRefs) : [])]).catch(() => []))).then(values => { if (!stopped) setLegacySources(values.flat()) })
    return () => { stopped = true }
  }, [missingSources, project.binding.courseId, project.binding.rootRelPath])
  const sources = [...legacySources, ...project.artifacts.flatMap(item => item.sourceRefs)].filter((source, index, all) => all.findIndex(item => item.sourceCourseId === source.sourceCourseId && item.relPath === source.relPath && item.articleId === source.articleId && item.quote === source.quote) === index).slice(0, 8)
  const hasActivity = project.history.length > 0 || project.artifacts.length > 0 || project.articles.length > 0
  return <>
    <div className="learning-hero learning-hero--simple"><div>
      <h1>{english ? nextArticle ? '읽던 글을 이어가세요.' : project.articles.length ? '다음 글을 만나볼까요?' : '관심 있는 글부터 읽어보세요.' : review ? latestArtifact ? '내 자료를 다시 익혀요.' : '내 자료로 복습을 시작하세요.' : '어떤 학습 공간인지 확인해 주세요.'}</h1>
      <p className="learning-lead">{english ? `${project.topic}에 관한 영어 글을 읽고, 모르는 표현을 직접 모아요.` : review ? `${linkedCourse?.name ? `${linkedCourse.name}의 ` : ''}자료로 만든 퀴즈와 카드, 풀이 기록이 여기에 쌓입니다.` : '기존 자료와 기록은 그대로 있어요. 학습 종류를 확인하면 이어갈 수 있습니다.'}</p>
      {english ? <button type="button" className="button button--primary" disabled={pending || !nextArticle && running} onClick={() => nextArticle ? onNavigate('reader', nextArticle.id) : onRun('find-articles')}>{nextArticle ? '이어서 읽기' : project.articles.length ? '다음 글 찾기' : '첫 영어 글 찾기'} <Icon name="chevronRight" /></button>
        : review ? <ReviewCreateActions project={project} />
        : <button type="button" className="button button--primary" onClick={onSettings}>학습 종류와 AI 확인하기 <Icon name="chevronRight" /></button>}
    </div></div>
    {english && nextArticle && <button className="learning-next-article" type="button" onClick={() => onNavigate('reader', nextArticle.id)}><div><small>{nextArticle.status === 'reading' ? '읽는 중' : '읽을 글'}</small><h2>{nextArticle.title}</h2><span>약 {nextArticle.estimatedMinutes}분{nextArticle.matchedWordIds.length ? ` · 모은 표현 ${nextArticle.matchedWordIds.length}개 재등장` : ''}</span></div><Icon name="chevronRight" /></button>}
    {due.length > 0 && <button className="learning-resume-item" type="button" onClick={() => onNavigate('review', due[0]!.artifactId)}><strong>오늘 복습할 카드</strong><span>{due.length}개 복습하기 <Icon name="chevronRight" /></span></button>}
    {review && project.artifacts.length > 0 && <section className="learning-home-section"><div className="learning-section-heading"><h2>최근 만든 학습 자료</h2><button type="button" className="learning-text-button" onClick={() => onNavigate('review')}>모두 보기</button></div><div className="learning-artifact-list">{project.artifacts.slice(-3).reverse().map(item => <button type="button" className="learning-artifact-card" key={item.id} onClick={() => onNavigate('review', item.id)}><div><strong>{item.title}</strong><span>{item.kind === 'quiz' ? '퀴즈 풀기' : item.kind === 'cards' ? '카드 복습하기' : '정리 읽기'}</span></div><Icon name="chevronRight" /></button>)}</div></section>}
    {hasActivity && <div className="learning-insights learning-insights--compact">{english && <><div><strong>{project.articles.filter(item => item.status === 'completed').length}</strong><span>읽은 글</span></div><div><strong>{project.words.length}</strong><span>모은 표현</span></div><div><strong>{metrics.encounteredWordCount}</strong><span>다른 글에서 다시 만난 표현</span></div></>}<div><strong>{metrics.reviewedCardCount}</strong><span>복습한 카드</span></div>{metrics.latestQuiz && <div><strong>{metrics.latestQuiz.score} / {metrics.latestQuiz.total}</strong><span>최근 퀴즈 자동 채점 · 자기 확인 {metrics.latestQuiz.selfPassedCount} / {metrics.latestQuiz.selfCheckedCount}</span></div>}</div>}
    {review && sources.length > 0 && <section className="learning-review-sources"><div className="learning-section-heading"><h2>원본 자료</h2>{linkedCourse && <button className="learning-text-button" type="button" onClick={() => { useCoursesStore.getState().selectCourse(linkedCourse.id); useWorkspaceStore.getState().showCourseWorkspace(linkedCourse.id); useUiStore.getState().showCourses() }}>원본 과목 열기 <Icon name="chevronRight" /></button>}</div><LearningSources sources={sources} binding={project.binding} onArticle={id => onNavigate('reader', id)} /></section>}
    {project.history.length > 0 && <section className="learning-home-section"><div className="learning-section-heading"><h2>최근 학습 기록</h2>{english && project.words.length > 0 && <button className="learning-text-button" type="button" disabled={pending || running} onClick={() => onRun('create-summary', undefined, project.words.map(word => word.id))}>단어와 예문 정리하기</button>}</div><ol className="learning-history">{project.history.slice(-5).reverse().map(item => <li key={item.id}><span>{item.summary}</span><time>{new Date(item.createdAt).toLocaleDateString('ko-KR')}</time></li>)}</ol></section>}
  </>
}
