export const RECORDING_SAMPLE_RATE = 16000
export const RECORDING_CHUNK_SAMPLES = 8000
export const DEFAULT_SPEECH_MODEL = 'whisper-large-v3-turbo' as const
export type SpeechModelId = typeof DEFAULT_SPEECH_MODEL | 'zipformer-ko' | 'sensevoice'
export type RecordingStatus =
  | 'ready'
  | 'recording'
  | 'paused'
  | 'processing'
  | 'complete'
  | 'interrupted'
export interface RecordingSession {
  id: string
  courseId: string
  title: string
  modelId: SpeechModelId
  createdAt: string
  status: RecordingStatus
  audioRelPath: string
  samples: number
  transcribedSamples: number
  nextSequence: number
  error: string | null
}
export interface TranscriptSegment {
  id: number
  sessionId: string
  startSample: number
  endSample: number
  text: string
}
export interface RecordingAnchor {
  id: string
  sample: number
  label: string
  relPath: string | null
  page: number | null
}
export interface RecordingDetail {
  session: RecordingSession
  segments: TranscriptSegment[]
  anchors: RecordingAnchor[]
}
export interface SpeechModelState {
  id: SpeechModelId
  name: string
  description: string
  bytes: number
  downloadedBytes: number
  status: 'available' | 'downloading' | 'verifying' | 'installed' | 'error'
  error: string | null
  unavailableReason?: string | undefined
}
export interface RecordingEvent {
  session: RecordingSession
  partial: { startSample: number; text: string } | null
  segment: TranscriptSegment | null
  rtf: number | null
  cooling: boolean
}
export interface RecordingIpcContract {
  'recordings:models': { req: {}; res: SpeechModelState[] }
  'recordings:downloadModel': { req: { modelId: SpeechModelId }; res: { ok: true } }
  'recordings:cancelDownload': { req: { modelId: SpeechModelId }; res: { ok: true } }
  'recordings:list': { req: { courseId: string }; res: RecordingSession[] }
  'recordings:resolve': { req: { courseId: string; relPath: string }; res: RecordingSession | null }
  'recordings:create': {
    req: { courseId: string; title: string; modelId: SpeechModelId }
    res: RecordingSession
  }
  'recordings:read': { req: { id: string; afterId?: number }; res: RecordingDetail }
  'recordings:control': {
    req: {
      id: string
      action: 'start' | 'pause' | 'stop' | 'retry' | 'interrupt'
      modelId?: SpeechModelId
    }
    res: RecordingSession
  }
  'recordings:append': {
    req: { id: string; sequence: number; pcm: Uint8Array }
    res: { nextSequence: number; samples: number }
  }
  'recordings:anchor': {
    req: { id: string; label: string; relPath?: string; page?: number; sample?: number }
    res: RecordingAnchor
  }
  'recordings:export': { req: { id: string }; res: { courseId: string; relPath: string } }
}
export const RECORDING_CHANNELS = [
  'recordings:models',
  'recordings:downloadModel',
  'recordings:cancelDownload',
  'recordings:list',
  'recordings:resolve',
  'recordings:create',
  'recordings:read',
  'recordings:control',
  'recordings:append',
  'recordings:anchor',
  'recordings:export'
] as const satisfies readonly (keyof RecordingIpcContract)[]

export function recordingTime(samples: number): string {
  const seconds = Math.floor(Math.max(0, samples) / RECORDING_SAMPLE_RATE)
  return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
    .map((part) => String(part).padStart(2, '0'))
    .join(':')
}
