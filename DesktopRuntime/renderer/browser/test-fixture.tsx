import { createRoot } from 'react-dom/client'
import { useState, type ComponentType } from 'react'
import * as BrowserPanel from '../../upstream/src/renderer/src/features/browser/BrowserPanel'
import { useDownloads } from '../../upstream/src/renderer/src/features/browser/downloadsStore'
import { useBrowserGuests, type BrowserNavState } from '../../upstream/src/renderer/src/features/browser/browserGuestsStore'
import '../../upstream/src/renderer/src/styles/tokens.css'
import '../../upstream/src/renderer/src/styles/base.css'
import '../../upstream/src/renderer/src/features/browser/browser.css'
import './browser.css'

// The adapter exports the shipped toolbar so tests cover its real responsive
// layout and menu composition, without instantiating the workspace dockview.
const Toolbar = (BrowserPanel as unknown as { BrowserToolbar: ComponentType<Record<string, unknown>> }).BrowserToolbar
const fixture = window as unknown as {
  downloadsState: () => unknown
  selectFixtureProfile: (id: string) => void
  setFixtureURL: (url: string) => void
  setFixturePrivate: (value: boolean) => void
  setFixtureProgress: (progress: number, loading: boolean) => void
  setFixtureDownloads: (count: number) => void
}
useDownloads.getState().init()
useBrowserGuests.getState().ensureGuest('fixture', 'https://example.test/reading')
useBrowserGuests.getState().updateNav('fixture', { canGoForward: true, canGoBack: true })
fixture.downloadsState = () => useDownloads.getState().downloads
fixture.setFixtureProgress = (estimatedProgress, loading) => useBrowserGuests.getState().updateNav('fixture', { estimatedProgress, loading } as Partial<BrowserNavState>)
fixture.setFixtureDownloads = activeCount => useDownloads.setState({ activeCount })
function Fixture(): JSX.Element {
  const [profile, setProfile] = useState('default'), [isPrivate, setPrivate] = useState(false)
  fixture.selectFixtureProfile = setProfile
  fixture.setFixturePrivate = setPrivate
  const nav = useBrowserGuests(state => state.nav.fixture)!
  const navigate = (url: string): void => useBrowserGuests.getState().updateNav('fixture', { url })
  fixture.setFixtureURL = navigate
  return <div className="browser-panel" data-private={isPrivate || undefined}>
    <Toolbar tabId="fixture" ownerCourse={null} nav={nav} onNavigate={navigate} isPrivate={isPrivate}
      onTogglePrivate={() => setPrivate(value => !value)} profileId={profile}
      onProfileChange={async (id: string) => { setProfile(id); return true }} sessionChanging={false} isPanelVisible={true} />
    <div className="browser-page-area" style={{ padding: 24, minHeight: 420, background: 'var(--bg-app)' }}>
      <h1>앱 안에서 이어지는 웹 탐색</h1><p>주소 입력, 페이지 도구, 방문 기록과 다운로드</p><div id="url">{nav.url}</div>
    </div>
  </div>
}
createRoot(document.getElementById('root')!).render(<Fixture />)
