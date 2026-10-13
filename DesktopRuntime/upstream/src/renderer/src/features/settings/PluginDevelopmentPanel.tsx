import { useEffect, useState } from 'react'
import { useLocale } from '../../i18n'
import { invoke } from '../../lib/ipc'

export function PluginDevelopmentPanel(): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [folders, setFolders] = useState<Array<{ id: string; path: string }>>(
    [],
  )
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    void invoke('plugins:devFolders', {})
      .then((value) => {
        if (active) setFolders(value.folders)
      })
      .catch((failure: unknown) => {
        if (active) setError(String(failure))
      })
    return () => {
      active = false
    }
  }, [attempt])
  async function run(action: () => Promise<unknown>): Promise<void> {
    setBusy(true)
    setError(null)
    try {
      await action()
      setAttempt((n) => n + 1)
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure))
    } finally {
      setBusy(false)
    }
  }
  return (
    <section className="marketplace-form">
      <h2>{ko ? '로컬 개발' : 'Local development'}</h2>
      <p>
        {ko
          ? '폴더 변경을 감지해 설치본을 갱신합니다. 코드가 바뀌면 설치됨 화면에서 다시 승인해 실행하세요. 앱을 종료하면 감시도 종료됩니다.'
          : 'Watch a folder and refresh its installed copy. After code changes, approve and enable it in Installed. Watching ends when Bandal exits.'}
      </p>
      <code>pnpm plugin create my-plugin publisher.my-plugin</code>
      <code>pnpm plugin pack my-plugin</code>
      <button
        type="button"
        className="settings-extension-button"
        disabled={busy}
        onClick={() =>
          void run(async () => {
            const picked = await invoke('plugins:pickFolder', {})
            if (picked.path)
              await invoke('plugins:watchFolder', { path: picked.path })
          })
        }
      >
        {ko ? '개발 폴더 연결' : 'Connect development folder'}
      </button>
      {error && <p role="alert">{error}</p>}
      {folders.map((folder) => (
        <div className="marketplace-release" key={folder.id}>
          <strong>{folder.id}</strong>
          <code>{folder.path}</code>
          <button
            type="button"
            className="settings-extension-button"
            disabled={busy}
            onClick={() =>
              void run(() => invoke('plugins:unwatchFolder', { id: folder.id }))
            }
          >
            {ko ? '감시 종료' : 'Stop watching'}
          </button>
        </div>
      ))}
    </section>
  )
}
