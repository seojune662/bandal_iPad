import { fileURLToPath } from 'node:url'
const controls = fileURLToPath(new URL('./BrowserSiteControls.tsx', import.meta.url))
const downloads = fileURLToPath(new URL('./downloads.ts', import.meta.url))
const pageControls = fileURLToPath(new URL('./BrowserPageControls.tsx', import.meta.url))
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
    code = replace(code, '<BrowserToolbarOverflow isPrivate={isPrivate} active={isPanelVisible}>', `<BrowserToolbarOverflow isPrivate={isPrivate} active={isPanelVisible}>
          <div className="ipad-browser-menu-session" data-keep-browser-menu><BrowserProfilePicker profileId={profileId} onChange={onProfileChange} /><AssistantPanelToggle /></div>
          <BrowserSiteControls tabId={tabId} profileId={profileId} url={nav.url} />
          <BrowserPageControls tabId={tabId} title={nav.title} />
          <button type="button" className="browser-nav-button" aria-label={nav.loading ? '중지' : '새로고침'} onClick={() => nav.loading ? guestActions.stop(tabId) : guestActions.reload(tabId)}><Icon name={nav.loading ? 'x' : 'refresh'} /></button>` )
  }
  if (id.endsWith('/features/browser/BrowserToolbarOverflow.tsx')) {
    code = "import { useDownloads } from './downloadsStore'\n" + code
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
  return code === source ? null : { code, map: null }
}
export default function browserPlugin() {
  return { name: 'bandal-ipad-browser', enforce: 'pre', transform(code, id) { return adaptBrowserSource(code, id.replaceAll('\\', '/')) } }
}
