export const PIP_REPORT_INTERVAL_MS = 3_000
export const PIP_PLAYBACK_RATES = [0.5, 0.75, 1, 1.25, 1.5, 2] as const

export interface PipSeekCommand {
  positionSec: number
  playbackRate: number
  play: boolean
}

export type PipAppliedSeek = PipSeekCommand

export type PipReportTrigger =
  | 'interval'
  | 'metadata'
  | 'playback'
  | 'seek'
  | 'rate'

export interface PipReportSchedule {
  nextIntervalAtMs: number
}

export interface PipReportPlan {
  schedule: PipReportSchedule
  shouldReport: boolean
}

export interface PipPlayerUiState {
  controlsVisible: boolean
  currentTimeSec: number
  durationSec: number
  muted: boolean
  paused: boolean
  playbackRate: number
  playBlocked: boolean
  volume: number
}

export type PipPlayerUiAction =
  | { type: 'controls'; visible: boolean }
  | { type: 'metadata'; durationSec: number }
  | { type: 'time'; currentTimeSec: number }
  | { type: 'playback'; paused: boolean }
  | { type: 'rate'; playbackRate: number }
  | { type: 'volume'; volume: number; muted: boolean }
  | { type: 'play-blocked'; blocked: boolean }

export const INITIAL_PIP_PLAYER_UI_STATE: PipPlayerUiState = {
  controlsVisible: true,
  currentTimeSec: 0,
  durationSec: 0,
  muted: false,
  paused: true,
  playbackRate: 1,
  playBlocked: false,
  volume: 1
}

const clamp = (value: number, min: number, max: number): number =>
  Math.min(max, Math.max(min, value))

export function sanitizePipPlaybackRate(playbackRate: number): number {
  return Number.isFinite(playbackRate) ? clamp(playbackRate, 0.5, 2) : 1
}

/** Pure normalization used before a main-process seek is applied to video. */
export function applyPipSeek(
  command: PipSeekCommand,
  durationSec: number | null
): PipAppliedSeek {
  const finitePosition = Number.isFinite(command.positionSec)
    ? Math.max(0, command.positionSec)
    : 0
  const positionSec =
    durationSec !== null && Number.isFinite(durationSec) && durationSec >= 0
      ? Math.min(finitePosition, durationSec)
      : finitePosition

  return {
    positionSec,
    playbackRate: sanitizePipPlaybackRate(command.playbackRate),
    play: command.play
  }
}

export function createPipReportSchedule(
  nowMs: number = Date.now()
): PipReportSchedule {
  return { nextIntervalAtMs: nowMs + PIP_REPORT_INTERVAL_MS }
}

/**
 * Immediate triggers do not move the periodic deadline: a pause just before a
 * three-second tick still gets both the immediate and regular snapshots.
 */
export function planPipProgressReport(
  current: PipReportSchedule,
  nowMs: number,
  trigger: PipReportTrigger
): PipReportPlan {
  if (trigger !== 'interval') {
    return { schedule: current, shouldReport: true }
  }

  const clockMovedBack =
    nowMs < current.nextIntervalAtMs - PIP_REPORT_INTERVAL_MS
  const shouldReport = clockMovedBack || nowMs >= current.nextIntervalAtMs

  return {
    schedule: shouldReport
      ? { nextIntervalAtMs: nowMs + PIP_REPORT_INTERVAL_MS }
      : current,
    shouldReport
  }
}

export function pipPlayerUiReducer(
  state: PipPlayerUiState,
  action: PipPlayerUiAction
): PipPlayerUiState {
  switch (action.type) {
    case 'controls':
      return { ...state, controlsVisible: action.visible }
    case 'metadata':
      return {
        ...state,
        durationSec:
          Number.isFinite(action.durationSec) && action.durationSec > 0
            ? action.durationSec
            : 0
      }
    case 'time':
      return {
        ...state,
        currentTimeSec: Number.isFinite(action.currentTimeSec)
          ? clamp(action.currentTimeSec, 0, state.durationSec || Infinity)
          : 0
      }
    case 'playback':
      return { ...state, paused: action.paused }
    case 'rate':
      return {
        ...state,
        playbackRate: sanitizePipPlaybackRate(action.playbackRate)
      }
    case 'volume':
      return {
        ...state,
        volume: Number.isFinite(action.volume)
          ? clamp(action.volume, 0, 1)
          : state.volume,
        muted: action.muted
      }
    case 'play-blocked':
      return { ...state, playBlocked: action.blocked }
  }
}

export function formatPipTime(seconds: number): string {
  const wholeSeconds = Number.isFinite(seconds)
    ? Math.max(0, Math.floor(seconds))
    : 0
  const hours = Math.floor(wholeSeconds / 3_600)
  const minutes = Math.floor((wholeSeconds % 3_600) / 60)
  const remainder = wholeSeconds % 60
  const mmss = `${String(minutes).padStart(2, '0')}:${String(remainder).padStart(2, '0')}`
  return hours > 0 ? `${hours}:${mmss}` : mmss
}
