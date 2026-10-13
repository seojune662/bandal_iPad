/**
 * Browser data: which sites the student is signed in to, their remembered
 * permissions, and how to forget any of it.
 *
 * `browser:sessionSites` / `browser:clearSession` were fully implemented in
 * main but had ZERO renderer callers — a working feature nobody could reach.
 * This is where they surface.
 *
 * Every class here is `settings-` prefixed on purpose: the settings surface
 * loads into the main window, and an unprefixed class has leaked into the
 * sidebar before (`.course-list`).
 */

import { useCallback, useEffect, useState } from 'react'
import { invoke } from '../../lib/ipc'
import type { Settings } from '../../../../shared/types/settings'

interface SignedInSite {
  origin: string
  cookieCount: number
}

interface SitePermission {
  id: string
  origin: string
  permission: string
  decision: 'granted' | 'denied'
  decidedAt: string
}

/** Same copy the prompt used, so the list reads back as what was asked. */
const PERMISSION_LABELS: Record<string, string> = {
  notifications: '알림 보내기',
  geolocation: '현재 위치 확인',
  media: '카메라와 마이크 사용',
  mediaKeySystem: '보호된 영상 재생',
  'clipboard-read': '클립보드 읽기',
  'display-capture': '화면 공유',
  midi: 'MIDI 기기 사용',
  midiSysex: 'MIDI 기기 사용',
  'window-management': '창 위치 관리',
  popups: '팝업 열기'
}

export function BrowsingDataPanel({
  profileId = 'default',
  settings: _settings
}: {
  profileId?: string
  settings: Settings | null
}): JSX.Element {
  const [sites, setSites] = useState<SignedInSite[] | null>(null)
  const [permissions, setPermissions] = useState<SitePermission[] | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [feedback, setFeedback] = useState<string | null>(null)
  const [sitesError, setSitesError] = useState(false)
  const [permissionsError, setPermissionsError] = useState(false)

  const loadSites = useCallback(() => {
    setSitesError(false)
    setSites(null)
    void invoke('browser:sessionSites', { profileId })
      .then((result) => setSites(result.sites))
      .catch(() => setSitesError(true))
  }, [profileId])

  const loadPermissions = useCallback(() => {
    setPermissionsError(false)
    setPermissions(null)
    void invoke('browser:sitePermissions', { profileId })
      .then((result) => setPermissions(result.permissions))
      .catch(() => setPermissionsError(true))
  }, [profileId])

  useEffect(() => loadSites(), [loadSites])
  useEffect(() => loadPermissions(), [loadPermissions])

  const forgetPermission = (id: string | null): void => {
    setBusy(id ?? 'permissions')
    void invoke('browser:forgetPermission', { profileId, id })
      .then(() => {
        setFeedback(
          id === null
            ? '사이트 권한을 모두 지웠습니다.'
            : '이 권한을 지웠습니다. 사이트가 다시 요청하면 새로 묻습니다.'
        )
        loadPermissions()
      })
      .catch(() => setFeedback('권한을 지우지 못했습니다.'))
      .finally(() => setBusy(null))
  }

  const forget = (origin: string | null): void => {
    setBusy(origin ?? '*')
    void invoke('browser:clearSession', { profileId, origin })
      .then(() => {
        setFeedback(
          origin === null
            ? '모든 사이트에서 로그아웃했습니다.'
            : `${origin}에서 로그아웃했습니다.`
        )
        loadSites()
      })
      .catch(() => setFeedback('로그아웃하지 못했습니다.'))
      .finally(() => setBusy(null))
  }

  /**
   * Cookies were never the whole story: an LMS keeps its token in
   * localStorage and a Canvas-style SPA restores from IndexedDB, so
   * "로그아웃" left the student logged in. A stale service worker serves an
   * old bundle forever, which is the "저만 깨져요" report with no fix.
   */
  const clearStorage = (): void => {
    setBusy('storage')
    void invoke('browser:clearStorage', { profileId, origin: null, cache: true })
      .then(() => {
        setFeedback('저장된 사이트 데이터와 캐시를 지웠습니다.')
        loadSites()
      })
      .catch(() => setFeedback('사이트 데이터를 지우지 못했습니다.'))
      .finally(() => setBusy(null))
  }

  const clearHistory = (): void => {
    setBusy('history')
    void invoke('browser:clearHistory', { profileId, courseId: null })
      .then(() => setFeedback('방문 기록을 지웠습니다.'))
      .catch(() => setFeedback('방문 기록을 지우지 못했습니다.'))
      .finally(() => setBusy(null))
  }

  return (
    <div className="settings-stack">
      <section className="settings-card">
        <div className="settings-card__header">
          <h2>로그인된 사이트</h2>
          <p>반달 브라우저가 기억하고 있는 학교 사이트 로그인입니다.</p>
        </div>
        {sitesError ? (
          <div className="settings-feedback settings-feedback--error" role="alert">
            로그인된 사이트를 불러오지 못했습니다.
            <button type="button" className="settings-site-row__action" onClick={loadSites}>다시 불러오기</button>
          </div>
        ) : sites === null ? (
          <p className="settings-feedback">불러오는 중…</p>
        ) : sites.length === 0 ? (
          <p className="settings-feedback">아직 없습니다.</p>
        ) : (
          <ul className="settings-site-list">
            {sites.map((site) => (
              <li key={site.origin} className="settings-site-row">
                <span className="settings-site-row__origin">{site.origin}</span>
                <button
                  type="button"
                  className="settings-site-row__action"
                  disabled={busy !== null}
                  onClick={() => forget(site.origin)}
                >
                  로그아웃
                </button>
              </li>
            ))}
          </ul>
        )}
        <div className="settings-danger-row">
          <button
            type="button"
            className="settings-site-row__action"
            disabled={busy !== null || (sites?.length ?? 0) === 0}
            onClick={() => forget(null)}
          >
            전체 로그아웃
          </button>
          <button
            type="button"
            className="settings-site-row__action"
            disabled={busy !== null}
            onClick={clearHistory}
          >
            방문 기록 지우기
          </button>
          <button
            type="button"
            className="settings-site-row__action"
            disabled={busy !== null}
            onClick={clearStorage}
          >
            사이트 데이터·캐시 지우기
          </button>
        </div>
        <p className="settings-feedback" aria-live="polite">
          {feedback ?? ''}
        </p>
      </section>

      <section className="settings-card">
        <div className="settings-card__header">
          <h2>사이트 권한</h2>
          <p>
            알림·위치·카메라처럼 사이트가 물어봤던 것들입니다. 지우면 다음에 다시
            묻습니다.
          </p>
        </div>
        {permissionsError ? (
          <div className="settings-feedback settings-feedback--error" role="alert">
            사이트 권한을 불러오지 못했습니다.
            <button type="button" className="settings-site-row__action" onClick={loadPermissions}>다시 불러오기</button>
          </div>
        ) : permissions === null ? (
          <p className="settings-feedback">불러오는 중…</p>
        ) : permissions.length === 0 ? (
          <p className="settings-feedback">아직 아무 사이트도 요청하지 않았습니다.</p>
        ) : (
          <ul className="settings-site-list">
            {permissions.map((entry) => (
              <li key={entry.id} className="settings-site-row">
                <span className="settings-site-row__origin">
                  {entry.origin} · {PERMISSION_LABELS[entry.permission] ?? entry.permission}
                  {' · '}
                  {entry.decision === 'granted' ? '허용함' : '차단함'}
                </span>
                <button
                  type="button"
                  className="settings-site-row__action"
                  disabled={busy !== null}
                  onClick={() => forgetPermission(entry.id)}
                >
                  지우기
                </button>
              </li>
            ))}
          </ul>
        )}
        {(permissions?.length ?? 0) > 0 && (
          <div className="settings-danger-row">
            <button
              type="button"
              className="settings-site-row__action"
              disabled={busy !== null}
              onClick={() => forgetPermission(null)}
            >
              전체 지우기
            </button>
          </div>
        )}
      </section>
    </div>
  )
}
