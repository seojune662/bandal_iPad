import { useEffect, useMemo, useState } from 'react'
import type { LearningAiSettings, LearningBinding, LearningProjectSnapshot, LearningProjectSummary } from '../../../../shared/types/learning'
import type { MaterialNode } from '../../../../shared/types/materials'
import { invoke } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { featureActionDisabledReason, type FeatureActionResult, type FeatureActionScope } from '../launcher/featureActions'
import type { FeatureEntry } from '../launcher/featureInventory'
import { EMPTY_LAUNCHER_CONTEXT, type LauncherContext } from '../launcher/launcherContext'
import { LearningAISelector } from './LearningAISelector'
import { learningError } from './learningNavigation'
import { learningDisplayName } from './learningPresentation'
import './learningGeneration.css'

export interface LearningGenerationChoice { context: LauncherContext; scope: FeatureActionScope; binding?: LearningBinding; ai?: LearningAiSettings }
export interface LearningGenerationRequest {
  label: string; entry: FeatureEntry; context: LauncherContext; initialScope?: FeatureActionScope
  binding?: LearningBinding; sourceCourseId?: string
  onStart: (choice: LearningGenerationChoice) => Promise<FeatureActionResult>
}
const bindingKey = (binding: LearningBinding): string => JSON.stringify([binding.courseId, binding.rootRelPath])
function filesIn(nodes: MaterialNode[]): MaterialNode[] { return nodes.flatMap(node => node.kind === 'dir' ? filesIn(node.children ?? []) : [node]) }

export function LearningGenerationForm({ request, onClose, sourceLocked = false, onPendingChange }: {
  request: LearningGenerationRequest
  onClose: () => void
  sourceLocked?: boolean
  onPendingChange?: (pending: boolean) => void
}): JSX.Element {
  const courses = useCoursesStore(state => state.courses)
  const native = request.entry.kind === 'pack' && request.entry.schemaVersion === 2
  const [sourceMode, setSourceMode] = useState<'' | 'current' | 'material' | 'course'>(request.initialScope ? 'current' : '')
  const [scope, setScope] = useState<FeatureActionScope | ''>(request.initialScope ?? '')
  const [courseId, setCourseId] = useState(request.sourceCourseId ?? '')
  const [relPath, setRelPath] = useState('')
  const [files, setFiles] = useState<MaterialNode[]>([])
  const [filesLoading, setFilesLoading] = useState(false)
  const [projects, setProjects] = useState<LearningProjectSummary[]>([])
  const [projectsLoading, setProjectsLoading] = useState(false)
  const defaultDestinationKey = request.binding ? bindingKey(request.binding) : 'automatic'
  const [destinationKey, setDestinationKey] = useState(defaultDestinationKey)
  const [changeDestination, setChangeDestination] = useState(false)
  const [destination, setDestination] = useState<LearningProjectSnapshot | null>(null)
  const [destinationLoading, setDestinationLoading] = useState(false)
  const [ai, setAi] = useState<LearningAiSettings | null>(null)
  const [aiValid, setAiValid] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => { onPendingChange?.(pending) }, [pending, onPendingChange])
  useEffect(() => () => onPendingChange?.(false), [onPendingChange])
  const context = useMemo<LauncherContext>(() => sourceMode === 'current' ? request.context : {
    ...EMPTY_LAUNCHER_CONTEXT, courseId: courseId || null, courseName: courses.find(course => course.id === courseId)?.name ?? null,
    ...(sourceMode === 'material' && relPath ? { material: { courseId, kind: /\.md$/i.test(relPath) ? 'note' : 'file', title: relPath.split('/').at(-1)!, relPath } } : {})
  }, [sourceMode, courseId, relPath, courses, request.context])
  const sourceOwner = context.courseId
  const currentMaterial = request.context.material?.relPath || request.context.browser || request.context.articleIds.length || request.context.wordIds.length
  const currentCourse = courses.some(course => course.id === request.context.courseId && course.workspaceKind !== 'study-space' && !course.missing)
  const currentTitle = request.context.material?.title || request.context.browser?.title || request.context.courseName || '현재 과목'
  const supportedCourse = request.entry.kind !== 'pack' || request.entry.worksOn.includes('course')
  const capturedBinding = sourceMode === 'current' && scope !== 'course' && context.binding && (context.articleIds.length || context.wordIds.length) ? context.binding : undefined
  const ownerRootRequired = native && sourceMode === 'current' && scope !== 'course' && !!currentMaterial && courses.some(course => course.id === sourceOwner && course.workspaceKind === 'study-space')
  const ownerRoot = ownerRootRequired ? projects.find(project => project.binding.courseId === sourceOwner && project.binding.rootRelPath === '' && !project.deletedAt && !project.warning) : undefined
  const fixedBinding = capturedBinding ?? ownerRoot?.binding
  const availableProjects = projects.filter(project => !project.deletedAt && !project.warning && (fixedBinding ? bindingKey(project.binding) === bindingKey(fixedBinding) : project.purpose === 'course-review' && (project.linkedCourseId === sourceOwner || project.binding.courseId === sourceOwner)))
  const defaultProject = availableProjects.filter(project => project.linkedCourseId === sourceOwner && project.binding.rootRelPath === '' && courses.find(course => course.id === project.binding.courseId)?.workspaceKind === 'study-space')
    .sort((a, b) => (courses.find(course => course.id === b.binding.courseId)?.createdAt ?? '').localeCompare(courses.find(course => course.id === a.binding.courseId)?.createdAt ?? '') || (courses.find(course => course.id === b.binding.courseId)?.sortOrder ?? 0) - (courses.find(course => course.id === a.binding.courseId)?.sortOrder ?? 0))[0]
  const selectedProject = availableProjects.find(project => bindingKey(project.binding) === destinationKey)
  const selectedBinding = fixedBinding ?? selectedProject?.binding
  const sourceValid = !!sourceMode && !!scope && !!sourceOwner && (sourceMode !== 'material' || !!relPath)
  const ownerRootMissing = ownerRootRequired && !capturedBinding && !ownerRoot && !projectsLoading
  const reason = sourceValid ? featureActionDisabledReason(request.entry, context, scope as FeatureActionScope) ?? (ownerRootMissing ? '원본을 보관할 학습 공간을 찾지 못했어요. 공간 목록에서 기존 학습 공간을 확인해 주세요.' : null) : null
  const destinationValid = !native || !!fixedBinding || !ownerRootRequired && (!!selectedProject || destinationKey === 'automatic')
  const valid = sourceValid && !reason && destinationValid && !destinationLoading && !projectsLoading && (!native || aiValid && !!ai)
  useEffect(() => {
    if (sourceMode !== 'material' || !courseId) { setFiles([]); return }
    let stale = false; setFilesLoading(true); setError(null)
    void invoke('materials:tree', { courseId }).then(tree => { if (!stale) setFiles(filesIn(tree)) }).catch(caught => { if (!stale) setError(learningError(caught)) }).finally(() => { if (!stale) setFilesLoading(false) })
    return () => { stale = true }
  }, [sourceMode, courseId])
  useEffect(() => {
    if (!native || !sourceOwner) { setProjects([]); setProjectsLoading(false); return }
    let stale = false; setProjectsLoading(true)
    void invoke('learning:list', { courseId: sourceOwner }).then(result => { if (!stale) setProjects(result.projects) }).catch(caught => { if (!stale) setError(learningError(caught)) }).finally(() => { if (!stale) setProjectsLoading(false) })
    return () => { stale = true }
  }, [native, sourceOwner])
  const loadBinding = selectedBinding ?? (destinationKey === 'automatic' ? defaultProject?.binding : undefined)
  const loadKey = loadBinding ? bindingKey(loadBinding) : ''
  const outputBinding = selectedBinding ?? loadBinding
  useEffect(() => {
    let stale = false; setDestination(null); setAi(null); setAiValid(false)
    if (!loadBinding) { setDestinationLoading(false); return }
    setDestinationLoading(true)
    void invoke('learning:get', { binding: loadBinding }).then(project => { if (!stale) { setDestination(project); setAi(project.ai ?? null) } }).catch(caught => { if (!stale) setError(learningError(caught)) }).finally(() => { if (!stale) setDestinationLoading(false) })
    return () => { stale = true }
  }, [loadKey])
  const chooseMode = (mode: typeof sourceMode): void => { setSourceMode(mode); setScope(mode === 'course' ? 'course' : mode === 'material' ? 'material' : ''); setRelPath(''); setDestinationKey(defaultDestinationKey); setError(null) }
  const sourceName = sourceMode === 'current' ? `${currentTitle}${context.browser ? ` · ${context.browser.url}` : context.material?.relPath && context.material.relPath !== currentTitle ? ` · ${context.material.relPath}` : ''}${context.material?.page ? ` · p${context.material.page}` : ''}` : sourceMode === 'material' ? relPath || '자료를 선택해 주세요' : context.courseName || '과목을 선택해 주세요'
  const scopeName = scope === 'selection' ? '선택한 부분' : scope === 'course' ? '과목 전체' : context.wordIds.length ? '단어장' : context.articleIds.length ? '기사 전체' : '자료 전체'
  const namedDestination = destination ?? (capturedBinding ? undefined : ownerRoot) ?? selectedProject ?? (destinationKey === 'automatic' ? defaultProject : undefined)
  const destinationName = native ? namedDestination ? learningDisplayName(namedDestination, courses) : fixedBinding ? courses.find(course => course.id === fixedBinding.courseId)?.name ?? '현재 학습 공간' : ownerRootRequired ? projectsLoading ? '현재 학습 공간 확인 중…' : '현재 학습 공간을 확인해 주세요' : destinationKey === 'automatic' ? `${context.courseName || '선택한 과목'} 복습 · 새 공간` : '저장 공간을 선택해 주세요' : request.entry.kind === 'pack' ? `${context.courseName || '선택한 과목'} / ${request.entry.outputs.dir}` : '플러그인에서 처리'
  const outputName = request.entry.kind === 'pack' ? request.entry.schemaVersion === 1 ? 'Markdown 문서' : request.entry.experience === 'quiz' ? '퀴즈' : '카드' : '플러그인 작업'
  return (
    <form className="learning-create__form" onSubmit={event => { event.preventDefault(); if (pending || !valid || !scope) return; setPending(true); setError(null); void request.onStart({ context, scope, ...(outputBinding ? { binding: outputBinding } : {}), ...(ai ? { ai } : {}) }).then(onClose).catch(caught => { setError(learningError(caught)); setPending(false) }) }}><div className="learning-dialog-body">
      {!sourceLocked && <><label className="learning-field"><span>원본 선택</span><select aria-label="학습 원본 선택" value={sourceMode} disabled={pending} onChange={event => chooseMode(event.target.value as typeof sourceMode)}><option value="">어떤 자료로 만들까요?</option>{(currentMaterial || currentCourse) && <option value="current">현재 열어 둔 자료 · {currentTitle}</option>}<option value="material">과목에서 자료 선택</option>{supportedCourse && <option value="course">과목 전체 선택</option>}</select></label>
      {sourceMode === 'current' && <label className="learning-field"><span>사용할 범위</span><select aria-label="학습 원본 범위" value={scope} disabled={pending} onChange={event => { setScope(event.target.value as FeatureActionScope | ''); setDestinationKey(defaultDestinationKey) }}><option value="">범위를 선택해 주세요</option>{request.context.selection && <option value="selection">선택한 부분</option>}{currentMaterial && <option value="material">{request.context.wordIds.length ? '현재 단어장' : request.context.articleIds.length ? '현재 기사' : request.context.browser ? '현재 웹페이지 전체' : '현재 자료 전체'}</option>}{supportedCourse && currentCourse && <option value="course">과목 전체</option>}</select></label>}
      {(sourceMode === 'material' || sourceMode === 'course') && <label className="learning-field"><span>원본 과목</span><select aria-label="학습 원본 과목" value={courseId} disabled={pending} onChange={event => { setCourseId(event.target.value); setRelPath(''); setDestinationKey(defaultDestinationKey) }}><option value="">과목을 선택해 주세요</option>{courses.filter(course => course.workspaceKind !== 'study-space' && !course.missing).map(course => <option key={course.id} value={course.id}>{course.name}</option>)}</select></label>}
      {sourceMode === 'material' && courseId && <label className="learning-field"><span>원본 자료</span><select aria-label="학습 원본 자료" value={relPath} disabled={pending || filesLoading} onChange={event => setRelPath(event.target.value)}><option value="">{filesLoading ? '자료를 불러오는 중…' : '자료를 선택해 주세요'}</option>{files.map(file => <option key={file.relPath} value={file.relPath}>{file.relPath}</option>)}</select></label>}
      </>}
      {scope === 'selection' && context.selection && <blockquote className="learning-source-quote">{context.selection}</blockquote>}
      {native && sourceValid && <div className="learning-field"><span>저장할 학습 공간</span><p className="learning-muted">{projectsLoading ? '저장 공간 확인 중…' : destinationName}{fixedBinding ? ' · 원문과 단어가 있는 공간에 저장합니다.' : ''}</p>{!fixedBinding && !ownerRootRequired && availableProjects.length > 0 && <button type="button" className="learning-text-button" disabled={pending || projectsLoading} onClick={() => setChangeDestination(value => !value)}>저장 공간 변경</button>}{changeDestination && !fixedBinding && !ownerRootRequired && <select aria-label="학습 저장 공간" value={destinationKey} disabled={pending || projectsLoading} onChange={event => setDestinationKey(event.target.value)}><option value="automatic">기본 복습 공간{defaultProject ? ` · ${learningDisplayName(defaultProject, courses)}` : ' · 새로 만들기'}</option>{availableProjects.map(project => <option key={bindingKey(project.binding)} value={bindingKey(project.binding)}>{learningDisplayName(project, courses)}</option>)}</select>}</div>}
      {native && destinationValid && sourceValid && (destinationLoading || projectsLoading ? <p role="status">공간의 AI 설정을 확인하는 중…</p> : <LearningAISelector key={`${loadKey}:${destination?.revision ?? 'new'}`} value={ai} disabled={pending} onChange={setAi} onValidityChange={setAiValid} />)}
      <dl className="learning-generation-preview" aria-label="실행 내용 확인"><dt>원본</dt><dd>{sourceValid ? `${sourceName} · ${scopeName}` : '원본과 범위를 먼저 선택해 주세요'}</dd><dt>결과</dt><dd>{outputName}</dd><dt>저장 공간</dt><dd>{destinationName}</dd><dt>AI</dt><dd>{native ? ai ? `${ai.provider} · ${ai.model}${ai.effort ? ` · ${ai.effort}` : ''}` : '연결된 AI와 모델을 선택해 주세요' : request.entry.kind === 'pack' ? '앱 AI 설정 · 문서 생성 팩' : '이 플러그인의 설정'}</dd></dl>
      {(reason || error) && <p className="learning-error" role="alert">{error || reason}</p>}
    </div><footer className="dialog-actions"><button className="button button--secondary" type="button" disabled={pending} onClick={onClose}>취소</button><button className="button button--primary" type="submit" disabled={pending || !valid}>{pending ? '원본 확인과 실행 준비 중…' : request.entry.kind === 'plugin-command' ? '실행' : `${request.label} 만들기`}</button></footer></form>
  )
}
