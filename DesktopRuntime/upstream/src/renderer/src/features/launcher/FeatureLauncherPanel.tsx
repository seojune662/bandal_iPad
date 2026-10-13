import { useEffect, useMemo, useRef, useState } from 'react'
import type { LearningBinding } from '../../../../shared/types/learning'
import type { MaterialNode } from '../../../../shared/types/materials'
import { Icon } from '../../app/icons'
import { invoke, onPush } from '../../lib/ipc'
import { useUiStore } from '../../stores/uiStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { openLearning } from '../learning/learningNavigation'
import { useFeatureInventory, type FeatureEntry } from './featureInventory'
import { useLauncherContext } from './launcherContext'
import { requestFeatureAction, type FeatureActionResult } from './featureActions'
import './launcher.css'

interface ActionStatus {
  phase: 'pending' | 'requested' | 'available' | 'started' | 'complete' | 'failed'
  message: string
  binding?: LearningBinding
  runId?: string
  courseId?: string
  relPath?: string
  resultArticleIds?: string[]
  resultArtifactIds?: string[]
}
const QUICK_PACKS = ['vocab-chain-en', 'quiz', 'flashcards']
function actionLabel(entry: FeatureEntry): string {
  if (entry.kind !== 'pack') return entry.label
  if (entry.experience === 'article-vocabulary') return '영어 글 읽기'
  return ({ quiz: '퀴즈 만들기', flashcards: '카드 만들기', summary: '요약하기' } as Record<string, string>)[entry.packId] ?? entry.label
}
const RUN_LABELS: Record<string, string> = {
  queued: '실행 대기 중', running: 'AI가 자료를 만드는 중', validating: '결과 확인 중',
  interrupted: '실행이 중단됐어요', 'awaiting-confirmation': '확인이 필요해요',
  complete: '완료', failed: '실행하지 못했어요', cancelled: '취소됨'
}
function containsMaterial(nodes: MaterialNode[], relPath: string): boolean {
  return nodes.some(node => node.relPath === relPath || !!node.children && containsMaterial(node.children, relPath))
}

export function FeatureLauncherPanel({ hidden }: { hidden: boolean }): JSX.Element {
  const { entries, loading, error, reload } = useFeatureInventory()
  const { context, loading: contextLoading } = useLauncherContext()
  const railOpen = useUiStore(state => state.leftRailOpen && state.courseRailOpen)
  const settingsOpen = useUiStore(state => state.isSettingsOpen)
  const [query, setQuery] = useState('')
  const [statuses, setStatuses] = useState<Record<string, ActionStatus>>({})
  const statusRef = useRef(statuses); statusRef.current = statuses
  const input = useRef<HTMLInputElement>(null)
  const pendingActions = useRef(new Set<string>())
  useEffect(() => {
    if (hidden || !railOpen || settingsOpen || document.querySelector('.tour-overlay')) return
    const element = input.current
    if (!element) return
    const focus = (): boolean => {
      if (!element.isConnected || element.closest('[inert], [hidden]')) return false
      element.focus({ preventScroll: true })
      return document.activeElement === element
    }
    if (focus()) return
    // Settings keeps the surrounding rail inert during its exit transition.
    const observer = new MutationObserver(() => { if (focus()) observer.disconnect() })
    observer.observe(document.body, { subtree: true, attributes: true, attributeFilter: ['inert', 'hidden'] })
    return () => observer.disconnect()
  }, [hidden, railOpen, settingsOpen])

  useEffect(() => {
    const refreshRuns = async (binding: LearningBinding): Promise<void> => {
      const pending = Object.entries(statusRef.current).filter(([, item]) => item.runId && item.binding?.courseId === binding.courseId && item.binding.rootRelPath === binding.rootRelPath)
      if (!pending.length) return
      try {
        const project = await invoke('learning:get', { binding })
        setStatuses(previous => {
          const next = { ...previous }
          for (const [id, captured] of pending) {
            if (next[id]?.runId !== captured.runId) continue
            const run = project.runs.find(item => item.id === captured.runId)
            if (!run) continue
            next[id] = { ...captured, phase: run.status === 'complete' ? 'complete' : ['failed', 'cancelled', 'interrupted'].includes(run.status) ? 'failed' : 'started', message: run.error || RUN_LABELS[run.status] || run.message, ...(run.resultArticleIds ? { resultArticleIds: run.resultArticleIds } : {}), ...(run.resultArtifactIds ? { resultArtifactIds: run.resultArtifactIds } : {}) }
          }
          return next
        })
      } catch { /* A transient read does not turn an executing run into a failure. */ }
    }
    const stop = onPush('learning:changed', ({ binding }) => { void refreshRuns(binding) })
    for (const item of Object.values(statusRef.current)) if (item.binding && item.phase === 'started') void refreshRuns(item.binding)
    return stop
  }, [Object.values(statuses).map(item => item.runId).join('|')])
  useEffect(() => {
    const refreshFiles = async (courseId: string): Promise<void> => {
      const requested = Object.entries(statusRef.current).filter(([, item]) => item.phase === 'requested' && item.courseId === courseId)
      if (!requested.length) return
      try {
        const tree = await invoke('materials:tree', { courseId })
        setStatuses(previous => {
          const next = { ...previous }
          for (const [id, item] of requested) if (item.relPath && next[id]?.relPath === item.relPath && containsMaterial(tree, item.relPath)) {
            next[id] = { ...item, phase: 'available', message: '생성된 자료를 열 수 있어요.' }
          }
          return next
        })
      } catch { /* Keep the request state until a material update confirms the file. */ }
    }
    const stop = onPush('materials:changed', ({ courseId }) => { void refreshFiles(courseId) })
    for (const item of Object.values(statusRef.current)) if (item.phase === 'requested' && item.courseId) void refreshFiles(item.courseId)
    return stop
  }, [Object.values(statuses).map(item => item.relPath).join('|')])

  const recordResult = (entry: FeatureEntry, result: FeatureActionResult): void => {
    if (result.status === 'failed') { setStatuses(previous => ({ ...previous, [entry.id]: { phase: 'failed', message: result.message } })); return }
    if (result.status === 'opened' && !result.binding) { setStatuses(previous => { const next = { ...previous }; delete next[entry.id]; return next }); return }
    setStatuses(previous => ({ ...previous, [entry.id]: {
      phase: result.status === 'started' ? 'started' : result.status === 'dispatched' ? 'requested' : 'complete', message: result.message,
      ...('binding' in result && result.binding ? { binding: result.binding } : {}),
      ...('runId' in result && result.runId ? { runId: result.runId } : {}),
      ...('relPath' in result && result.relPath && 'courseId' in result ? { relPath: result.relPath, courseId: result.courseId } : {})
    } }))
  }
  const run = async (entry: FeatureEntry): Promise<void> => {
    if (pendingActions.current.has(entry.id) || statusRef.current[entry.id]?.phase === 'started') return
    pendingActions.current.add(entry.id)
    setStatuses(previous => ({ ...previous, [entry.id]: { phase: 'pending', message: '실행 준비 중…' } }))
    try { recordResult(entry, await requestFeatureAction(entry, context, { onResult: result => recordResult(entry, result) })) }
    catch (caught) { setStatuses(previous => ({ ...previous, [entry.id]: { phase: 'failed', message: caught instanceof Error ? caught.message : '실행하지 못했어요.' } })) }
    finally { pendingActions.current.delete(entry.id) }
  }

  const filtered = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase()
    return entries.filter(entry => !needle || `${actionLabel(entry)} ${entry.label} ${entry.description} ${entry.kind === 'pack' && entry.packId === 'vocab-chain-en' ? '영어 단어 사슬' : ''} ${entry.kind !== 'pack' ? entry.pluginName : ''}`.toLocaleLowerCase().includes(needle))
  }, [entries, query])
  const quick = QUICK_PACKS.flatMap(id => filtered.filter(entry => entry.kind === 'pack' && entry.packId === id))
  const others = filtered.filter(entry => !quick.includes(entry))
  const card = (entry: FeatureEntry): JSX.Element => {
    const status = statuses[entry.id]
    const reason = entry.unavailableReason || (!entry.enabled ? '이 기능이 비활성화되어 있어요.' : null)
    const busy = status?.phase === 'pending' || status?.phase === 'started'
    return <article className="launcher-feature" key={entry.id} data-kind={entry.kind} data-tour={entry.kind === 'pack' ? entry.packId === 'quiz' ? 'quiz-tools' : entry.packId === 'vocab-chain-en' ? 'english-tool' : undefined : undefined}>
      <button type="button" className="launcher-feature__action" disabled={!!reason || busy || contextLoading}
        title={reason ?? entry.description} onClick={() => void run(entry)}>
        <span className="launcher-feature__icon" aria-hidden="true">{entry.kind === 'pack' ? entry.experience === 'article-vocabulary' ? 'Aa' : entry.experience === 'quiz' ? '?' : entry.experience === 'flashcards' ? '▤' : '✦' : <Icon name="puzzle" />}</span>
        <span><strong>{actionLabel(entry)}</strong><small className="launcher-feature__type">{entry.kind === 'pack' ? entry.schemaVersion === 1 ? 'Markdown 문서' : entry.experience === 'quiz' ? '퀴즈' : entry.experience === 'flashcards' ? '카드' : '영어 읽기' : '플러그인'}</small><small>{entry.description}</small></span>
      </button>
      {reason && <p className="launcher-feature__reason">{reason}</p>}
      {status && <div className="launcher-feature__status" role="status" data-phase={status.phase}>
        <span>{status.message}</span>
        {status.binding && <button type="button" onClick={() => {
          const artifactId = status.resultArtifactIds?.[0], articleId = status.resultArticleIds?.[0]
          openLearning(status.binding!, artifactId ? 'review' : articleId ? 'reader' : 'home', artifactId ?? articleId)
        }}>{status.phase === 'complete' ? status.resultArtifactIds?.length || status.resultArticleIds?.length ? '결과 열기' : '공간 보기' : '진행 보기'}</button>}
        {status.relPath && status.courseId && status.phase === 'available' && <button type="button" onClick={() => {
          useCoursesStore.getState().selectCourse(status.courseId!)
          const workspace = useWorkspaceStore.getState()
          workspace.setActiveCourse(status.courseId!)
          workspace.openTab(descriptorFor('file', { courseId: status.courseId!, relPath: status.relPath! }))
        }}>결과 열기</button>}
      </div>}
    </article>
  }

  return <aside id="plugins-panel" className="app-rail app-rail--left feature-launcher" aria-label="학습 도구" hidden={hidden}>
    <header className="launcher-header"><div><p>바로 실행</p><h2>학습 도구</h2></div><button type="button" className="bare-icon-button" aria-label="기능 새로고침" onClick={() => void reload()}><Icon name="refresh" /></button></header>
    <label className="launcher-search"><Icon name="search" /><input ref={input} value={query} onChange={event => setQuery(event.target.value)} placeholder="기능 검색" aria-label="기능 검색" /></label>
    <div className="launcher-scroll">
      {error && <p className="launcher-error" role="alert">{error} <button type="button" onClick={() => void reload()}>다시 불러오기</button></p>}
      {loading && <p className="launcher-empty" role="status">기능을 불러오는 중…</p>}
      {quick.length > 0 && <section aria-label="학습 바로가기"><h3 className="launcher-section-label">학습 바로가기</h3>{quick.map(card)}</section>}

      {others.length > 0 && <section aria-label="전체 기능"><h3 className="launcher-section-label">전체 기능</h3>{others.map(card)}</section>}
      {!loading && filtered.length === 0 && <p className="launcher-empty">{query ? '검색한 기능이 없어요.' : '사용할 수 있는 기능이 없어요. 플러그인 관리에서 추가해 보세요.'}</p>}

    </div>
    <footer className="launcher-footer"><button type="button" onClick={() => useUiStore.getState().openSettings('packs')}><Icon name="settings" /> 플러그인 관리 <Icon name="chevronRight" /></button></footer>
  </aside>
}
