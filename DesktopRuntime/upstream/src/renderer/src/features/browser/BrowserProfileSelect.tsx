import { useBrowserProfiles } from './useBrowserProfiles'
import './browserProfiles.css'

export function BrowserProfileSelect({ value, onChange }: { value: string; onChange: (id: string) => void }): JSX.Element {
  const { profiles, loading, error, refresh } = useBrowserProfiles()
  const missing = !profiles.some(profile => profile.id === value)
  return <div className="browser-profile-select">
    <label>브라우저 프로필 <select aria-label="설정할 브라우저 프로필" value={value} disabled={loading || !!error || profiles.length === 0} onChange={e => onChange(e.target.value)}>
      {missing && <option value={value}>{loading ? '프로필을 불러오는 중…' : error ? '프로필을 불러올 수 없음' : '사용할 수 없는 프로필'}</option>}
      {profiles.map(p => <option key={p.id} value={p.id}>{p.icon} {p.name}</option>)}
    </select></label>
    {error && <div role="alert"><span>{error}</span><button type="button" onClick={() => void refresh()}>다시 불러오기</button></div>}
    {!loading && !error && missing && <p role="alert">선택한 프로필이 없습니다. 사용할 프로필을 선택해 주세요.</p>}
  </div>
}
