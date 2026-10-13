import { useEffect, useState } from 'react'
import type { MarketplaceRelease } from '../../../../../shared/types/marketplace'
import { describePermission } from '../../../../../shared/plugins/permissions'
import { useLocale } from '../../../i18n'
import { invoke } from '../../../lib/ipc'

export function MarketplaceReleaseDetails({ id }: { id: string }): JSX.Element {
  const locale = useLocale()
  const ko = locale === 'ko-KR'
  const [release, setRelease] = useState<MarketplaceRelease | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [busy, setBusy] = useState(false)
  const [reported, setReported] = useState(false)
  useEffect(() => {
    let active = true
    setError(null)
    setRelease(null)
    void invoke('marketplace:release', { id })
      .then((result) => {
        if (active) setRelease(result)
      })
      .catch((failure: unknown) => {
        if (active)
          setError(failure instanceof Error ? failure.message : String(failure))
      })
    return () => {
      active = false
    }
  }, [id, attempt])
  return (
    <div className="marketplace-release-details">
      {error && (
        <p role="alert">
          {error}{' '}
          <button
            type="button"
            className="settings-extension-button"
            onClick={() => setAttempt((n) => n + 1)}
          >
            {ko ? '다시 시도' : 'Retry'}
          </button>
        </p>
      )}
      {!release && !error && (
        <p role="status">
          {ko ? '버전 정보 불러오는 중…' : 'Loading release…'}
        </p>
      )}
      {release && (
        <>
          {release.status === 'withdrawn' && (
            <p role="alert">
              {ko
                ? '게시가 중단된 버전입니다. 설치된 경우 비활성화하세요.'
                : 'This version has been withdrawn. Disable it if installed.'}{' '}
              {release.review_reason}
            </p>
          )}
          <h4>
            {ko ? '변경 내역' : 'Release notes'} · {release.version}
          </h4>
          <pre className="marketplace-release-notes">
            {release.changelog ||
              (ko
                ? '등록된 변경 내역이 없습니다.'
                : 'No release notes provided.')}
          </pre>
          <h4>{ko ? '요청하는 권한' : 'Requested permissions'}</h4>
          <ul>
            {release.manifest.permissions.map((permission) => (
              <li key={permission}>{describePermission(permission, locale)}</li>
            ))}
          </ul>
          <p>
            {ko
              ? '심사는 안전을 보장하지 않습니다. 신뢰하는 개발자의 플러그인만 실행하세요.'
              : 'Review does not guarantee safety. Only run plugins from developers you trust.'}
          </p>
          {reported ? (
            <p role="status">
              {ko ? '신고가 접수되었습니다.' : 'Report submitted.'}
            </p>
          ) : (
            release.status === 'approved' && (
              <details>
                <summary>{ko ? '문제 신고' : 'Report a problem'}</summary>
                <form
                  className="marketplace-form"
                  onSubmit={(event) => {
                    event.preventDefault()
                    if (busy) return
                    const reason = String(
                      new FormData(event.currentTarget).get('reason') ?? '',
                    ).trim()
                    if (!reason) return
                    setBusy(true)
                    setError(null)
                    void invoke('marketplace:report', { releaseId: id, reason })
                      .then(() => setReported(true))
                      .catch((failure: unknown) =>
                        setError(
                          failure instanceof Error
                            ? failure.message
                            : String(failure),
                        ),
                      )
                      .finally(() => setBusy(false))
                  }}
                >
                  <label>
                    {ko
                      ? '신고 사유 (로그인 필요)'
                      : 'Reason (sign-in required)'}
                    <textarea
                      name="reason"
                      required
                      maxLength={2000}
                      disabled={busy}
                    />
                  </label>
                  <button
                    type="submit"
                    className="settings-extension-button"
                    disabled={busy}
                  >
                    {ko ? '신고 제출' : 'Submit report'}
                  </button>
                </form>
              </details>
            )
          )}
        </>
      )}
    </div>
  )
}
