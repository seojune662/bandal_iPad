export type PipSource =
  | { kind: 'local'; courseId: string; relPath: string; title: string }
  | {
      kind: 'web'
      url: string
      title: string
      /** Best-effort identity for the exact video selected in the source tab. */
      videoHint?: {
        index: number
        aspect?: number
      }
    }

export interface PipOpenRequest {
  source: PipSource
  positionSec: number
  playbackRate: number
  paused?: boolean
}

export interface PipState {
  open: boolean
  source: PipSource | null
  positionSec: number
  playbackRate: number
  paused: boolean
}

/** 돌아가기 시 원래 자리로 넘기는 페이로드 */
export interface PipRestorePayload {
  source: PipSource
  positionSec: number
  playbackRate: number
}
