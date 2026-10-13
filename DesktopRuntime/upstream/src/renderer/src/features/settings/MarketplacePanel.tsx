import { useEffect, useState } from 'react'
import type {
  MarketplaceDashboard,
  MarketplaceRelease,
} from '../../../../shared/types/marketplace'
import { useLocale } from '../../i18n'
import { invoke, onPush } from '../../lib/ipc'
import { useUiStore } from '../../stores/uiStore'
import { describePermission } from '../../../../shared/plugins/permissions'

export function MarketplacePanel(): JSX.Element {
  const locale = useLocale()
  const ko = locale === 'ko-KR'
  const [dashboard, setDashboard] = useState<MarketplaceDashboard | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [attempt, setAttempt] = useState(0)
  const [selected, setSelected] = useState<MarketplaceRelease | null>(null)
  const [reason, setReason] = useState('')
  const [changelog, setChangelog] = useState('')
  useEffect(() => {
    let active = true
    setError(null)
    void invoke('marketplace:dashboard', {})
      .then((result) => {
        if (active) {
          setDashboard(result)
          setSelected(null)
        }
      })
      .catch((failure: unknown) => {
        if (active)
          setError(failure instanceof Error ? failure.message : String(failure))
      })
    const stop = onPush('auth:changed', () => {
      setDashboard(null)
      setSelected(null)
      setAttempt((n) => n + 1)
    })
    return () => {
      active = false
      stop()
    }
  }, [attempt])
  async function perform(action: () => Promise<unknown>): Promise<void> {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await action()
      setAttempt((n) => n + 1)
      setReason('')
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : String(failure))
    } finally {
      setBusy(false)
    }
  }
  const statuses = ko
    ? {
        pending: '심사 대기',
        approved: '공개',
        rejected: '반려',
        withdrawn: '게시 중단',
      }
    : {
        pending: 'In review',
        approved: 'Published',
        rejected: 'Rejected',
        withdrawn: 'Withdrawn',
      }
  return (
    <div className="settings-stack marketplace-panel" aria-busy={busy}>
      <div className="settings-extensions__toolbar">
        <div>
          <h2>{ko ? '개발자 센터' : 'Developer center'}</h2>
          <p>
            {ko
              ? '학습을 돕는 도구를 만들고 반달 사용자와 나누세요.'
              : 'Build study tools and share them with Bandal users.'}
          </p>
        </div>
        <button
          type="button"
          className="settings-extension-button"
          disabled={busy}
          onClick={() => setAttempt((n) => n + 1)}
        >
          {ko ? '새로고침' : 'Refresh'}
        </button>
      </div>
      {error && (
        <p role="alert" className="settings-extension-feedback">
          {error}
        </p>
      )}
      {!dashboard && !error && (
        <p role="status">{ko ? '불러오는 중…' : 'Loading…'}</p>
      )}
      {dashboard && !dashboard.configured && (
        <p className="settings-extension-feedback">
          {ko
            ? '이 빌드에는 마켓플레이스 서비스가 연결되어 있지 않습니다. 폴더 설치로 로컬 플러그인을 사용할 수 있습니다.'
            : 'The marketplace service is not connected in this build. You can install local plugins from a folder.'}
        </p>
      )}
      {dashboard?.configured && !dashboard.signedIn && (
        <div className="settings-extension-feedback">
          <p>
            {ko
              ? '플러그인을 게시하려면 반달 계정으로 로그인하세요.'
              : 'Sign in with your Bandal account to publish plugins.'}
          </p>
          <button
            type="button"
            className="settings-extension-button"
            onClick={() => useUiStore.getState().openSettings('account')}
          >
            {ko ? '계정으로 이동' : 'Open account settings'}
          </button>
        </div>
      )}
      {dashboard?.signedIn && (
        <>
          {!dashboard.publisher ? (
            <form
              className="marketplace-form"
              onSubmit={(event) => {
                event.preventDefault()
                const data = new FormData(event.currentTarget)
                void perform(() =>
                  invoke('marketplace:register', {
                    id: String(data.get('id')),
                    displayName: String(data.get('name')),
                  }),
                )
              }}
            >
              <h3>{ko ? '개발자 등록' : 'Register as a developer'}</h3>
              <label>
                {ko
                  ? '개발자 ID (플러그인 ID의 접두사)'
                  : 'Publisher ID (plugin namespace)'}
                <input
                  name="id"
                  required
                  pattern="[a-z0-9][a-z0-9-]*"
                  maxLength={63}
                  disabled={busy}
                  placeholder="your-name"
                />
              </label>
              <label>
                {ko ? '표시 이름' : 'Display name'}
                <input name="name" required maxLength={80} disabled={busy} />
              </label>
              <button className="settings-extension-button" disabled={busy}>
                {ko ? '등록' : 'Register'}
              </button>
            </form>
          ) : (
            <form
              className="marketplace-form"
              onSubmit={(event) => {
                event.preventDefault()
                void perform(() => invoke('marketplace:submit', { changelog }))
              }}
            >
              <h3>{dashboard.publisher.display_name}</h3>
              <p>
                {ko ? '플러그인 ID 접두사' : 'Plugin namespace'}:{' '}
                <code>{dashboard.publisher.id}.</code>
              </p>
              <label>
                {ko ? '이번 버전의 변경 사항' : 'Release notes'}
                <textarea
                  value={changelog}
                  maxLength={10000}
                  onChange={(event) => setChangelog(event.currentTarget.value)}
                  disabled={busy}
                />
              </label>
              <button
                className="settings-extension-button settings-extension-button--primary"
                disabled={busy}
              >
                {ko
                  ? 'ZIP 선택 후 심사 제출'
                  : 'Choose ZIP and submit for review'}
              </button>
              <p>
                {ko
                  ? '모든 버전은 파일 검사와 운영자 심사를 거쳐 공개됩니다. 제출한 버전은 덮어쓸 수 없습니다.'
                  : 'Every version is validated and reviewed before publication. Submitted versions cannot be overwritten.'}
              </p>
            </form>
          )}
          <div className="marketplace-releases">
            <h3>
              {dashboard.reviewer
                ? ko
                  ? '심사·게시 관리'
                  : 'Review and publication'
                : ko
                  ? '내 플러그인 버전'
                  : 'My releases'}
            </h3>
            {dashboard.releases.length === 0 && (
              <p>
                {ko
                  ? '아직 제출한 버전이 없습니다.'
                  : 'No releases submitted yet.'}
              </p>
            )}
            {dashboard.releases.map((release) => (
              <button
                type="button"
                className="marketplace-release"
                key={release.id}
                aria-pressed={selected?.id === release.id}
                onClick={() => {
                  setSelected(release)
                  setReason('')
                }}
              >
                <strong>{release.manifest.name}</strong>
                <span>{release.version}</span>
                <span>{statuses[release.status]}</span>
              </button>
            ))}
          </div>
          {dashboard.reviewer && (
            <section className="marketplace-releases">
              <h3>{ko ? '접수된 신고' : 'Open reports'}</h3>
              {!dashboard.reports?.length && (
                <p>{ko ? '미처리 신고가 없습니다.' : 'No open reports.'}</p>
              )}
              {dashboard.reports?.map((report) => (
                <form
                  key={report.id}
                  className="marketplace-form"
                  onSubmit={(event) => {
                    event.preventDefault()
                    const resolution = String(
                      new FormData(event.currentTarget).get('resolution') ?? '',
                    ).trim()
                    if (resolution)
                      void perform(() =>
                        invoke('marketplace:resolveReport', {
                          id: report.id,
                          reason: resolution,
                        }),
                      )
                  }}
                >
                  <p>{report.reason}</p>
                  <button
                    type="button"
                    className="settings-extension-button"
                    disabled={busy}
                    onClick={() =>
                      void invoke('marketplace:release', {
                        id: report.release_id,
                      })
                        .then(setSelected)
                        .catch((failure: unknown) =>
                          setError(
                            failure instanceof Error
                              ? failure.message
                              : String(failure),
                          ),
                        )
                    }
                  >
                    {ko ? '신고된 버전 검토' : 'Inspect reported release'}
                  </button>
                  <label>
                    {ko ? '처리 결과' : 'Resolution'}
                    <textarea
                      name="resolution"
                      required
                      maxLength={2000}
                      disabled={busy}
                    />
                  </label>
                  <button className="settings-extension-button" disabled={busy}>
                    {ko ? '처리 완료' : 'Resolve report'}
                  </button>
                </form>
              ))}
            </section>
          )}
          {selected && (
            <article className="marketplace-form">
              <h3>
                {selected.manifest.name} · {selected.version}
              </h3>
              <p>{selected.manifest.description}</p>
              <pre className="marketplace-release-notes">
                {selected.changelog}
              </pre>
              <ul>
                {selected.manifest.permissions.map((permission) => (
                  <li key={permission}>
                    {describePermission(permission, locale)}
                  </li>
                ))}
              </ul>
              <p>
                {statuses[selected.status]} {selected.review_reason}
              </p>
              <details>
                <summary>
                  {ko ? '매니페스트·무결성 정보' : 'Manifest and integrity'}
                </summary>
                <pre>{JSON.stringify(selected.manifest, null, 2)}</pre>
                <code>{selected.sha256}</code>
              </details>
              <button
                className="settings-extension-button"
                type="button"
                disabled={busy}
                onClick={() =>
                  void perform(() =>
                    invoke('marketplace:reviewBundle', { id: selected.id }),
                  )
                }
              >
                {ko ? '검토할 ZIP 저장' : 'Save ZIP for review'}
              </button>
              {dashboard.reviewer &&
                ['pending', 'approved'].includes(selected.status) && (
                  <>
                    <label>
                      {ko ? '심사·중단 사유' : 'Review or withdrawal reason'}
                      <textarea
                        maxLength={2000}
                        value={reason}
                        onChange={(event) =>
                          setReason(event.currentTarget.value)
                        }
                      />
                    </label>
                    <div className="settings-extension-card__actions">
                      {(selected.status === 'pending'
                        ? (['approved', 'rejected'] as const)
                        : (['withdrawn'] as const)
                      ).map((decision) => (
                        <button
                          key={decision}
                          type="button"
                          className="settings-extension-button"
                          disabled={busy || !reason.trim()}
                          onClick={() => {
                            if (
                              !window.confirm(
                                ko
                                  ? `${statuses[decision]} 상태로 변경할까요?`
                                  : `Change this release to ${statuses[decision]}?`,
                              )
                            )
                              return
                            void perform(() =>
                              invoke('marketplace:review', {
                                id: selected.id,
                                decision,
                                reason,
                              }),
                            )
                          }}
                        >
                          {statuses[decision]}
                        </button>
                      ))}
                    </div>
                  </>
                )}
            </article>
          )}
        </>
      )}
    </div>
  )
}
