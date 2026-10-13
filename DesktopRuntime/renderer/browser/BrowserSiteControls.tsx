import { useEffect, useRef, useState } from 'react'
import { showToast } from '../../upstream/src/renderer/src/app/toast'
import './browser.css'

type Mode = 'desktop' | 'mobile' | 'automatic'
type Presentation = { mode: Mode; available: boolean }
export const browserRequest = (channel: string, request: unknown): Promise<unknown> =>
  (window.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>)(channel, request)

export function BrowserSiteControls({ tabId, profileId, url }: { tabId: string; profileId?: string; url: string }): JSX.Element {
  const [state, setState] = useState<Presentation>({ mode: 'automatic', available: false })
  const [busy, setBusy] = useState(false)
  const generation = useRef(0)
  useEffect(() => {
    const revision = ++generation.current
    setState({ mode: 'automatic', available: false }); setBusy(false)
    void browserRequest('browser:sitePresentation', { tabId }).then(value => {
      if (generation.current === revision) setState(value as Presentation)
    }).catch(() => { if (generation.current === revision) setState({ mode: 'automatic', available: false }) })
    return () => { ++generation.current }
  }, [tabId, profileId, url])
  const change = (mode: Mode): void => {
    const revision = generation.current
    setBusy(true)
    void browserRequest('browser:setSitePresentation', { tabId, mode }).then(value => {
      if (generation.current === revision) setState(value as Presentation)
    }).catch(() => { if (generation.current === revision) showToast('웹사이트 표시를 바꾸지 못했어요. 다시 시도해 주세요.', 'danger') })
      .finally(() => { if (generation.current === revision) setBusy(false) })
  }
  return <fieldset className="ipad-browser-presentation" data-keep-browser-menu disabled={!state.available || busy}>
    <legend>웹사이트 표시</legend>
    {([['desktop', '데스크톱'], ['mobile', '모바일'], ['automatic', '자동']] as const).map(([mode, label]) =>
      <button type="button" key={mode} aria-label={`${label} 웹사이트 요청`} aria-pressed={state.mode === mode} onClick={() => change(mode)}>{label}</button>)}
    <small>이 프로필의 사이트별 설정 · 변경하면 새로고침</small>
  </fieldset>
}

export function BrowserProfileMark({ icon }: { icon?: string | undefined }): JSX.Element {
  // Old native profile records used the SF Symbol name "globe"; never render
  // that implementation token as visible text in the original profile picker.
  if (icon && icon !== 'globe') return <>{icon}</>
  return <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c5 5 5 13 0 18-5-5-5-13 0-18Z"/></svg>
}
