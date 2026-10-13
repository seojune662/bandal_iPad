import { useId, useState } from 'react'
import type {
  SpeechModelId,
  SpeechModelState
} from '../../../../shared/recording'
import { invoke } from '../../lib/ipc'

export function SpeechModelPicker({
  models,
  value,
  disabled = false,
  onChange
}: {
  models: SpeechModelState[]
  value: SpeechModelId
  disabled?: boolean
  onChange: (id: SpeechModelId) => void
}): JSX.Element {
  const name = useId()
  const [error, setError] = useState<string | null>(null)
  async function download(id: SpeechModelId, cancel: boolean): Promise<void> {
    setError(null)
    try {
      await invoke(
        cancel ? 'recordings:cancelDownload' : 'recordings:downloadModel',
        { modelId: id }
      )
    } catch {
      setError('모델 다운로드 요청에 실패했습니다. 다시 시도해 주세요.')
    }
  }
  return (
    <div className="speech-models">
      {models.map((entry) => (
        <div
          key={entry.id}
          className="recording__model"
          data-selected={value === entry.id}
        >
          <label>
            <input
              type="radio"
              name={name}
              checked={value === entry.id}
              disabled={disabled || !!entry.unavailableReason}
              onChange={() => onChange(entry.id)}
            />
            <strong>{entry.name}</strong>
            <span>{Math.round(entry.bytes / 1e6)} MB</span>
          </label>
          <details className="recording__model-description">
            <summary>모델 설명</summary>
            <p>{entry.description}</p>
          </details>
          {entry.unavailableReason ? (
            <p className="recording__model-error">{entry.unavailableReason}</p>
          ) : entry.status === 'installed' ? (
            <span className="recording__installed">✓ 다운로드 완료</span>
          ) : entry.status === 'downloading' || entry.status === 'verifying' ? (
            <>
              <progress
                aria-label={`${entry.name} 다운로드`}
                value={entry.downloadedBytes}
                max={entry.bytes}
              />
              <div className="recording__model-progress">
                <span>
                  {entry.status === 'verifying'
                    ? '파일 확인 중…'
                    : `${Math.floor((entry.downloadedBytes / entry.bytes) * 100)}% 다운로드 중`}
                </span>
                <button onClick={() => void download(entry.id, true)}>
                  취소
                </button>
              </div>
            </>
          ) : (
            <button
              className="recording__download"
              onClick={() => void download(entry.id, false)}
            >
              ↓ {entry.status === 'error' ? '다시 다운로드' : '모델 다운로드'}
            </button>
          )}
          {entry.error && (
            <p role="alert" className="recording__model-error">
              {entry.error}
            </p>
          )}
        </div>
      ))}
      {error && (
        <p role="alert" className="recording__model-error">
          {error}
        </p>
      )}
    </div>
  )
}
