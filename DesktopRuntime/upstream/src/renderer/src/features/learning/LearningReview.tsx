import { useEffect, useMemo, useRef, useState } from 'react'
import type { LearningArtifact, LearningCardRating, LearningProjectSnapshot, LearningQuizAttempt } from '../../../../shared/types/learning'
import { invoke } from '../../lib/ipc'
import { Icon } from '../../app/icons'
import { MarkdownView } from '../chat/MarkdownView'
import { LearningSources } from './LearningSources'
import { learningError, notifyLearningChanged } from './learningNavigation'

export function dueLearningCards(project: LearningProjectSnapshot, now = Date.now()): typeof project.cards {
  return project.cards.filter(card => card.status === 'new' || Date.parse(card.dueAt) <= now).sort((a, b) => a.dueAt.localeCompare(b.dueAt))
}

export function quizCanFinish(artifact: Extract<LearningArtifact, { kind: 'quiz' }>, attempt: LearningQuizAttempt | undefined, drafts?: Record<string, string>): boolean {
  return artifact.questions.every(question => { const answer = attempt?.answers.find(item => item.questionId === question.id)
    const value = drafts?.[question.id] ?? answer?.answer
    return Boolean(value?.trim()) && (question.type !== 'short-answer' || answer?.selfCheck !== undefined && value === answer.answer)
  })
}

export function LearningQuiz({ artifact, project, onUpdate, onArticle }: { artifact: Extract<LearningArtifact, { kind: 'quiz' }>; project: LearningProjectSnapshot; onUpdate: (value: LearningProjectSnapshot) => void; onArticle: (id: string) => void }): JSX.Element {
  const previous = [...project.quizAttempts].reverse().find(item => item.artifactId === artifact.id)
  const [attemptId, setAttemptId] = useState(previous?.id ?? crypto.randomUUID())
  const attempt = project.quizAttempts.find(item => item.id === attemptId)
  const [drafts, setDrafts] = useState<Record<string, string>>(() => Object.fromEntries(previous?.answers.map(item => [item.questionId, item.answer]) ?? []))
  const [revealed, setRevealed] = useState<Set<string>>(() => new Set(previous?.answers.filter(item => item.selfCheck !== undefined).map(item => item.questionId)))
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const completed = attempt?.completedAt !== null && attempt?.completedAt !== undefined
  const saveQueue = useRef<Promise<void>>(Promise.resolve())
  const failedAnswers = useRef(new Map<string, { answer: string; selfCheck?: boolean; error: string }>())
  const finishing = useRef(false)
  const save = (questionId: string, answer: string, selfCheck?: boolean): Promise<void> => {
    const request = saveQueue.current.catch(() => {}).then(async () => {
      try {
        const next = await invoke('learning:saveQuizAnswer', { binding: project.binding, artifactId: artifact.id, attemptId, questionId, answer, ...(selfCheck === undefined ? {} : { selfCheck }) })
        failedAnswers.current.delete(questionId)
        setError(failedAnswers.current.values().next().value?.error ?? null)
        onUpdate(next)
      } catch (caught) {
        const error = learningError(caught)
        failedAnswers.current.set(questionId, { answer, ...(selfCheck === undefined ? {} : { selfCheck }), error })
        setError(error)
        throw caught
      }
    })
    saveQueue.current = request
    void request.catch(() => {})
    return request
  }
  const finish = async (grade = true): Promise<void> => {
    if (finishing.current) return
    finishing.current = true
    setPending(true); setError(null)
    try {
      await saveQueue.current.catch(() => {})
      // A later answer's successful save must not permit grading an older failed draft.
      for (const [questionId, draft] of [...failedAnswers.current]) await save(questionId, draft.answer, draft.selfCheck)
      if (grade) {
        const next = await invoke('learning:finishQuiz', { binding: project.binding, artifactId: artifact.id, attemptId })
        onUpdate(next); notifyLearningChanged()
      }
    } catch (caught) { setError(learningError(caught)) }
    finally { finishing.current = false; setPending(false) }
  }

  return <div className="learning-quiz"><div className="learning-section-heading"><div><p className="learning-eyebrow">CHECK YOUR UNDERSTANDING</p><h2>{artifact.title}</h2></div><span className="learning-pill">{artifact.questions.length}문제</span></div>
    <p className="learning-muted">답은 자동 저장됩니다. 객관식과 빈칸은 채점하고, 단답형은 모범 답안과 비교해 스스로 확인해요.</p>
    {completed && <div className="learning-result" role="status"><strong>자동 채점 {attempt.score} / {attempt.total}</strong><span>단답형 자기 확인 {attempt.selfPassedCount} / {attempt.selfCheckedCount}</span><button className="button button--secondary" type="button" onClick={() => { setAttemptId(crypto.randomUUID()); setDrafts({}); setRevealed(new Set()); setError(null) }}>다시 풀기</button></div>}
    {artifact.questions.map((question, index) => {
      const answer = attempt?.answers.find(item => item.questionId === question.id)
      const value = drafts[question.id] ?? answer?.answer ?? ''
      const showsAnswer = completed || (question.type === 'short-answer' && revealed.has(question.id))
      return <section className="learning-question" key={question.id}><div className="learning-question-number">{String(index + 1).padStart(2, '0')}</div><div className="learning-question-body"><MarkdownView text={question.prompt} />
        {question.type === 'choice' ? <fieldset className="learning-choices" disabled={completed || pending}><legend className="sr-only">{index + 1}번 답 고르기</legend>{question.options?.map(option => <label key={option.id} data-selected={value === option.id}><input type="radio" name={`${attemptId}-${question.id}`} value={option.id} checked={value === option.id} onChange={() => { setDrafts(current => ({ ...current, [question.id]: option.id })); void save(question.id, option.id) }} /><span>{option.text}</span></label>)}</fieldset> : <label className="learning-field"><span className="sr-only">{index + 1}번 답 입력</span><textarea aria-label={`${index + 1}번 답 입력`} rows={question.type === 'short-answer' ? 3 : 1} value={value} placeholder="나의 답" disabled={completed || pending} onChange={event => { const text = event.target.value; setDrafts(current => ({ ...current, [question.id]: text })); void save(question.id, text) }} /></label>}
        {question.type === 'short-answer' && !showsAnswer && <button className="button button--secondary" type="button" disabled={!value.trim() || pending} onClick={() => setRevealed(current => new Set([...current, question.id]))}>모범 답안과 비교하기</button>}
        {showsAnswer && <div className="learning-answer" data-correct={question.type !== 'short-answer' ? answer?.correct : undefined}><strong>{question.type === 'short-answer' ? '모범 답안' : answer?.correct ? '맞았어요' : '다시 확인해요'}</strong><MarkdownView text={question.type === 'short-answer' ? (question.modelAnswer ?? question.answer) : question.type === 'choice' ? (question.options?.find(item => item.id === question.answer)?.text ?? question.answer) : question.answer} /><MarkdownView text={question.explanation} />{question.checkingPoints && <ul>{question.checkingPoints.map(point => <li key={point}>{point}</li>)}</ul>}
          {question.type === 'short-answer' && !completed && <div className="learning-self-check" aria-label="내 답 스스로 확인"><button className="button button--secondary" type="button" aria-pressed={answer?.selfCheck === true} disabled={pending} onClick={() => void save(question.id, value, true)}>잘 설명했어요</button><button className="button button--secondary" type="button" aria-pressed={answer?.selfCheck === false} disabled={pending} onClick={() => void save(question.id, value, false)}>다시 공부할래요</button></div>}
          <LearningSources sources={question.sourceRefs} binding={project.binding} onArticle={onArticle} /></div>}
      </div></section>
    })}
    {error && <div className="learning-error" role="alert">{error}{failedAnswers.current.size > 0 && <button className="button button--secondary" type="button" disabled={pending} onClick={() => void finish(false)}>답 다시 저장</button>}</div>}{!completed && <footer className="learning-review-footer"><span className="learning-muted">모든 문제에 답하고 단답형 자기 확인을 마치면 결과를 볼 수 있어요.</span><button className="button button--primary" type="button" disabled={pending || !quizCanFinish(artifact, attempt, drafts)} onClick={() => void finish()}>{pending ? '결과 저장 중…' : '채점하고 정답 보기'}</button></footer>}
  </div>
}

export function LearningCards({ artifact, project, onUpdate, onArticle }: { artifact: Extract<LearningArtifact, { kind: 'cards' }>; project: LearningProjectSnapshot; onUpdate: (value: LearningProjectSnapshot) => void; onArticle: (id: string) => void }): JSX.Element {
  const definitionIds = useMemo(() => new Set(artifact.cards.map(card => card.id)), [artifact.cards])
  const [queue, setQueue] = useState(() => dueLearningCards(project).filter(card => definitionIds.has(card.id)).map(card => card.id))
  const [index, setIndex] = useState(0)
  const [flipped, setFlipped] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const card = project.cards.find(item => item.id === queue[index])
  const ratingPending = useRef(false)
  const reviewed = useMemo(() => project.cards.filter(item => definitionIds.has(item.id) && item.lastReviewedAt), [project.cards, definitionIds])
  useEffect(() => { setFlipped(false) }, [index])
  const rate = async (rating: LearningCardRating): Promise<void> => {
    if (!card || ratingPending.current) return
    ratingPending.current = true
    setPending(true); setError(null)
    try { const next = await invoke('learning:reviewCard', { binding: project.binding, cardId: card.id, rating, reviewId: crypto.randomUUID() }); onUpdate(next); notifyLearningChanged(); setIndex(value => value + 1) }
    catch (caught) { setError(learningError(caught)) }
    finally { ratingPending.current = false; setPending(false) }
  }
  return <div className="learning-card-review"><div className="learning-section-heading"><div><p className="learning-eyebrow">A LITTLE REVIEW, A LASTING MEMORY</p><h2>{artifact.title}</h2></div><span className="learning-pill">{card ? `${index + 1} / ${queue.length}` : '복습 완료'}</span></div>
    {card ? <><button className="learning-flashcard" type="button" aria-label={flipped ? '카드 앞면 보기' : '카드 답 확인'} onClick={() => setFlipped(value => !value)}><span className="learning-eyebrow">{flipped ? 'ANSWER' : 'QUESTION'}</span><MarkdownView text={flipped ? card.back : card.front} /><small>{flipped ? '클릭하면 앞면으로' : '생각해 본 뒤 클릭해서 확인'}</small></button>{flipped ? <><LearningSources sources={card.sourceRefs} binding={project.binding} onArticle={onArticle} /><div className="learning-card-ratings" aria-label="기억 정도"><button type="button" disabled={pending} onClick={() => void rate('again')}>기억 안 남<small>다시 만나기</small></button><button type="button" disabled={pending} onClick={() => void rate('hard')}>어렵게 기억<small>조금 더 연습</small></button><button type="button" disabled={pending} onClick={() => void rate('good')}>기억함<small>간격 늘리기</small></button></div></> : <p className="learning-muted learning-centered">정답을 확인한 뒤 기억 정도를 골라주세요.</p>}</> : <div className="learning-empty learning-review-complete"><Icon name="graph" /><h3>오늘의 복습을 마쳤어요.</h3><p>다음 복습 시간은 기억 정도에 맞춰 저장됩니다.</p><button className="button button--secondary" type="button" onClick={() => { setQueue(artifact.cards.map(item => item.id)); setIndex(0); setFlipped(false) }}>모든 카드 미리 복습하기</button>{reviewed.length > 0 && <small>{reviewed.length}개의 카드에 복습 기록이 있어요.</small>}</div>}
    {error && <p className="learning-error" role="alert">{error}</p>}
  </div>
}
