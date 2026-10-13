import { DEFAULT_SPEECH_MODEL, type SpeechModelId } from './recording'

export interface TabPreferences {
  markdownTitlePrefix: string
  recordingModel: SpeechModelId
  recordingDeviceId: string
  recordingSidebarOpen: boolean
  recordingFollowTranscript: boolean
  recordingPlaybackRate: number
  whiteboardBackground: 'blank' | 'grid' | 'dots' | 'lines'
  boardDefaultView: 'board' | 'calendar'
  boardHideDone: boolean
}
export const DEFAULT_TAB_PREFERENCES: TabPreferences = {
  markdownTitlePrefix: '새 마크다운',
  recordingModel: DEFAULT_SPEECH_MODEL,
  recordingDeviceId: 'default',
  recordingSidebarOpen: true,
  recordingFollowTranscript: true,
  recordingPlaybackRate: 1,
  whiteboardBackground: 'grid',
  boardDefaultView: 'calendar',
  boardHideDone: false
}
export const RECORDING_PLAYBACK_RATES = [0.75, 1, 1.25, 1.5, 1.75, 2] as const

export function sanitizeTabPreferences(raw: unknown): TabPreferences {
  const r =
    typeof raw === 'object' && raw !== null && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {}
  const d = DEFAULT_TAB_PREFERENCES
  return {
    markdownTitlePrefix:
      typeof r.markdownTitlePrefix === 'string' && r.markdownTitlePrefix.trim()
        ? r.markdownTitlePrefix.trim().slice(0, 60)
        : d.markdownTitlePrefix,
    recordingModel:
      typeof r.recordingModel === 'string' &&
      ['whisper-large-v3-turbo', 'zipformer-ko', 'sensevoice'].includes(
        r.recordingModel
      )
        ? (r.recordingModel as SpeechModelId)
        : d.recordingModel,
    recordingDeviceId:
      typeof r.recordingDeviceId === 'string' &&
      r.recordingDeviceId.length > 0 &&
      r.recordingDeviceId.length <= 256
        ? r.recordingDeviceId
        : d.recordingDeviceId,
    recordingSidebarOpen:
      typeof r.recordingSidebarOpen === 'boolean'
        ? r.recordingSidebarOpen
        : d.recordingSidebarOpen,
    recordingFollowTranscript:
      typeof r.recordingFollowTranscript === 'boolean'
        ? r.recordingFollowTranscript
        : d.recordingFollowTranscript,
    recordingPlaybackRate: RECORDING_PLAYBACK_RATES.some(
      (rate) => rate === r.recordingPlaybackRate
    )
      ? (r.recordingPlaybackRate as number)
      : d.recordingPlaybackRate,
    whiteboardBackground:
      typeof r.whiteboardBackground === 'string' &&
      ['blank', 'grid', 'dots', 'lines'].includes(r.whiteboardBackground)
        ? (r.whiteboardBackground as TabPreferences['whiteboardBackground'])
        : d.whiteboardBackground,
    boardDefaultView: r.boardDefaultView === 'board' ? 'board' : 'calendar',
    boardHideDone:
      typeof r.boardHideDone === 'boolean' ? r.boardHideDone : d.boardHideDone
  }
}
