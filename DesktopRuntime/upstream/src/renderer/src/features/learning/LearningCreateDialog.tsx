import { startLearningRun } from './learningStartedRuns'
import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { LearningAiSettings, LearningBinding, LearningLevel, LearningProjectSnapshot, LearningPurpose } from '../../../../shared/types/learning'
import { LEARNING_TOPICS } from '../../../../shared/types/learning'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { useUiStore } from '../../stores/uiStore'
import { useFocusTrap } from '../../components/useFocusTrap'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { useCoursesStore } from '../../stores/coursesStore'
import { LearningAISelector } from './LearningAISelector'
import { EnglishReadingGuide } from './EnglishReadingGuide'
import { dismissEnglishReadingGuide, useEnglishReadingGuideSeen } from './englishReadingGuideState'
import { learningError, notifyLearningChanged, openLearning, rememberEnglishBinding } from './learningNavigation'
import './learning.css'

export interface LearningCreateDialogProps {
  courseId?: string
  packId?: string
  project?: LearningProjectSnapshot
  onClose: () => void
  onCreated?: (binding: LearningBinding) => void
}

export function LearningCreateDialog(props: LearningCreateDialogProps): JSX.Element {
  const guideSeen = useEnglishReadingGuideSeen()
  if (!props.project && !guideSeen) return <EnglishReadingGuide creating onContinue={dismissEnglishReadingGuide} onClose={() => { dismissEnglishReadingGuide(); props.onClose() }} />
  return <LearningCreateForm {...props} />
}

function LearningCreateForm({ packId, project, onClose, onCreated }: LearningCreateDialogProps): JSX.Element {
  const owner = useCoursesStore(state => state.courses.find(course => course.id === project?.binding.courseId))
  const [classifyStandalone, setClassifyStandalone] = useState(false)
  const canClassifyStandalone = !!project && project.binding.rootRelPath === '' && owner?.workspaceKind !== 'study-space'
  const editing = !!project
  const [purpose, setPurpose] = useState<LearningPurpose>(project?.purpose ?? (editing ? 'unclassified' : 'english-reading'))
  const [name, setName] = useState(project?.name ?? '')
  const [topicIds, setTopicIds] = useState<string[]>(project?.topicIds ?? [])
  const [level, setLevel] = useState<LearningLevel | ''>(project?.readingSetupConfirmed ? project.level : '')
  const [minutes, setMinutes] = useState<number | ''>(project?.readingSetupConfirmed ? project.readingMinutes : '')
  const [ai, setAi] = useState<LearningAiSettings | null>(project?.ai ?? null)
  const [aiValid, setAiValid] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const root = useRef<HTMLElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const titleId = useId()
  useFocusTrap(root, { active: !settingsOpen, initialFocus: input, onEscape: pending ? undefined : onClose })
  useEffect(() => { if (!settingsOpen) return acquirePointerPassthrough() }, [settingsOpen])
  const english = purpose === 'english-reading'
  const valid = name.trim().length > 0 && purpose !== 'unclassified' && aiValid && ai !== null && (!english || topicIds.length >= 1 && topicIds.length <= 3 && !!level && !!minutes)
  const save = async (event: React.FormEvent): Promise<void> => {
    event.preventDefault()
    if (!valid || !ai) return
    setPending(true); setError(null)
    try {
      const topic = english ? LEARNING_TOPICS.filter(item => topicIds.includes(item.id)).map(item => item.label).join(', ') : project?.topic ?? '과목 자료'
      const selectedPackId = english
        ? packId ?? (project?.purpose === 'english-reading' ? project.packId : undefined) ?? 'vocab-chain-en'
        : (project?.purpose === 'course-review' ? project.packId : undefined) ?? 'quiz'
      const settings = { name: name.trim(), topic, purpose, topicIds: english ? topicIds : [], readingSetupConfirmed: english,
        ai, ...(english ? { level: level as LearningLevel, readingMinutes: Number(minutes) } : {}),
        ...(selectedPackId ? { packId: selectedPackId } : {}) }
      const saved = project ? await invoke('learning:updateSettings', { binding: project.binding, expectedRevision: project.revision, ...settings, ...(canClassifyStandalone && classifyStandalone ? { workspaceKind: 'study-space' as const } : {}) })
        : await invoke('learning:create', { placement: 'standalone', ...settings })
      await useCoursesStore.getState().loadCourses()
      if (english) rememberEnglishBinding(saved.binding)
      openLearning(saved.binding)
      notifyLearningChanged(); onCreated?.(saved.binding)
      if (english && !editing) void startLearningRun({ binding: saved.binding, kind: 'find-articles', ...(saved.packId ? { packId: saved.packId } : {}) }).catch(caught => showToast(learningError(caught), 'danger'))
      onClose()
    } catch (caught) { setError(learningError(caught)); setPending(false) }
  }
  const title = editing ? '학습 공간 설정' : '영어 이어읽기 시작하기'
  return createPortal(<div className="dialog-backdrop" style={settingsOpen ? { display: 'none' } : undefined} onMouseDown={event => { if (event.target === event.currentTarget && !pending) onClose() }}>
    <section ref={root} className="course-dialog learning-create learning-create--form" role="dialog" aria-modal="true" aria-labelledby={titleId}>
      <header className="course-dialog__header"><div><p className="eyebrow">MY LEARNING SPACE</p><h2 id={titleId}>{title}</h2></div><button className="bare-icon-button" type="button" aria-label="닫기" disabled={pending} onClick={onClose}><Icon name="x" /></button></header>
      <form className="learning-create__form" onSubmit={event => void save(event)}>
        <div className="learning-dialog-body">
          <p className="learning-muted">{editing ? '기존 자료를 그대로 두고, 이 공간의 용도와 사용할 AI를 확인해 주세요.' : '관심 주제로 첫 영어 글을 찾고, 모르는 표현을 다음 글에서 다시 만나요. 과목과 별도로 자료가 쌓입니다.'}</p>
          <label className="learning-field"><span>학습 공간 이름</span><input aria-label="학습 공간 이름" ref={input} className="text-field" value={name} placeholder="예: 나의 우주 읽기" maxLength={80} required disabled={pending} onChange={event => setName(event.target.value)} /></label>
          {editing && <label className="learning-field"><span>학습 공간 종류</span><select aria-label="학습 공간 종류" value={purpose} disabled={pending} onChange={event => setPurpose(event.target.value as LearningPurpose)}><option value="unclassified">종류를 선택해 주세요</option><option value="english-reading">영어 이어읽기</option><option value="course-review">과목 복습</option></select></label>}
          {canClassifyStandalone && <label className="learning-classify-workspace"><input type="checkbox" checked={classifyStandalone} disabled={pending} onChange={event => setClassifyStandalone(event.target.checked)} /><span><strong>이 폴더를 독립 학습 공간으로 분류</strong><small>파일 경로와 기록을 유지하고, 과목 목록에서 학습 공간 목록으로 옮겨 표시합니다. 실제 과목 폴더라면 선택하지 마세요.</small></span></label>}
          {english && <>
            <fieldset className="learning-topic-picker" disabled={pending}><legend>관심 주제 <small>1~3개 선택 · {topicIds.length}/3</small></legend><div>{LEARNING_TOPICS.map(item => <label key={item.id} data-selected={topicIds.includes(item.id)}><input type="checkbox" aria-label={`주제 ${item.label}`} checked={topicIds.includes(item.id)} disabled={pending || !topicIds.includes(item.id) && topicIds.length === 3} onChange={event => setTopicIds(previous => event.target.checked ? [...previous, item.id] : previous.filter(id => id !== item.id))} /><span>{item.label}</span></label>)}</div></fieldset>
            <div className="learning-form-row"><label className="learning-field"><span>편한 영어 수준</span><select aria-label="편한 영어 수준" required value={level} disabled={pending} onChange={event => setLevel(event.target.value as LearningLevel | '')}><option value="">수준 선택</option><option value="beginner">기초 · 쉬운 문장부터</option><option value="intermediate">중급 · 일반적인 기사 · 추천</option><option value="advanced">고급 · 깊이 있는 글</option></select></label><label className="learning-field"><span>한 편의 읽기 시간</span><select aria-label="한 편의 읽기 시간" required value={minutes} disabled={pending} onChange={event => setMinutes(event.target.value ? Number(event.target.value) : '')}><option value="">읽기 시간 선택</option><option value={4}>3~5분 · 가볍게 읽기 · 추천</option><option value={3}>약 3분</option><option value={5}>약 5분</option><option value={8}>약 8분</option></select></label></div>
          </>}
          <LearningAISelector value={ai} disabled={pending} onChange={setAi} onValidityChange={setAiValid} />
          {error && <p className="form-error" role="alert">{error}</p>}
        </div>
        <footer className="dialog-actions"><button type="button" className="button button--secondary" disabled={pending} onClick={onClose}>취소</button><button type="submit" className="button button--primary" disabled={pending || !valid}>{pending ? '설정 저장 중…' : editing ? '설정 저장' : '공간 만들고 첫 글 찾기'}</button></footer>
      </form>
    </section>
  </div>, document.body)
}
