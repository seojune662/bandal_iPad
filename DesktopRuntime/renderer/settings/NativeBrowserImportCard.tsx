import { useState } from 'react'
import { useLocale } from '../../upstream/src/renderer/src/i18n'
import { SettingsCard } from '../../upstream/src/renderer/src/features/settings/primitives'
import { useFavoritesStore } from '../../upstream/src/renderer/src/stores/favoritesStore'

interface ImportResult { imported: number; skipped: number; ignored?: number; cancelled?: boolean }
export function NativeBrowserImportCard({ profileId }: { profileId: string }): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [busy, setBusy] = useState(false), [feedback, setFeedback] = useState(''), [failed, setFailed] = useState(false)
  const run = async (kind: 'bookmarks' | 'passwords'): Promise<void> => {
    if (busy) return
    setBusy(true); setFeedback(''); setFailed(false)
    try {
      const channel = kind === 'bookmarks' ? 'browser:importBookmarkFile' : 'credentials:importCsv'
      const result = await (window.bandal.invoke as (channel: string, request: unknown) => Promise<ImportResult>)(channel, { profileId })
      if (result.cancelled) return
      if (kind === 'bookmarks') await useFavoritesStore.getState().load(null)
      setFeedback(ko ? `${result.imported}개 가져옴 · ${result.skipped}개 건너뜀` : `${result.imported} imported · ${result.skipped} skipped`)
    } catch (error) {
      setFailed(true); setFeedback(error instanceof Error ? error.message : ko ? '파일을 가져오지 못했습니다.' : 'Could not import this file.')
    } finally { setBusy(false) }
  }
  return <SettingsCard title={ko ? '브라우저 데이터 가져오기' : 'Import browser data'} description={ko ? '다른 브라우저에서 내보낸 파일을 선택한 프로필로 가져옵니다. 다른 앱의 저장소를 직접 읽지는 않습니다.' : 'Import an exported file into the selected profile. Other apps’ storage cannot be read directly.'}>
    <p className="setting-row__description">{ko ? '북마크는 공통 즐겨찾기에 추가되고 선택한 프로필로 열립니다. 폴더는 하나의 목록으로 합치며 같은 주소는 기존 이름을 유지합니다. 유효한 HTTP·HTTPS 링크만 가져옵니다.' : 'Bookmarks appear in shared favorites and open in the selected profile. Folders become one list; existing names are kept for duplicate URLs. Only valid HTTP and HTTPS links are imported.'}</p>
    <div className="settings-card__rows"><button type="button" className="secondary-button" disabled={busy} onClick={() => void run('bookmarks')}>{ko ? 'HTML 북마크 가져오기' : 'Import HTML bookmarks'}</button>
    <button type="button" className="secondary-button" disabled={busy} onClick={() => void run('passwords')}>{ko ? 'CSV 로그인 가져오기' : 'Import CSV logins'}</button></div>
    {feedback && <p className="settings-feedback" role={failed ? 'alert' : 'status'}>{feedback}</p>}
  </SettingsCard>
}
