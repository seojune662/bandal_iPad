import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { PROFILE_COLORS, type BrowserProfile } from '../../../../shared/types/browserProfile'
import { useFocusTrap } from '../../components/useFocusTrap'
import { invoke } from '../../lib/ipc'
import { notifyBrowserProfilesChanged, useBrowserProfiles } from './useBrowserProfiles'
import { acquirePointerPassthrough } from './webviewPassthrough'
import './browserProfiles.css'

const COLOR_NAMES = ['초록', '파랑', '보라', '주황', '분홍']
const ICONS = ['●', '◆', '★', '■', '▲']

export function BrowserProfilePicker({ profileId, onChange }: {
  profileId: string
  onChange: (id: string) => Promise<boolean | void>
}): JSX.Element {
  const { profiles, loading, error: loadError, refresh } = useBrowserProfiles()
  const [open, setOpen] = useState(false)
  // null is the profile list, '' creates a profile, and an id edits one.
  const [editing, setEditing] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [color, setColor] = useState<string>(PROFILE_COLORS[0])
  const [icon, setIcon] = useState('●')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const running = useRef(false)
  const dialogRef = useRef<HTMLElement>(null)
  const nameRef = useRef<HTMLInputElement>(null)
  const descriptionId = useId()
  const currentNameId = useId()
  const current = profiles.find(p => p.id === profileId)
  const currentName = current?.name ?? (profileId === 'default' ? '기본' : '프로필 선택')

  const close = (): void => {
    if (running.current) return
    setOpen(false)
    setEditing(null)
    setError('')
    setNotice('')
  }
  useFocusTrap(dialogRef, { active: open, onEscape: close })
  useEffect(() => {
    if (!open) return
    return acquirePointerPassthrough()
  }, [open])
  useEffect(() => {
    if (editing !== null) nameRef.current?.focus()
  }, [editing])

  const run = async (action: () => Promise<void>): Promise<void> => {
    if (running.current) return
    running.current = true
    setBusy(true)
    setError('')
    setNotice('')
    try { await action() }
    catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { running.current = false; setBusy(false) }
  }
  const selectProfile = async (id: string): Promise<void> => {
    const changed = await onChange(id)
    if (changed === false) {
      setNotice('페이지를 떠나지 않아 프로필 전환을 취소했습니다. 현재 로그인은 그대로 유지됩니다.')
      return
    }
    setEditing(null)
    setOpen(false)
  }
  const editProfile = (profile?: BrowserProfile): void => {
    setEditing(profile?.id ?? '')
    setName(profile?.name ?? '')
    setColor(profile?.color ?? PROFILE_COLORS[profiles.length % PROFILE_COLORS.length] ?? PROFILE_COLORS[0])
    setIcon(profile?.icon ?? '●')
    setError('')
    setNotice('')
  }

  return <>
    <button
      type="button"
      className="browser-profile-trigger"
      aria-label="브라우저 프로필"
      aria-describedby={currentNameId}
      aria-haspopup="dialog"
      aria-expanded={open}
      title={`브라우저 프로필: ${currentName} · 이 탭의 로그인 계정 분리 및 변경`}
      onClick={() => { setOpen(true); void refresh() }}
    >
      <span className="browser-profile-trigger__icon" aria-hidden="true" style={{ color: current?.color }}>{current?.icon ?? '●'}</span>
      <span id={currentNameId} className="browser-profile-trigger__name">{currentName}</span>
      <span className="browser-profile-trigger__chevron" aria-hidden="true">⌄</span>
    </button>
    {open && createPortal(<div className="browser-profile-manager-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) close() }}>
      <section ref={dialogRef} className="browser-profile-manager" role="dialog" aria-modal="true" aria-label="브라우저 프로필 선택" aria-describedby={descriptionId} aria-busy={busy}>
        <header className="browser-profile-manager__header">
          <div><h2>브라우저 프로필</h2><p>이 탭에서 사용할 로그인 공간을 선택하세요.</p></div>
          <button type="button" className="browser-profile-manager__close" aria-label="닫기" disabled={busy} onClick={close}>×</button>
        </header>
        <div id={descriptionId} className="browser-profile-manager__help">
          <strong>학교 계정과 개인 계정을 따로 사용할 수 있어요.</strong>
          <p>프로필마다 웹사이트 로그인·쿠키·방문 기록이 분리됩니다. Bandal 로그인 계정과는 별개이며, 새 프로필에서는 원하는 계정으로 사이트에 로그인하세요.</p>
        </div>
        <div className="browser-profile-manager__section-heading"><h3>내 프로필</h3><span>현재 탭에만 적용</span></div>
        {loading && <p role="status">프로필을 불러오는 중…</p>}
        {loadError && <div className="browser-profile-manager__error" role="alert"><span>{loadError}</span><button type="button" disabled={loading || busy} onClick={() => void refresh()}>다시 불러오기</button></div>}
        <div className="browser-profile-manager__list">{profiles.map(p => <div key={p.id} className="browser-profile-manager__row" data-current={p.id === profileId}>
          <button type="button" className="browser-profile-manager__choose" disabled={busy || loading || !!loadError} aria-pressed={p.id === profileId} onClick={() => void run(() => selectProfile(p.id))}>
            <span className="browser-profile-manager__avatar" aria-hidden="true" style={{ color: p.color }}>{p.icon}</span>
            <span className="browser-profile-manager__identity"><strong>{p.name}</strong><small>{p.id === profileId ? '이 탭에서 사용 중' : '이 프로필로 전환'}</small></span>
            {p.id === profileId && <span aria-hidden="true">✓</span>}
          </button>
          <button type="button" disabled={busy || loading || !!loadError} aria-label={`${p.name} 편집`} onClick={() => editProfile(p)}>편집</button>
          {p.id !== 'default' && <button type="button" className="browser-profile-manager__delete" disabled={busy || loading || !!loadError || p.id === profileId} title={p.id === profileId ? '다른 프로필로 전환하고 이 프로필의 모든 탭을 닫은 뒤 삭제할 수 있습니다.' : '프로필과 저장된 로그인·방문 기록 삭제'} aria-label={`${p.name} 삭제`} onClick={() => void run(async () => {
            await invoke('browser:deleteProfile', { id: p.id })
            if (editing === p.id) setEditing(null)
            notifyBrowserProfilesChanged()
          })}>삭제</button>}
        </div>)}</div>
        {!loading && !loadError && !current && <p className="browser-profile-manager__error" role="alert">현재 탭의 프로필을 찾을 수 없습니다. 사용할 프로필을 선택해 주세요.</p>}
        {editing === null ? <button type="button" className="browser-profile-manager__add" disabled={busy || loading || !!loadError} onClick={() => editProfile()}>＋ 새 프로필 만들기</button> : <form className="browser-profile-manager__form" onSubmit={e => {
          e.preventDefault()
          if (!name.trim()) return
          void run(async () => {
            const creating = editing === ''
            const saved = await invoke('browser:saveProfile', { ...(editing ? { id: editing } : {}), name: name.trim(), color, icon })
            // Saving succeeded even if switching is later cancelled or fails.
            // Exit the form before switching so a retry cannot create duplicates.
            setEditing(null)
            notifyBrowserProfilesChanged()
            if (creating) await selectProfile(saved.id)
            else setNotice('프로필을 저장했습니다.')
          })
        }}>
          <h3>{editing ? '프로필 편집' : '새 프로필 만들기'}</h3>
          <div className="browser-profile-manager__fields">
            <label className="browser-profile-manager__name-field">이름<input ref={nameRef} aria-label="프로필 이름" placeholder="예: 학교, 개인, ChatGPT" value={name} disabled={busy} onChange={e => setName(e.target.value)} maxLength={40} required /></label>
            <label>아이콘<select aria-label="프로필 아이콘" value={icon} disabled={busy} onChange={e => setIcon(e.target.value)}>{(ICONS.includes(icon) ? ICONS : [icon, ...ICONS]).map(value => <option key={value} value={value}>{value}</option>)}</select></label>
          </div>
          <fieldset disabled={busy} className="browser-profile-manager__colors"><legend>프로필 색상</legend>{PROFILE_COLORS.map((c, i) => <button type="button" key={c} aria-label={`${COLOR_NAMES[i]} 프로필 색상`} aria-pressed={color === c} onClick={() => setColor(c)}><span aria-hidden="true" style={{ background: c }} />{COLOR_NAMES[i]}{color === c && <span aria-hidden="true">✓</span>}</button>)}</fieldset>
          {!editing && <p>만든 프로필로 이 페이지를 다시 엽니다. 다른 탭의 로그인은 유지됩니다.</p>}
          <div className="browser-profile-manager__form-actions"><button type="button" disabled={busy} onClick={() => setEditing(null)}>취소</button><button className="browser-profile-manager__primary" disabled={busy || !name.trim()} type="submit">{busy ? '처리 중…' : editing ? '저장' : '만들고 이 탭에서 사용'}</button></div>
        </form>}
        {error && <p className="browser-profile-manager__error" role="alert">{error}</p>}
        {notice && <p className="browser-profile-manager__notice" role="status">{notice}</p>}
        <p className="browser-profile-manager__footer">프로필을 바꾸면 현재 페이지를 다시 엽니다. 과목 자료는 함께 사용하고 즐겨찾기는 저장한 프로필로 열립니다.</p>
      </section>
    </div>, document.body)}
  </>
}
