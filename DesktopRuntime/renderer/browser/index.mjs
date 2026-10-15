import { fileURLToPath } from 'node:url'
import { adaptBrowserRecoverySource } from './recovery-adapter.mjs'
const controls = fileURLToPath(new URL('./BrowserSiteControls.tsx', import.meta.url))
const downloads = fileURLToPath(new URL('./downloads.ts', import.meta.url))
const pageControls = fileURLToPath(new URL('./BrowserPageControls.tsx', import.meta.url))
const chromeControls = fileURLToPath(new URL('./BrowserChromeControls.tsx', import.meta.url))
function replace(source, needle, value, count = 1) {
  if (source.split(needle).length - 1 !== count) throw new Error(`iPad browser adapter anchor changed: ${needle}`)
  return source.split(needle).join(value)
}
export function adaptBrowserSource(source, id) {
  let code = source
  if (id.endsWith('/features/browser/BrowserGuestView.tsx')) {
    code = replace(code, "import { isDefaultZoom } from './zoom'", "import { settingsSnapshot } from '../../stores/settingsSnapshot'\nimport { showToast } from '../../app/toast'")
    code = replace(code, '    const applyZoom = (): void => {', `    const initialZoomLevel = settingsSnapshot().browser.defaultZoomLevel
    let zoomAttempt = 0, zoomFailureShown = false
    const applyZoom = (): void => {`)
    code = replace(code, `      const level = useBrowserGuests.getState().zoom[tabId]
      if (level === undefined || isDefaultZoom(level)) return`, `      const store = useBrowserGuests.getState()
      const saved = store.zoom[tabId]
      const level = saved ?? initialZoomLevel
      // The preference is a new-tab default. Once chosen, retain this tab's
      // value when settings change, it navigates, or its native page remounts.
      const attempt = ++zoomAttempt`)
    code = replace(code, `        void element.setZoomLevel(level).catch(() => undefined)`, `        void element.setZoomLevel(level).then(() => {
          if (disposed || attempt !== zoomAttempt) return
          zoomFailureShown = false
          const current = useBrowserGuests.getState()
          if (saved === undefined && current.zoom[tabId] === undefined) current.setZoom(tabId, level)
        }).catch(() => {
          if (disposed || attempt !== zoomAttempt || zoomFailureShown || useBrowserGuests.getState().zoom[tabId] !== saved) return
          zoomFailureShown = true
          showToast('페이지 크기를 적용하지 못했어요. 다시 불러오면 재시도합니다.', 'danger')
        })`)
  }
  if (id.endsWith('/features/browser/BrowserPanel.tsx')) {
    code = `import { BrowserSiteControls } from ${JSON.stringify(controls)}\n` + code
    code = `import { BrowserPageControls } from ${JSON.stringify(pageControls)}\n` + code
    code = `import { BrowserMenuSection, BrowserShareButton, BrowserDownloadsButton, BrowserSaveControls, BrowserHistoryControls, BrowserLoadingProgress } from ${JSON.stringify(chromeControls)}\n` + code
    code = replace(code, 'function BrowserToolbar({', 'export function BrowserToolbar({')
    // Preserve all login prompts and keyboard actions while giving the touch
    // chrome its own compact grouping; never alter the upstream snapshot.
    const menuStart = code.indexOf('          <BrowserToolbarOverflow isPrivate={isPrivate} active={isPanelVisible}>')
    const menuEnd = code.indexOf('          </BrowserToolbarOverflow>', menuStart)
    if (menuStart < 0 || menuEnd < 0) throw new Error('iPad browser toolbar menu anchor changed')
    code = code.slice(0, menuStart) + `          <BrowserToolbarOverflow isPrivate={isPrivate} active={isPanelVisible}>
            <BrowserMenuSection title="페이지">
              <button type="button" className="browser-nav-button ipad-browser-menu-compact" aria-label="앞으로" disabled={!nav.canGoForward} onClick={() => guestActions.forward(tabId)}><BrowserIcon name="arrowRight" /></button>
              <button type="button" className="browser-nav-button" aria-label="홈페이지로 이동" onClick={() => onNavigate(settingsSnapshot().browser.homePage || DEFAULT_BROWSER_URL)}><BrowserIcon name="home" /></button>
              <BrowserPageControls tabId={tabId} />
              <BrowserSiteControls tabId={tabId} profileId={profileId} url={nav.url} />
              <BrowserPipChip hasPlayingVideo={video?.hasPlayingVideo === true} onOpen={() => {
                void openWebVideoInPip(tabId, { url: nav.url, title: nav.title }).catch(() => showToast('작은 창을 열지 못했어요.', 'danger'))
              }} />
            </BrowserMenuSection>
            <BrowserMenuSection title="즐겨찾기 및 기록">
              {!isPrivate && <BrowserFavoriteButton starred={starred !== null} onToggle={() => toggleFavorite(tabId, nav)} />}
              <BrowserHistoryControls profileId={profileId} isPrivate={isPrivate} onNavigate={onNavigate} />
              <BrowserDownloadsButton className="ipad-browser-menu-compact" count={activeDownloads} expanded={downloadsAnchor !== null} onClick={openDownloads} />
            </BrowserMenuSection>
            <BrowserMenuSection title="공유 및 저장">
              <BrowserShareButton className="ipad-browser-menu-compact" tabId={tabId} />
              <BrowserSaveControls tabId={tabId} title={nav.title} url={nav.url} />
            </BrowserMenuSection>
            <BrowserMenuSection title="프로필">
              <div className="ipad-browser-menu-session" data-keep-browser-menu><BrowserProfilePicker profileId={profileId} onChange={onProfileChange} /><AssistantPanelToggle /></div>
              <button type="button" className="browser-nav-button browser-private-button" aria-label={isPrivate ? '비공개 브라우징 끄기' : '비공개 브라우징 켜기'} aria-pressed={isPrivate} disabled={sessionChanging} onClick={onTogglePrivate}><BrowserIcon name="private" /></button>
            </BrowserMenuSection>
          </BrowserToolbarOverflow>` + code.slice(menuEnd + '          </BrowserToolbarOverflow>'.length)
    const reloadStart = code.indexOf("          <Tooltip label={nav.loading ? '중지' : '새로고침'} placement=\"bottom\">")
    const reloadEnd = code.indexOf('          </Tooltip>', reloadStart) + '          </Tooltip>'.length
    if (reloadStart < 0 || reloadEnd < reloadStart) throw new Error('iPad browser reload anchor changed')
    const reloadButton = code.slice(reloadStart, reloadEnd)
    code = code.slice(0, reloadStart) + code.slice(reloadEnd)
    code = replace(code, '          <BrowserProfilePicker profileId={profileId} onChange={onProfileChange} />', `${reloadButton}
          <BrowserShareButton className="ipad-browser-inline-action" tabId={tabId} />
          <BrowserDownloadsButton className="ipad-browser-inline-action" count={activeDownloads} expanded={downloadsAnchor !== null} onClick={openDownloads} />`)
    code = replace(code, '          <AssistantPanelToggle className="browser-assistant-toggle" />', '')
    code = replace(code, '  const goBack = (): void => {', `  const openDownloads = (event: React.MouseEvent<HTMLButtonElement>): void => {
    setDiagnosticsAnchor(null)
    setDownloadsAnchor(downloadsAnchor === null ? event.currentTarget.getBoundingClientRect() : null)
  }
  const goBack = (): void => {`)
    code = replace(code, `      <div
        className="browser-progress"
        data-active={progressVisible ? 'true' : undefined}
        aria-hidden="true"
      >
        <div className="browser-progress__bar" />
      </div>`, '      <BrowserLoadingProgress tabId={tabId} loading={nav.loading} visible={progressVisible} />')
  }
  if (id.endsWith('/features/browser/BrowserAddressInput.tsx')) {
    code = `import { BrowserConnectionStatus } from ${JSON.stringify(chromeControls)}\n` + code
    code = replace(code, `      <span className={\`browser-address__security\${parts.secure ? '' : ' browser-address__security--insecure'}\`}
        title={parts.secure ? '이 연결은 암호화돼 있어요' : '암호화되지 않은 연결이에요. 비밀번호를 입력하지 마세요.'}
        aria-label={parts.secure ? '보안 연결' : '보안되지 않은 연결'}>
        <BrowserIcon name={parts.secure ? 'lock' : 'insecure'} />
      </span>`, '      <BrowserConnectionStatus url={value} isPrivate={isPrivate} />')
    code = replace(code, "import { BrowserIcon } from './browserIcons'\n", '')
    // Do not cancel the keydown that the Korean IME uses to commit a syllable.
    // Some WebKit keyboards report only keyCode=229, others only composition.
    code = replace(code, "          onKeyDown={(event) => {\n            if (event.key === 'Enter') {", "          onKeyDown={(event) => {\n            if (event.nativeEvent.isComposing || composing.current || event.nativeEvent.keyCode === 229) return\n            if (event.key === 'Enter') {")
    code = replace(code, '<span>{parts.prefix}</span><strong>{parts.domain}</strong>', '<strong>{parts.domain}</strong>')
  }
  if (id.endsWith('/features/browser/BrowserToolbarOverflow.tsx')) {
    code = "import { useDownloads } from './downloadsStore'\n" + code
    code = replace(code, '<div className="browser-toolbar__utilities">{children}</div>', '')
    code = replace(code, 'className="browser-toolbar-menu"', `className="browser-toolbar-menu" data-compact={(trigger.current?.closest('.browser-chrome')?.getBoundingClientRect().width ?? window.innerWidth) <= 700 || undefined}`)
    code = replace(code, '  const [anchor, setAnchor]', '  const activeDownloads = useDownloads(state => state.activeCount)\n  const [anchor, setAnchor]')
    code = replace(code, '</svg>\n      </button>', '</svg>{activeDownloads > 0 && <span className="ipad-browser-download-count" aria-label={`${activeDownloads}개 다운로드 진행 중`}>{activeDownloads}</span>}\n      </button>')
    code = replace(code, '    const outside = (event: PointerEvent): void => {', "    const outside = (event: PointerEvent): void => {\n      if (event.target instanceof Element && event.target.closest('.browser-profile-manager-backdrop')) return")
    code = replace(code, "if ((event.target as HTMLElement).closest('button:not(:disabled)')) close()", "if (!(event.target as HTMLElement).closest('[data-keep-browser-menu], .browser-profile-manager-backdrop') && (event.target as HTMLElement).closest('button:not(:disabled)')) close()")
    code = replace(code, "anchor.right - 220, window.innerWidth - 228", "anchor.right - 280, window.innerWidth - 288")
  }
  if (id.endsWith('/features/browser/BrowserProfilePicker.tsx')) {
    code = `import { BrowserProfileMark } from ${JSON.stringify(controls)}\n` + code
    code = replace(code, "{current?.icon ?? '●'}</span>", '{<BrowserProfileMark icon={current?.icon} />}</span>')
    code = replace(code, '{p.icon}</span>', '{<BrowserProfileMark icon={p.icon} />}</span>')
    code = replace(code, '<option key={value} value={value}>{value}</option>', '<option key={value} value={value}>{value === \'globe\' ? \'기본\' : value}</option>')
  }
  if (id.endsWith('/features/browser/BrowserContextMenu.tsx')) {
    code = replace(code, 'const items = contextMenuItems(state).map', "const items = contextMenuItems(state).filter(id => id !== 'inspect').map")
  }
  if (id.endsWith('/features/browser/downloadsStore.ts')) {
    code = `import { restoreDownloads, dismissNativeDownload } from ${JSON.stringify(downloads)}\n` + code
    code = replace(code, '    initialized = true', '    initialized = true\n    restoreDownloads(set, get)')
    code = replace(code, '  dismiss: (id) => {', '  dismiss: (id) => {\n    dismissNativeDownload(id)')
  }
  if (id.endsWith('/features/browser/BrowserDownloadPage.tsx')) {
    code = replace(code, "    {(download?.state === 'completed'", "    {(download?.state === 'interrupted' || download?.state === 'cancelled') && <button className=\"browser-error__action\" onClick={() => action('retry')}>다시 받기</button>}\n    {(download?.state === 'completed'")
  }
  if (id.endsWith('/features/browser/BrowserDownloadsPanel.tsx')) {
    code = replace(code, "{(download.state === 'completed' || download.recoverable) && (", "{(download.state === 'interrupted' || download.state === 'cancelled') && <button type=\"button\" className=\"browser-downloads__action\" onClick={() => fileAction(download.id, 'retry')}>다시 받기</button>}\n                  {(download.state === 'completed' || download.recoverable) && (")
  }
  code = adaptBrowserRecoverySource(code, id)?.code ?? code
  return code === source ? null : { code, map: null }
}
export default function browserPlugin() {
  return { name: 'bandal-ipad-browser', enforce: 'pre', transform(code, id) { return adaptBrowserSource(code, id.replaceAll('\\', '/')) } }
}
