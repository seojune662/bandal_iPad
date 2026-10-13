import { useState } from 'react'
import type { LearningAiSettings, LearningRun, LearningRunKind } from '../../../../shared/types/learning'
import { invoke } from '../../lib/ipc'

const LABELS: Record<LearningRunKind, string> = { 'find-articles': '다음 글 찾기', 'explain-word': '문맥 속 뜻 정리', 'create-quiz': '퀴즈 만들기', 'create-cards': '플래시카드 만들기', 'create-summary': '학습 자료 정리', 'import-material': '기존 자료 변환' }
export function LearningRunStatus({ run, ai, pending, onCancel, onRetry, onSettings, onConnection, onDismiss, onOpenResult, retryUnavailableReason }: {
  run: LearningRun; ai?: LearningAiSettings | undefined; pending: boolean; onCancel: () => void; onRetry: () => void; onSettings: () => void; onConnection: () => void; onDismiss?: () => void; onOpenResult?: () => void; retryUnavailableReason?: string
}): JSX.Element {
  const [connectionChecked, setConnectionChecked] = useState<string | null>(null)
  const [checking, setChecking] = useState(false)
  const terminal = ['complete', 'awaiting-confirmation'].includes(run.status)
  const failed = ['failed', 'interrupted', 'cancelled'].includes(run.status)
  const modelChanged = !!ai && (ai.provider !== run.provider || !!run.model && ai.model !== run.model)
  const connectionReady = !!ai && connectionChecked === `${ai.provider}:${ai.model}`
  const needsModel = run.errorCategory === 'model'
  const retryBlocked = !ai || !!retryUnavailableReason || needsModel && !modelChanged || run.errorCategory === 'connection' && !connectionReady
  const check = async (): Promise<void> => {
    if (!ai) return
    setChecking(true)
    try { const result = await invoke('agent:availability', { provider: ai.provider }); setConnectionChecked(result.installed && result.loggedIn && !result.code ? `${ai.provider}:${ai.model}` : null) }
    catch { setConnectionChecked(null) }
    finally { setChecking(false) }
  }
  return <div className="learning-run" role="status" data-status={run.status}><span className="learning-run-indicator" /><div><strong>{LABELS[run.kind]}</strong><span>{run.error ?? run.message ?? '학습 자료를 준비하고 있어요.'}</span>{run.model && <small>{run.provider} · {run.model}{run.effort ? ` · ${run.effort}` : ''}</small>}{run.actionable && <span>{run.actionable}</span>}{run.errorCategory === 'quota' && <span>사용 한도가 다시 열리면 같은 모델로 다시 시도하거나, 다른 AI를 선택할 수 있어요.</span>}
    {failed && <details className="learning-run-details"><summary>상세 보기</summary><dl><dt>AI</dt><dd>{run.provider} · {run.model || '모델 기록 없음'}</dd>{run.effort && <><dt>Effort</dt><dd>{run.effort}</dd></>}{run.errorCode && <><dt>오류 코드</dt><dd>{run.errorCode}</dd></>}{run.sessionId && <><dt>실행 ID</dt><dd>{run.sessionId}</dd></>}<dt>발생 시간</dt><dd>{new Date(run.updatedAt).toLocaleString('ko-KR')}</dd></dl></details>}
    {failed && retryBlocked && <span>{retryUnavailableReason ?? (!ai ? '새로 실행하려면 사용할 AI를 선택해 주세요.' : needsModel ? '다른 AI 모델을 선택한 뒤 다시 시도해 주세요.' : 'AI에 연결하고 연결 상태를 다시 확인해 주세요.')}</span>}</div>
    {terminal ? onOpenResult ? <button type="button" className="learning-text-button" onClick={onOpenResult}>{run.kind === 'create-quiz' ? '퀴즈 풀기' : run.kind === 'create-cards' ? '카드 복습하기' : '결과 열기'}</button> : null : failed ? <>{!ai && !retryUnavailableReason && <button type="button" className="learning-text-button" onClick={onSettings}>AI 선택</button>}{run.errorCategory === 'connection' ? <><button type="button" className="learning-text-button" onClick={onConnection}>AI 연결 설정</button><button type="button" className="learning-text-button" disabled={pending || checking || !ai} onClick={() => void check()}>{checking ? '확인 중…' : '연결 다시 확인'}</button></> : needsModel ? <button type="button" className="learning-text-button" onClick={onSettings}>AI 모델 다시 선택</button> : null}<button type="button" className="learning-text-button" disabled={pending || retryBlocked} onClick={onRetry}>다시 시도</button></> : <button type="button" className="learning-text-button" disabled={pending} onClick={onCancel}>취소</button>}
    {onDismiss && <button type="button" className="learning-text-button" aria-label="작업 알림 닫기" disabled={pending} onClick={onDismiss}>닫기</button>}
  </div>
}
