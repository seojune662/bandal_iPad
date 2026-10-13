import { useCallback, useEffect, useRef, useState } from 'react'
import type { AppleCalendarState } from '../../../../shared/types/appleCalendar'
import { invoke, onPush } from '../../lib/ipc'
import { useLocale } from '../../i18n'
import { SettingsCard } from '../settings/primitives'
import './appleCalendar.css'

export function CalendarSettingsPanel(): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [state, setState] = useState<AppleCalendarState | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState('')
  const sequence = useRef(0)
  const saving = useRef(false)
  const refresh = useCallback(async () => {
    if (saving.current) return
    const current = ++sequence.current
    try {
      const value = await invoke('appleCalendar:state', {})
      if (current === sequence.current) { setState(value); setError(null) }
    } catch (e) { if (current === sequence.current) setError(e instanceof Error ? e.message : '캘린더를 불러오지 못했습니다.') }
  }, [])
  useEffect(() => {
    void refresh()
    const focus = () => { void refresh() }
    window.addEventListener('focus', focus)
    const off = onPush('appleCalendar:changed', focus)
    return () => { sequence.current++; off(); window.removeEventListener('focus', focus) }
  }, [refresh])
  const run = async (action: () => Promise<AppleCalendarState>, message: string) => {
    if (saving.current) return
    saving.current = true
    const current = ++sequence.current
    setBusy(true); setError(null); setNotice('')
    try { const value = await action(); if (current === sequence.current) { setState(value); setNotice(message) } }
    catch (e) { if (current === sequence.current) setError(e instanceof Error ? e.message : '캘린더 설정을 저장하지 못했습니다.') }
    finally { saving.current = false; if (current === sequence.current) setBusy(false) }
  }
  const ready = state?.connected === true && state.authorization === 'authorized'
  const denied = state?.authorization === 'denied' || state?.authorization === 'restricted' || state?.authorization === 'write-only'
  const change = (selectedCalendarIds: string[], destinationCalendarId: string | null) =>
    run(() => invoke('appleCalendar:configure', { selectedCalendarIds, destinationCalendarId }), ko ? '저장했어요. 달력에 바로 반영됩니다.' : 'Saved. Your calendar is up to date.')
  return <div className="settings-stack apple-calendar-settings" aria-busy={busy}>
    <SettingsCard title="Apple Calendar" description={ko ? 'Mac의 캘린더 앱에 연결된 iCloud·로컬 캘린더를 반달에서 함께 봅니다.' : 'Bring the iCloud and local calendars in your Mac Calendar app into Bandal.'}>
      <div className="settings-card__body">
      <div className="apple-calendar-connection">
        <div><strong>{ready ? (ko ? '연결됨' : 'Connected') : (ko ? '내 일정과 공부를 한곳에' : 'Your schedule, alongside your studies')}</strong>
          <p>{state?.supported === false ? (ko ? 'Apple 캘린더 연결은 macOS 앱에서 사용할 수 있어요.' : 'Apple Calendar is available in the macOS app.') : ready ? (ko ? '선택한 캘린더만 표시합니다. 변경 사항은 달력을 열거나 새로고침하면 반영됩니다.' : 'Only selected calendars are shown. Changes refresh when you open or refresh the calendar.') : (ko ? '연결할 때 macOS에서 캘린더 전체 접근 권한을 요청합니다. 일정은 이 Mac에서만 읽습니다.' : 'macOS will ask for full calendar access when you connect. Events are read on this Mac only.')}</p>
        </div>
        {state?.supported && <button className="secondary-button" disabled={busy} onClick={() => void run(() => invoke(state.connected ? 'appleCalendar:disconnect' : 'appleCalendar:connect', {}), '')}>
          {busy ? (ko ? '처리 중…' : 'Working…') : state.connected ? (ko ? '연결 해제' : 'Disconnect') : (ko ? 'Apple 캘린더 연결' : 'Connect Apple Calendar')}
        </button>}
      </div>
      {state === null && !error && <p role="status">{ko ? '연결 상태 확인 중…' : 'Checking connection…'}</p>}
      {denied && <div className="apple-calendar-notice"><p>{ko ? '시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서 반달의 전체 접근을 허용해주세요.' : 'Allow full access for Bandal in System Settings → Privacy & Security → Calendars.'}</p><button className="secondary-button" onClick={() => void invoke('appleCalendar:permissions', {}).catch(e => setError(String(e)))}>{ko ? '시스템 설정 열기' : 'Open System Settings'}</button></div>}
      {ready && <p className="apple-calendar-hint">{ko ? '연결을 해제해도 Apple 캘린더에 보낸 일정은 삭제되지 않습니다. 시스템 권한은 macOS 설정에서 관리합니다.' : 'Disconnecting keeps events you exported. Manage system permissions in macOS Settings.'}</p>}
      </div>
    </SettingsCard>
    {error && <div className="apple-calendar-notice" role="alert"><p>{error}</p><button className="secondary-button" disabled={busy} onClick={() => void refresh()}>{ko ? '다시 확인' : 'Retry'}</button></div>}
    {notice && <p className="apple-calendar-hint" role="status">{notice}</p>}
    {ready && state && <>
      <SettingsCard title={ko ? '달력에서 볼 캘린더' : 'Calendars to display'} description={ko ? '읽기 전용·구독 캘린더도 볼 수 있어요. 모두 해제하면 외부 일정이 표시되지 않습니다.' : 'Read-only and subscribed calendars work too. Uncheck all to hide external events.'}>
        <div className="settings-card__body">
        <div className="apple-calendar-list">
          {state.calendars.map(calendar => <label key={calendar.id} className="apple-calendar-choice"><input type="checkbox" disabled={busy} checked={state.selectedCalendarIds.includes(calendar.id)} onChange={e => void change(e.target.checked ? [...state.selectedCalendarIds, calendar.id] : state.selectedCalendarIds.filter(id => id !== calendar.id), state.destinationCalendarId)} /><span className="apple-calendar-dot" style={{ backgroundColor: calendar.color }} /><span><strong>{calendar.title}</strong><small>{calendar.source}{!calendar.writable ? (ko ? ' · 읽기 전용' : ' · Read only') : ''}</small></span></label>)}
          {state.calendars.length === 0 && <p>{ko ? 'Mac의 캘린더 앱에서 먼저 계정이나 캘린더를 추가해주세요.' : 'Add an account or calendar in the Mac Calendar app first.'}</p>}
        </div>
        <button className="secondary-button" disabled={busy} onClick={() => void refresh()}>{ko ? '캘린더 목록 새로고침' : 'Refresh calendars'}</button>
        </div>
      </SettingsCard>
      <SettingsCard title={ko ? '반달 일정을 보낼 곳' : 'Where to send Bandal events'} description={ko ? '달력에서 과제·일정을 열고 “Apple 캘린더로 보내기”를 누르세요. 다시 보내면 기존 일정이 갱신됩니다. 자동 양방향 동기화는 하지 않습니다.' : 'Open a task in the calendar and choose “Send to Apple Calendar”. Sending it again updates the existing event. Changes do not sync automatically in both directions.'}>
        <div className="settings-card__body">
        <label className="apple-calendar-destination"><span>{ko ? '저장할 캘린더' : 'Destination calendar'}</span><select disabled={busy} value={state.destinationCalendarId ?? ''} onChange={e => void change(state.selectedCalendarIds, e.target.value || null)}><option value="">{ko ? '선택해주세요' : 'Choose a calendar'}</option>{state.destinationCalendarId && !state.calendars.some(c => c.id === state.destinationCalendarId && c.writable) && <option value={state.destinationCalendarId} disabled>{ko ? '이전 캘린더를 사용할 수 없습니다' : 'Previous calendar unavailable'}</option>}{state.calendars.filter(c => c.writable).map(c => <option key={c.id} value={c.id}>{c.title} · {c.source}</option>)}</select></label>
        <p className="apple-calendar-hint">{ko ? '마감 일정은 지정 시각에, 기간 일정은 설정한 시작·종료에 맞춰 저장합니다. 원본 과제를 삭제해도 보낸 일정은 유지됩니다.' : 'Deadlines keep their exact time; events keep their start and end dates. Deleting a task keeps the exported event.'}</p>
        </div>
      </SettingsCard>
    </>}
  </div>
}
