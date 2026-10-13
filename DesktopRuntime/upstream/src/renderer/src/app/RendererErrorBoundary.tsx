import { Component, type ErrorInfo, type ReactNode } from 'react'

interface RendererErrorBoundaryProps {
  children: ReactNode
}

interface RendererErrorBoundaryState {
  error: Error | null
}

export class RendererErrorBoundary extends Component<
  RendererErrorBoundaryProps,
  RendererErrorBoundaryState
> {
  override state: RendererErrorBoundaryState = { error: null }

  static getDerivedStateFromError(error: unknown): RendererErrorBoundaryState {
    return {
      error: error instanceof Error ? error : new Error(String(error))
    }
  }

  override componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error(
      '[Bandal] 화면 렌더링 중 복구 가능한 오류가 발생했습니다.',
      error,
      info
    )
  }

  override render(): ReactNode {
    if (this.state.error === null) return this.props.children

    return (
      <main className="renderer-error" role="alert">
        <div className="renderer-error__card">
          <span className="renderer-error__mark" aria-hidden="true">
            ◐
          </span>
          <p className="renderer-error__eyebrow">Bandal 복구 모드</p>
          <h1>화면을 불러오지 못했어요</h1>
          <p>
            이미 저장한 파일과 필기는 보존되어 있습니다. 앱을 다시 불러오면 마지막
            작업 화면부터 복구를 시도합니다.
          </p>
          <button type="button" onClick={() => window.location.reload()}>
            다시 불러오기
          </button>
          <details>
            <summary>오류 정보</summary>
            <code>{this.state.error.message}</code>
          </details>
        </div>
      </main>
    )
  }
}
