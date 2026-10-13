import { useEffect, useState } from 'react'
import type { PluginManifest } from '../../../../shared/types/plugin'
import { useLocale } from '../../i18n'
import { invoke, onPush } from '../../lib/ipc'

export function PluginConfiguration({
  manifest,
}: {
  manifest: PluginManifest
}): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [values, setValues] = useState<Record<string, unknown> | null>(null)
  const [error, setError] = useState(false)
  const [busy, setBusy] = useState(false)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    let pushed = false
    setValues(null)
    setError(false)
    const stop = onPush('plugins:settingsChanged', (event) => {
      if (event.pluginId === manifest.id) {
        pushed = true
        setValues(event.values)
      }
    })
    void invoke('plugins:getSettings', { id: manifest.id })
      .then((result) => {
        if (active && !pushed) setValues(result.values)
      })
      .catch(() => {
        if (active) setError(true)
      })
    return () => {
      active = false
      stop()
    }
  }, [manifest.id, attempt])

  async function save(key: string, value: unknown): Promise<void> {
    if (busy) return
    setBusy(true)
    setError(false)
    try {
      const result = await invoke('plugins:setSetting', {
        id: manifest.id,
        key,
        value,
      })
      setValues(result.values)
    } catch {
      setError(true)
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="plugin-configuration" aria-busy={busy}>
      {error && (
        <p role="alert">
          {ko
            ? '설정을 불러오거나 저장하지 못했습니다.'
            : 'Could not load or save settings.'}
          <button
            type="button"
            className="settings-extension-button"
            onClick={() => setAttempt((n) => n + 1)}
          >
            {ko ? '다시 불러오기' : 'Reload'}
          </button>
        </p>
      )}
      {values === null ? (
        <p role="status">{ko ? '설정 불러오는 중…' : 'Loading settings…'}</p>
      ) : (
        <>
          {manifest.contributes.settings?.map((field) => (
            <div className="setting-row" key={field.key}>
              <label
                className="setting-row__copy"
                htmlFor={`${manifest.id}-${field.key}`}
              >
                <span className="setting-row__label">{field.title}</span>
                {field.description && (
                  <span className="setting-row__description">
                    {field.description}
                  </span>
                )}
              </label>
              {field.type === 'boolean' ? (
                <input
                  id={`${manifest.id}-${field.key}`}
                  type="checkbox"
                  checked={values[field.key] === true}
                  disabled={busy}
                  onChange={(event) =>
                    void save(field.key, event.currentTarget.checked)
                  }
                />
              ) : field.type === 'select' ? (
                <select
                  id={`${manifest.id}-${field.key}`}
                  className="language-select"
                  value={String(values[field.key])}
                  disabled={busy}
                  onChange={(event) =>
                    void save(field.key, event.currentTarget.value)
                  }
                >
                  {field.options?.map((option) => (
                    <option key={option}>{option}</option>
                  ))}
                </select>
              ) : (
                <form
                  key={`${field.key}:${String(values[field.key])}`}
                  onSubmit={(event) => {
                    event.preventDefault()
                    const input = event.currentTarget.elements.namedItem(
                      'value',
                    ) as HTMLInputElement
                    void save(
                      field.key,
                      field.type === 'number'
                        ? input.valueAsNumber
                        : input.value,
                    )
                  }}
                >
                  <input
                    id={`${manifest.id}-${field.key}`}
                    name="value"
                    type={field.type === 'number' ? 'number' : 'text'}
                    defaultValue={String(values[field.key])}
                    min={field.min}
                    max={field.max}
                    step="any"
                    minLength={field.type === 'string' ? field.min : undefined}
                    maxLength={field.type === 'string' ? field.max : undefined}
                    disabled={busy}
                  />
                  <button
                    type="submit"
                    className="settings-extension-button"
                    disabled={busy}
                  >
                    {ko ? '저장' : 'Save'}
                  </button>
                </form>
              )}
            </div>
          ))}
          <button
            type="button"
            className="settings-extension-button"
            disabled={busy}
            onClick={() => {
              if (
                !window.confirm(
                  ko
                    ? '이 플러그인의 설정을 초기화할까요?'
                    : 'Reset this plugin’s settings?',
                )
              )
                return
              setBusy(true)
              setError(false)
              void invoke('plugins:resetSettings', { id: manifest.id })
                .then((result) => setValues(result.values))
                .catch(() => setError(true))
                .finally(() => setBusy(false))
            }}
          >
            {ko ? '기본값 복원' : 'Restore defaults'}
          </button>
        </>
      )}
    </div>
  )
}
