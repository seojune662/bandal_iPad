import { Component, type ReactNode } from 'react'
import { rendererDiagnostic } from '../../diagnostics'
import { prepareDocumentRecovery } from './recovery'

type State = { error: Error | null; recoveryError: string | null; recovering: boolean }
/** Lives inside the stable workspace content entry, including tab transfers.
 * Recovering one document never recreates the shell or other live documents. */
export class DocumentErrorBoundary extends Component<{ children: ReactNode }, State> {
  override state: State = { error: null, recoveryError: null, recovering: false }
  private mounted = false
  private recovery: Promise<void> | undefined
  override componentDidMount(): void { this.mounted = true }
  override componentWillUnmount(): void { this.mounted = false }
  static getDerivedStateFromError(reason: unknown): Partial<State> {
    return { error: reason instanceof Error ? reason : new Error(String(reason)), recovering: false }
  }
  override componentDidCatch(error: Error): void {
    void (window.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>)('runtime:diagnostic', rendererDiagnostic(error)).catch(() => undefined)
  }
  private recover = (): void => {
    if (this.recovery) return
    this.setState({ recovering: true, recoveryError: null })
    this.recovery = prepareDocumentRecovery().then(() => {
      if (this.mounted) this.setState({ error: null, recoveryError: null, recovering: false })
    }).catch(error => {
      if (this.mounted) this.setState({ recovering: false, recoveryError: error instanceof Error ? error.message : String(error) })
    }).finally(() => { this.recovery = undefined })
  }
  override render(): ReactNode {
    if (!this.state.error) return this.props.children
    return <section role="alert" aria-label="문서 오류" data-bandal-native-overlay=""
      style={{ boxSizing: 'border-box', width: '100%', height: '100%', overflow: 'auto', padding: 24, background: 'var(--bg, #fff)', color: 'var(--text, #292828)' }}>
      <h2>이 문서를 표시하지 못했어요</h2>
      <p>다른 문서는 계속 사용할 수 있어요. 저장을 확인한 뒤 이 문서의 화면을 다시 엽니다.</p>
      {this.state.recoveryError && <p role="alert">{this.state.recoveryError}</p>}
      <button type="button" disabled={this.state.recovering} onClick={this.recover}
        style={{ minHeight: 44, padding: '8px 16px', font: 'inherit' }}>
        {this.state.recovering ? '저장 확인 중…' : '이 문서 다시 열기'}
      </button>
      <details><summary style={{ minHeight: 44, paddingTop: 12 }}>오류 정보</summary><pre style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{this.state.error.message}</pre></details>
    </section>
  }
}
