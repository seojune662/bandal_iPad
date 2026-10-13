import type { SpeechModelId } from '../../../shared/recording'
export type EngineRequest =
  | { seq: number; type: 'init'; modelId: SpeechModelId; directory: string }
  | { seq: number; type: 'audio'; samples: Float32Array; preview?: boolean }
  | { seq: number; type: 'flush' }
export interface EngineResult {
  segments: { startSample: number; endSample: number; text: string }[]
  partial: { startSample: number; text: string } | null
}
export type EngineResponse =
  | { seq: number; result: EngineResult; elapsedMs: number }
  | { seq: number; error: string }
