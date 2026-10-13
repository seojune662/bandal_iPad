import { memo, useEffect, useState, type RefObject } from 'react'
import {
  recordingTime,
  RECORDING_SAMPLE_RATE
} from '../../../../shared/recording'
import { RECORDING_PLAYBACK_RATES } from '../../../../shared/tabPreferences'

/** Playback ticks stay here; they must not redraw the transcript/settings. */
export const RecordingPlayer = memo(function RecordingPlayer({
  audioRef,
  src,
  duration,
  defaultRate,
  onError
}: {
  audioRef: RefObject<HTMLAudioElement>
  src: string
  duration: number
  defaultRate: number
  onError: (message: string) => void
}): JSX.Element {
  const [time, setTime] = useState(0)
  const [playing, setPlaying] = useState(false)
  const [rate, setRate] = useState(defaultRate)
  useEffect(() => {
    setRate(defaultRate)
    if (audioRef.current) audioRef.current.playbackRate = defaultRate
  }, [audioRef, defaultRate])
  function seek(next: number): void {
    const value = Math.max(0, Math.min(duration, next))
    if (audioRef.current) audioRef.current.currentTime = value
    setTime(value)
  }
  return (
    <div className="recording-playback" aria-label="녹음 재생">
      <audio
        ref={audioRef}
        preload="metadata"
        src={src}
        onTimeUpdate={(event) => setTime(event.currentTarget.currentTime)}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onLoadedMetadata={(event) => {
          event.currentTarget.playbackRate = rate
        }}
        onError={() =>
          onError(
            '녹음 파일을 재생하지 못했습니다. 원음 파일의 위치를 확인해 주세요.'
          )
        }
      />
      <div className="recording-playback__transport">
        <button aria-label="10초 뒤로" onClick={() => seek(time - 10)}>
          −10
        </button>
        <button
          className="recording-playback__play"
          aria-label={playing ? '재생 일시정지' : '녹음 재생'}
          onClick={() => {
            if (playing) audioRef.current?.pause()
            else
              void audioRef.current
                ?.play()
                .catch(() =>
                  onError('녹음을 재생하지 못했습니다. 다시 시도해 주세요.')
                )
          }}
        >
          {playing ? 'Ⅱ' : '▶'}
        </button>
        <button aria-label="10초 앞으로" onClick={() => seek(time + 10)}>
          +10
        </button>
        <span className="recording-playback__time">
          {recordingTime(time * RECORDING_SAMPLE_RATE)} /{' '}
          {recordingTime(duration * RECORDING_SAMPLE_RATE)}
        </span>
        <select
          aria-label="재생 속도"
          value={rate}
          onChange={(event) => {
            const next = Number(event.target.value)
            setRate(next)
            if (audioRef.current) audioRef.current.playbackRate = next
          }}
        >
          {RECORDING_PLAYBACK_RATES.map((value) => (
            <option key={value} value={value}>
              {value}×
            </option>
          ))}
        </select>
      </div>
      <input
        type="range"
        aria-label="재생 위치"
        aria-valuetext={recordingTime(time * RECORDING_SAMPLE_RATE)}
        min={0}
        max={duration}
        step={0.1}
        value={Math.min(time, duration)}
        onChange={(event) => seek(Number(event.target.value))}
      />
    </div>
  )
})
