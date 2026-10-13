import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type {
  BrowserImportFileKind,
  BrowserImportItem,
  BrowserImportJob,
  BrowserImportSource,
} from '../../../../shared/types/browserImport'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useLocale } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { useFavoritesStore } from '../../stores/favoritesStore'
import { BrowserIcon } from './browserIcons'
import { BrowserProfileSelect } from './BrowserProfileSelect'
import { acquirePointerPassthrough } from './webviewPassthrough'
import './browserImport.css'

const ITEMS: BrowserImportItem[] = [
  'cookies',
  'passwords',
  'bookmarks',
  'history',
]

export function BrowserImportDialog({
  profileId: initialProfileId,
  onClose,
}: {
  profileId: string
  onClose: () => void
}): JSX.Element {
  const korean = useLocale() === 'ko-KR'
  const label = (ko: string, en: string): string => (korean ? ko : en)
  const names: Record<BrowserImportItem, string> = {
    cookies: label('로그인 상태 · 쿠키', 'Sign-in sessions · cookies'),
    passwords: label('비밀번호', 'Passwords'),
    bookmarks: label('북마크', 'Bookmarks'),
    history: label('방문 기록', 'History'),
  }
  const dialogRef = useRef<HTMLDivElement>(null)
  const mounted = useRef(true)
  const [sources, setSources] = useState<BrowserImportSource[]>([])
  const [sourceId, setSourceId] = useState('')
  const [profileId, setProfileId] = useState(initialProfileId)
  const [items, setItems] = useState<BrowserImportItem[]>(ITEMS)
  const [replace, setReplace] = useState(false)
  const [loading, setLoading] = useState(true)
  const [starting, setStarting] = useState(false)
  const [error, setError] = useState('')
  const [job, setJob] = useState<BrowserImportJob | null>(null)
  const source = sources.find((item) => item.id === sourceId)
  const running = starting || job?.state === 'running'
  useFocusTrap(dialogRef, {
    active: true,
    onEscape: running ? undefined : onClose,
  })
  useEffect(() => {
    mounted.current = true
    const release = acquirePointerPassthrough()
    void invoke('browser:importSources', {})
      .then((next) => {
        if (!mounted.current) return
        setSources(next)
        setSourceId(next[0]?.id ?? '')
      })
      .catch(() => {
        if (mounted.current)
          setError(
            label(
              '브라우저 목록을 읽지 못했습니다. 파일로 가져올 수 있습니다.',
              'Could not discover browsers. You can import a file.',
            ),
          )
      })
      .finally(() => {
        if (mounted.current) setLoading(false)
      })
    return () => {
      mounted.current = false
      release()
    }
  }, [])
  useEffect(() => {
    if (job?.state !== 'running') return
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const poll = async (): Promise<void> => {
      try {
        const next = await invoke('browser:importJob', { jobId: job.id })
        if (cancelled) return
        if (next === null) throw new Error('missing job')
        setJob(next)
        if (next.state === 'running') timer = setTimeout(() => void poll(), 400)
        else void useFavoritesStore.getState().load(null)
      } catch {
        if (!cancelled) {
          setError(
            label(
              '진행 상태를 확인하지 못했습니다.',
              'Could not read import progress.',
            ),
          )
          timer = setTimeout(() => void poll(), 1200)
        }
      }
    }
    void poll()
    return () => {
      cancelled = true
      if (timer) clearTimeout(timer)
    }
  }, [job?.id, job?.state])
  const pickFile = async (kind: BrowserImportFileKind): Promise<void> => {
    setError('')
    try {
      const picked = await invoke('browser:importFile', { kind })
      if (!mounted.current || picked === null) return
      setSources((current) => [
        ...current.filter((item) => item.id !== picked.id),
        picked,
      ])
      setSourceId(picked.id)
      setItems(ITEMS.filter((item) => picked.capabilities[item].supported))
    } catch {
      if (mounted.current)
        setError(
          label(
            '파일을 읽지 못했습니다. 내보내기 파일을 확인해 주세요.',
            'Could not read this export file.',
          ),
        )
    }
  }
  const start = async (): Promise<void> => {
    if (!source || running) return
    setStarting(true)
    setError('')
    try {
      const next = await invoke('browser:importStart', {
        sourceId,
        targetProfileId: profileId,
        items: items.filter((item) => source.capabilities[item].supported),
        conflict: replace ? 'replace' : 'keep',
      })
      if (mounted.current) setJob(next)
    } catch {
      if (mounted.current)
        setError(
          label(
            '가져오기를 시작하지 못했습니다. 원본 브라우저를 닫고 다시 시도해 주세요.',
            'Could not start the import. Close the source browser and try again.',
          ),
        )
    } finally {
      if (mounted.current) setStarting(false)
    }
  }
  return createPortal(
    <div className="browser-import-backdrop">
      <div
        className="browser-import-dialog"
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="browser-import-title"
      >
        <header>
          <div>
            <h2 id="browser-import-title">
              {label('브라우저 데이터 가져오기', 'Import browser data')}
            </h2>
            <p>
              {label(
                '쓰던 계정과 자료를 반달에서도 이어서 사용하세요.',
                'Bring your accounts and browsing data into Bandal.',
              )}
            </p>
          </div>
          <button
            type="button"
            className="browser-import-close"
            aria-label={label('닫기', 'Close')}
            disabled={running}
            onClick={onClose}
          >
            <Icon name="x" />
          </button>
        </header>
        {job === null ? (
          <>
            <fieldset disabled={running}>
              <legend>
                {label('1. 가져올 브라우저', '1. Source browser')}
              </legend>
              <select
                aria-label={label(
                  '가져올 브라우저 프로필',
                  'Source browser profile',
                )}
                value={sourceId}
                onChange={(event) => {
                  setSourceId(event.target.value)
                  setItems(ITEMS)
                }}
              >
                {sources.length === 0 && (
                  <option value="">
                    {loading
                      ? label('브라우저 찾는 중…', 'Finding browsers…')
                      : label(
                          '파일로 가져오기를 선택하세요',
                          'Choose an export file',
                        )}
                  </option>
                )}
                {sources.map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.name} · {item.profileName}
                  </option>
                ))}
              </select>
              <div className="browser-import-files">
                <button
                  type="button"
                  onClick={() => void pickFile('passwords-csv')}
                >
                  {label('비밀번호 CSV', 'Password CSV')}
                </button>
                <button
                  type="button"
                  onClick={() => void pickFile('bookmarks-html')}
                >
                  {label('북마크 HTML', 'Bookmark HTML')}
                </button>
                <button
                  type="button"
                  onClick={() => void pickFile('safari-zip')}
                >
                  {label('Safari 내보내기 ZIP', 'Safari export ZIP')}
                </button>
              </div>
            </fieldset>
            <fieldset disabled={running}>
              <legend>
                {label('2. 반달에서 사용할 프로필', '2. Destination profile')}
              </legend>
              <BrowserProfileSelect value={profileId} onChange={setProfileId} />
            </fieldset>
            <fieldset disabled={running}>
              <legend>{label('3. 가져올 항목', '3. Data to import')}</legend>
              {ITEMS.map((item) => (
                <label className="browser-import-item" key={item}>
                  <input
                    type="checkbox"
                    checked={
                      source?.capabilities[item].supported === true &&
                      items.includes(item)
                    }
                    disabled={!source?.capabilities[item].supported}
                    onChange={(event) =>
                      setItems((current) =>
                        event.target.checked
                          ? [...current, item]
                          : current.filter((value) => value !== item),
                      )
                    }
                  />
                  <span>
                    <strong>{names[item]}</strong>
                    <small>
                      {source?.capabilities[item].description ??
                        label(
                          '원본을 선택하면 지원 범위를 보여드립니다.',
                          'Choose a source to see available data.',
                        )}
                    </small>
                  </span>
                </label>
              ))}
              <p className="browser-import-note">
                {label(
                  '방문 기록은 최근 90일, 최대 2만 URL을 가져옵니다. 이전할 수 없는 로그인 상태는 다시 로그인해야 합니다.',
                  'History includes the last 90 days, up to 20,000 URLs. Sessions that cannot be transferred require signing in again.',
                )}
              </p>
              <label className="browser-import-replace">
                <input
                  type="checkbox"
                  checked={replace}
                  onChange={(event) => setReplace(event.target.checked)}
                />
                {label(
                  '중복 항목은 가져온 정보로 교체',
                  'Replace existing entries with imported data',
                )}
              </label>
            </fieldset>
          </>
        ) : (
          <section className="browser-import-result" aria-live="polite">
            <h3>
              {job.state === 'running'
                ? label('가져오는 중…', 'Importing…')
                : job.state === 'completed'
                  ? label('가져오기를 마쳤습니다', 'Import complete')
                  : job.state === 'cancelled'
                    ? label('가져오기를 중단했습니다', 'Import cancelled')
                    : label(
                        '일부 데이터를 가져오지 못했습니다',
                        'Import could not finish',
                      )}
            </h3>
            {job.state === 'running' && (
              <progress
                aria-label={label('가져오기 진행', 'Import progress')}
                {...(job.total && job.total > 0
                  ? { max: job.total, value: job.processed }
                  : {})}
              />
            )}
            <table>
              <thead>
                <tr>
                  <th>{label('항목', 'Data')}</th>
                  <th>{label('가져옴', 'Imported')}</th>
                  <th>{label('기존 유지', 'Kept')}</th>
                  <th>{label('지원 불가', 'Unsupported')}</th>
                  <th>{label('실패', 'Failed')}</th>
                </tr>
              </thead>
              <tbody>
                {ITEMS.map((item) => (
                  <tr key={item}>
                    <th>{names[item]}</th>
                    <td>{job.results[item].imported}</td>
                    <td>{job.results[item].kept}</td>
                    <td>{job.results[item].unsupported}</td>
                    <td>{job.results[item].failed}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {job.messages.map((message, index) => (
              <p key={index}>{message}</p>
            ))}
            {job.state === 'cancelled' && (
              <p>
                {label(
                  '이미 가져온 항목은 유지됩니다. 다시 실행해도 중복으로 추가되지 않습니다.',
                  'Completed entries are kept. Retrying does not add duplicates.',
                )}
              </p>
            )}
          </section>
        )}
        {error && (
          <p className="browser-import-error" role="alert">
            {error}
          </p>
        )}
        <footer>
          {job === null ? (
            <>
              <span>
                {label(
                  '기본값은 기존 정보 유지입니다.',
                  'Existing data is kept by default.',
                )}
              </span>
              <button
                type="button"
                className="browser-import-primary"
                disabled={
                  running ||
                  !source ||
                  !items.some((item) => source.capabilities[item].supported)
                }
                onClick={() => void start()}
              >
                {starting
                  ? label('시작하는 중…', 'Starting…')
                  : label('가져오기', 'Import')}
              </button>
            </>
          ) : running ? (
            <button
              type="button"
              disabled={starting}
              onClick={() => {
                if (job)
                  void invoke('browser:importCancel', { jobId: job.id }).catch(
                    () =>
                      setError(
                        label(
                          '취소 요청을 전달하지 못했습니다.',
                          'Could not request cancellation.',
                        ),
                      ),
                  )
              }}
            >
              {label('가져오기 중단', 'Cancel import')}
            </button>
          ) : (
            <>
              <button
                type="button"
                onClick={() => {
                  setJob(null)
                  setError('')
                }}
              >
                {label('다른 데이터 가져오기', 'Import more')}
              </button>
              <button
                type="button"
                className="browser-import-primary"
                onClick={onClose}
              >
                {label('완료', 'Done')}
              </button>
            </>
          )}
        </footer>
      </div>
    </div>,
    document.body,
  )
}

export function BrowserImportBanner({
  profileId,
}: {
  profileId: string
}): JSX.Element | null {
  const korean = useLocale() === 'ko-KR'
  const key = `bandal.browser-import-dismissed.v1.${profileId}`
  const [dismissed, setDismissed] = useState(() => {
    try {
      return localStorage.getItem(key) === '1'
    } catch {
      return false
    }
  })
  const [open, setOpen] = useState(false)
  if (dismissed) return null
  return (
    <>
      <div className="browser-import-banner">
        <BrowserIcon name="globe" />
        <div>
          <strong>
            {korean ? '쓰던 브라우저에서 가져오기' : 'Import from your browser'}
          </strong>
          <span>
            {korean
              ? '로그인 정보, 북마크와 방문 기록을 이어서 사용하세요.'
              : 'Bring your sign-in details, bookmarks and history.'}
          </span>
        </div>
        <button type="button" onClick={() => setOpen(true)}>
          {korean ? '가져오기' : 'Import'}
        </button>
        <button
          type="button"
          className="browser-import-close"
          aria-label={korean ? '가져오기 안내 닫기' : 'Dismiss import banner'}
          onClick={() => {
            setDismissed(true)
            try {
              localStorage.setItem(key, '1')
            } catch {
              /* Optional preference. */
            }
          }}
        >
          <Icon name="x" />
        </button>
      </div>
      {open && (
        <BrowserImportDialog
          profileId={profileId}
          onClose={() => setOpen(false)}
        />
      )}
    </>
  )
}
