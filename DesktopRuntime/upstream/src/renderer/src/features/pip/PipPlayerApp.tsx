import {
  useCallback,
  useEffect,
  useReducer,
  useRef,
  type ChangeEvent,
  type KeyboardEvent as ReactKeyboardEvent
} from 'react'
import { invoke, onPush } from '../../lib/ipc'
import { mediaUrlFor } from '../materials/mediaUrl'
import {
  applyPipSeek,
  createPipReportSchedule,
  formatPipTime,
  INITIAL_PIP_PLAYER_UI_STATE,
  PIP_PLAYBACK_RATES,
  PIP_REPORT_INTERVAL_MS,
  pipPlayerUiReducer,
  planPipProgressReport,
  type PipReportTrigger,
  type PipSeekCommand
} from './pipPlayerModel'
import {
  playWithMutedFallback,
  syncInitialPipState
} from './pipStartup'

export interface PipPlayerAppProps {
  courseId: string
  relPath: string
  title: string
}

interface PipReportPayload {
  positionSec: number
  playbackRate: number
  paused: boolean
  aspect?: number
}

const CONTROL_HIDE_DELAY_MS = 2_000

function finiteVideoDuration(video: HTMLVideoElement): number | null {
  return Number.isFinite(video.duration) && video.duration >= 0
    ? video.duration
    : null
}

function snapshotFor(video: HTMLVideoElement): PipReportPayload {
  const duration = finiteVideoDuration(video)
  const finitePosition = Number.isFinite(video.currentTime)
    ? Math.max(0, video.currentTime)
    : 0
  const positionSec = duration === null
    ? finitePosition
    : Math.min(finitePosition, duration)
  const aspect =
    video.videoWidth > 0 && video.videoHeight > 0
      ? video.videoWidth / video.videoHeight
      : undefined

  return {
    positionSec,
    playbackRate: video.playbackRate,
    paused: video.paused,
    ...(aspect === undefined ? {} : { aspect })
  }
}

function isInteractiveTarget(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLElement &&
    target.closest('button, input, select') !== null
  )
}

export function PipPlayerApp({
  courseId,
  relPath,
  title
}: PipPlayerAppProps): JSX.Element {
  const [state, dispatch] = useReducer(
    pipPlayerUiReducer,
    INITIAL_PIP_PLAYER_UI_STATE
  )
  const videoRef = useRef<HTMLVideoElement | null>(null)
  const controlsTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const reportScheduleRef = useRef(createPipReportSchedule())
  const pendingSeekRef = useRef<PipSeekCommand | null>(null)
  const src = mediaUrlFor(courseId, relPath)

  const revealControls = useCallback((): void => {
    dispatch({ type: 'controls', visible: true })
    if (controlsTimerRef.current !== null) {
      clearTimeout(controlsTimerRef.current)
    }
    controlsTimerRef.current = setTimeout(() => {
      dispatch({ type: 'controls', visible: false })
      controlsTimerRef.current = null
    }, CONTROL_HIDE_DELAY_MS)
  }, [])

  const reportProgress = useCallback((trigger: PipReportTrigger): void => {
    const video = videoRef.current
    if (video === null) return

    const plan = planPipProgressReport(
      reportScheduleRef.current,
      Date.now(),
      trigger
    )
    reportScheduleRef.current = plan.schedule
    if (!plan.shouldReport) return

    // `aspect` is an additive contract field. Passing a named value keeps this
    // renderer compatible while the shared IPC declaration catches up.
    const payload: PipReportPayload = snapshotFor(video)
    void invoke('pip:report', payload).catch(() => undefined)
  }, [])

  const requestPlay = useCallback(async (): Promise<void> => {
    const video = videoRef.current
    if (video === null) return
    const result = await playWithMutedFallback(video, () => {
      dispatch({ type: 'volume', volume: video.volume, muted: true })
    })
    if (result !== 'blocked') {
      dispatch({ type: 'play-blocked', blocked: false })
      return
    }

    dispatch({ type: 'play-blocked', blocked: true })
    dispatch({ type: 'playback', paused: true })
    revealControls()
  }, [revealControls])

  const togglePlayback = useCallback((): void => {
    const video = videoRef.current
    if (video === null) return
    if (video.paused) {
      void requestPlay()
    } else {
      video.pause()
    }
  }, [requestPlay])

  const applySeekCommand = useCallback(
    (command: PipSeekCommand): void => {
      const video = videoRef.current
      if (video === null) return
      if (video.readyState === HTMLMediaElement.HAVE_NOTHING) {
        pendingSeekRef.current = command
        const next = applyPipSeek(command, null)
        video.playbackRate = next.playbackRate
        dispatch({ type: 'rate', playbackRate: next.playbackRate })
        return
      }

      pendingSeekRef.current = null
      const next = applyPipSeek(command, finiteVideoDuration(video))
      video.playbackRate = next.playbackRate
      video.currentTime = next.positionSec
      dispatch({ type: 'time', currentTimeSec: next.positionSec })
      dispatch({ type: 'rate', playbackRate: next.playbackRate })
      dispatch({ type: 'play-blocked', blocked: false })
      reportProgress('seek')
      if (next.play) {
        void requestPlay()
      } else {
        video.pause()
      }
    },
    [reportProgress, requestPlay]
  )

  const seekTo = useCallback(
    (positionSec: number): void => {
      const video = videoRef.current
      if (video === null) return
      const next = applyPipSeek(
        {
          positionSec,
          playbackRate: video.playbackRate,
          play: !video.paused
        },
        finiteVideoDuration(video)
      )
      video.currentTime = next.positionSec
      dispatch({ type: 'time', currentTimeSec: next.positionSec })
      reportProgress('seek')
    },
    [reportProgress]
  )

  const changeVolume = useCallback((volume: number): void => {
    const video = videoRef.current
    if (video === null) return
    video.volume = Math.min(1, Math.max(0, volume))
    if (video.volume > 0) video.muted = false
    dispatch({ type: 'volume', volume: video.volume, muted: video.muted })
  }, [])

  useEffect(() => {
    let disposed = false
    let receivedSeekPush = false
    const disposeSeek = onPush('pip:seek', (command) => {
      receivedSeekPush = true
      applySeekCommand(command)
    })
    void syncInitialPipState({
      getState: () => invoke('pip:getState', {}),
      applySeek: applySeekCommand,
      shouldApply: () => !disposed && !receivedSeekPush
    }).catch(() => undefined)
    const interval = window.setInterval(() => {
      reportProgress('interval')
    }, PIP_REPORT_INTERVAL_MS)

    revealControls()
    return () => {
      disposed = true
      disposeSeek()
      window.clearInterval(interval)
      if (controlsTimerRef.current !== null) {
        clearTimeout(controlsTimerRef.current)
      }
    }
  }, [applySeekCommand, reportProgress, revealControls])

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent): void => {
      revealControls()
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        return
      }
      if (isInteractiveTarget(event.target)) return

      const video = videoRef.current
      if (video === null) return
      switch (event.key) {
        case ' ':
        case 'Spacebar':
          event.preventDefault()
          togglePlayback()
          break
        case 'ArrowLeft':
          event.preventDefault()
          seekTo(video.currentTime - 5)
          break
        case 'ArrowRight':
          event.preventDefault()
          seekTo(video.currentTime + 5)
          break
        case 'ArrowUp':
          event.preventDefault()
          changeVolume(video.volume + 0.1)
          break
        case 'ArrowDown':
          event.preventDefault()
          changeVolume(video.volume - 0.1)
          break
      }
    }

    window.addEventListener('keydown', handleKeyDown, true)
    return () => window.removeEventListener('keydown', handleKeyDown, true)
  }, [changeVolume, revealControls, seekTo, togglePlayback])

  const handleSeekInput = (event: ChangeEvent<HTMLInputElement>): void => {
    seekTo(Number(event.currentTarget.value))
  }

  const handleRateInput = (event: ChangeEvent<HTMLSelectElement>): void => {
    const video = videoRef.current
    if (video === null) return
    video.playbackRate = Number(event.currentTarget.value)
  }

  const handleVolumeInput = (event: ChangeEvent<HTMLInputElement>): void => {
    changeVolume(Number(event.currentTarget.value))
  }

  const handleControlKeyDown = (
    event: ReactKeyboardEvent<HTMLElement>
  ): void => {
    if (event.key === 'Escape') {
      event.preventDefault()
      event.stopPropagation()
    }
    revealControls()
  }

  return (
    <main
      className="pip-player"
      data-controls-visible={state.controlsVisible ? 'true' : 'false'}
      onMouseEnter={revealControls}
      onMouseMove={revealControls}
      onKeyDown={handleControlKeyDown}
    >
      <video
        ref={videoRef}
        className="pip-player__video"
        src={src}
        preload="metadata"
        playsInline
        aria-label={title}
        onLoadedMetadata={(event) => {
          dispatch({
            type: 'metadata',
            durationSec: event.currentTarget.duration
          })
          dispatch({
            type: 'time',
            currentTimeSec: event.currentTarget.currentTime
          })
          reportProgress('metadata')
          const pendingSeek = pendingSeekRef.current
          if (pendingSeek !== null) applySeekCommand(pendingSeek)
        }}
        onTimeUpdate={(event) => {
          dispatch({
            type: 'time',
            currentTimeSec: event.currentTarget.currentTime
          })
        }}
        onPlay={() => {
          dispatch({ type: 'playback', paused: false })
          dispatch({ type: 'play-blocked', blocked: false })
          reportProgress('playback')
        }}
        onPause={() => {
          dispatch({ type: 'playback', paused: true })
          reportProgress('playback')
        }}
        onSeeked={(event) => {
          dispatch({ type: 'time', currentTimeSec: event.currentTarget.currentTime })
          reportProgress('seek')
        }}
        onRateChange={(event) => {
          dispatch({ type: 'rate', playbackRate: event.currentTarget.playbackRate })
          reportProgress('rate')
        }}
        onVolumeChange={(event) => {
          dispatch({
            type: 'volume',
            volume: event.currentTarget.volume,
            muted: event.currentTarget.muted
          })
        }}
      />

      {state.playBlocked ? (
        <button
          type="button"
          className="pip-player__blocked-play"
          aria-label="영상 재생"
          onClick={() => void requestPlay()}
        >
          <span aria-hidden="true">▶</span>
        </button>
      ) : null}

      <section className="pip-player__chrome" aria-label="영상 컨트롤">
        <header className="pip-player__header">
          <p className="pip-player__title" title={title}>
            {title}
          </p>
          <div className="pip-player__window-actions">
            <button
              type="button"
              className="pip-player__icon-button"
              aria-label="원래 화면으로 돌아가기"
              title="돌아가기"
              onClick={() => {
                void invoke('pip:restore', {}).catch(() => undefined)
              }}
            >
              <span aria-hidden="true">↩</span>
            </button>
            <button
              type="button"
              className="pip-player__icon-button pip-player__icon-button--close"
              aria-label="미니 플레이어 닫기"
              title="닫기"
              onClick={() => {
                void invoke('pip:close', {}).catch(() => undefined)
              }}
            >
              <span aria-hidden="true">×</span>
            </button>
          </div>
        </header>

        <div className="pip-player__controls">
          <label className="pip-player__seek">
            <span className="sr-only">재생 위치</span>
            <input
              type="range"
              min="0"
              max={Math.max(0, state.durationSec)}
              step="0.1"
              value={Math.min(state.currentTimeSec, state.durationSec || 0)}
              aria-label="재생 위치"
              onChange={handleSeekInput}
            />
          </label>
          <div className="pip-player__control-row">
            <button
              type="button"
              className="pip-player__icon-button"
              aria-label={state.paused ? '재생' : '일시정지'}
              onClick={togglePlayback}
            >
              <span aria-hidden="true">{state.paused ? '▶' : 'Ⅱ'}</span>
            </button>
            <output className="pip-player__time" aria-label="재생 시간">
              {formatPipTime(state.currentTimeSec)} / {formatPipTime(state.durationSec)}
            </output>
            <div className="pip-player__spacer" />
            <label className="pip-player__rate">
              <span className="sr-only">재생 속도</span>
              <select
                value={state.playbackRate}
                aria-label="재생 속도"
                onChange={handleRateInput}
              >
                {PIP_PLAYBACK_RATES.map((rate) => (
                  <option key={rate} value={rate}>
                    {rate}×
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              className="pip-player__icon-button"
              aria-label={state.muted ? '음소거 해제' : '음소거'}
              aria-pressed={state.muted}
              onClick={() => {
                const video = videoRef.current
                if (video === null) return
                video.muted = !video.muted
                dispatch({
                  type: 'volume',
                  volume: video.volume,
                  muted: video.muted
                })
              }}
            >
              <span aria-hidden="true">
                {state.muted || state.volume === 0 ? '🔇' : '🔊'}
              </span>
            </button>
            <label className="pip-player__volume">
              <span className="sr-only">음량</span>
              <input
                type="range"
                min="0"
                max="1"
                step="0.05"
                value={state.volume}
                aria-label="음량"
                onChange={handleVolumeInput}
              />
            </label>
          </div>
        </div>
      </section>
    </main>
  )
}
