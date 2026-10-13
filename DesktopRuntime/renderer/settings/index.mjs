/** iPad-only settings contracts. The desktop snapshot remains byte-preserved. */
import { fileURLToPath } from 'node:url'
const browserImport = fileURLToPath(new URL('./NativeBrowserImportCard.tsx', import.meta.url))
function replace(source, needle, value, count = 1) {
  if (source.split(needle).length - 1 !== count) throw new Error(`Native settings adapter anchor changed: ${needle}`)
  return source.split(needle).join(value)
}

export function adaptSettingsSource(source, id) {
  let code = source
  if (id.endsWith('/shared/types/permissions.ts')) {
    code = replace(code, "  'notifications',", "  'notifications',\n  'microphone',\n  'calendar',")
  }
  if (id.endsWith('/settings/permissions/PermissionsPanel.tsx')) {
    code = replace(code, "  } else if (id === 'notifications') {", `  } else if (id === 'microphone') {
    content = <><rect x="9" y="2" width="6" height="12" rx="3" /><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8" /></>
  } else if (id === 'calendar') {
    content = <><rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 11h18" /></>
  } else if (id === 'notifications') {`)
    code = replace(code, "    window.addEventListener('focus', refresh)\n    return () => window.removeEventListener('focus', refresh)", `    const visible = (): void => { if (document.visibilityState === 'visible') refresh() }
    window.addEventListener('focus', refresh)
    document.addEventListener('visibilitychange', visible)
    return () => {
      window.removeEventListener('focus', refresh)
      document.removeEventListener('visibilitychange', visible)
    }`)
  }
  if (id.endsWith('/calendar/CalendarSettingsPanel.tsx')) {
    for (const [before, after] of [
      ['Mac의 캘린더 앱에 연결된 iCloud·로컬 캘린더를 반달에서 함께 봅니다.', 'iPad의 캘린더 앱에 연결된 iCloud·로컬 캘린더를 반달에서 함께 봅니다.'],
      ['Bring the iCloud and local calendars in your Mac Calendar app into Bandal.', 'Bring the iCloud and local calendars on your iPad into Bandal.'],
      ['Apple 캘린더 연결은 macOS 앱에서 사용할 수 있어요.', '이 기기에서 Apple 캘린더 연결을 사용할 수 없습니다.'],
      ['Apple Calendar is available in the macOS app.', 'Apple Calendar is unavailable on this device.'],
      ['연결할 때 macOS에서 캘린더 전체 접근 권한을 요청합니다. 일정은 이 Mac에서만 읽습니다.', '연결할 때 iPadOS에서 캘린더 전체 접근 권한을 요청합니다. 일정은 이 iPad에서만 읽습니다.'],
      ['macOS will ask for full calendar access when you connect. Events are read on this Mac only.', 'iPadOS will ask for full calendar access when you connect. Events are read on this iPad only.'],
      ['시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서 반달의 전체 접근을 허용해주세요.', '설정 앱의 반달 → 캘린더에서 전체 접근을 허용해 주세요.'],
      ['Allow full access for Bandal in System Settings → Privacy & Security → Calendars.', 'Allow full calendar access for Bandal in the Settings app.'],
      ['시스템 권한은 macOS 설정에서 관리합니다.', '시스템 권한은 iPad의 설정 앱에서 관리합니다.'],
      ['Manage system permissions in macOS Settings.', 'Manage system permissions in the iPad Settings app.'],
      ['Mac의 캘린더 앱에서 먼저 계정이나 캘린더를 추가해주세요.', 'iPad의 캘린더 앱에서 먼저 계정이나 캘린더를 추가해 주세요.'],
      ['Add an account or calendar in the Mac Calendar app first.', 'Add an account or calendar in the iPad Calendar app first.']
    ]) code = replace(code, before, after)
    code = replace(code, "    window.addEventListener('focus', focus)", `    const visible = () => { if (document.visibilityState === 'visible') focus() }
    document.addEventListener('visibilitychange', visible)
    window.addEventListener('focus', focus)`)
    code = replace(code, "off(); window.removeEventListener('focus', focus)", "off(); window.removeEventListener('focus', focus); document.removeEventListener('visibilitychange', visible)")
  }
  if (id.endsWith('/notifications/NotificationsPanel.tsx')) {
    code = replace(code, ".catch(() => showToast(t('settings.notifications.test.failed'), 'danger'))", ".catch((error: unknown) => showToast(error instanceof Error ? error.message : t('settings.notifications.test.failed'), 'danger'))")
  }
  if (id.endsWith('/settings/advanced/AdvancedPanel.tsx')) {
    const start = code.indexOf('function displayDataRoot('), end = code.indexOf('\nfunction rejectedMessage(', start)
    if (start < 0 || end < 0) throw new Error('Native storage display boundary changed')
    // A macOS home-folder abbreviation is not an iPad sandbox location. Keep
    // the real picker path visible, even if its suffix happens to match Mac.
    code = code.slice(0, start) + "function displayDataRoot(path: string | undefined): string { return path || '—' }\n" + code.slice(end)
  }
  if (id.endsWith('/settings/privacy/PrivacyPanel.tsx')) {
    code = replace(code, ".catch(() => showToast(t('settings.privacy.diagnostics.failed'), 'danger'))", ".catch((error: unknown) => showToast(error instanceof Error ? error.message : t('settings.privacy.diagnostics.failed'), 'danger'))")
  }
  if (id.endsWith('/settings/SettingsPanels.tsx')) {
    code = replace(code, "  if (status === null || status.phase === 'unsupported') return null", `  if (status === null) return null
  if (status.phase === 'unsupported') return <SettingsCard title={t('settings.update.title')} description={t('settings.update.ipadDistribution')}>{null}</SettingsCard>`)
  }
  if (id.endsWith('/settings/browser/BrowserSettingsPanel.tsx')) {
    const start = code.indexOf('function BrowserImportCard('), end = code.indexOf('\nfunction WebExtensionsCard(', start)
    if (start < 0 || end < 0) throw new Error('Native browser import card boundary changed')
    code = `import { NativeBrowserImportCard } from ${JSON.stringify(browserImport)}\n` + code.slice(0, start) + 'function BrowserImportCard({ profileId }: { profileId: string }): JSX.Element { return <NativeBrowserImportCard key={profileId} profileId={profileId} /> }\n' + code.slice(end)
    code = replace(code, 'disabled={busy !== null}\n        onClick={install}', 'disabled\n        onClick={install}')
    code = replace(code, "description={t('settings.browser.extensions.description')}", "description={t('settings.browser.extensions.ipadDescription')}")
    code = replace(code, "{t('settings.browser.extensions.empty')}", "{t('settings.browser.extensions.ipadEmpty')}")
  }
  if (id.endsWith('/i18n/messages/ko-KR.ts') || id.endsWith('/i18n/messages/en-US.ts')) {
    const ko = id.endsWith('/ko-KR.ts')
    const rows = {
      'settings.permissions.microphone.label': ko ? '마이크' : 'Microphone',
      'settings.permissions.microphone.description': ko ? '강의를 녹음하고 기기 안에서 자막을 만듭니다.' : 'Record lectures and transcribe them on this iPad.',
      'settings.permissions.calendar.label': ko ? '캘린더' : 'Calendar',
      'settings.permissions.calendar.description': ko ? '선택한 캘린더의 일정을 읽고 과제를 추가합니다. 읽기와 쓰기를 모두 허용해 주세요.' : 'Read selected calendars and add assignments. Full calendar access is required.',
      'settings.browser.extensions.ipadDescription': ko ? 'Chromium 확장은 iPad의 WebKit 브라우저에서 실행할 수 없습니다.' : 'Chromium extensions cannot run in the iPad WebKit browser.',
      'settings.browser.extensions.ipadEmpty': ko ? '데스크톱 반달에서 설치한 확장은 데스크톱에서 계속 사용할 수 있습니다.' : 'Extensions installed in Bandal on your desktop remain available there.',
      'settings.update.ipadDistribution': ko ? 'App Store 또는 TestFlight로 설치한 앱은 해당 앱에서 업데이트합니다. 개발용으로 직접 설치한 앱은 새 빌드를 설치해 주세요.' : 'Apps installed from the App Store or TestFlight are updated there. For a development installation, install a new build.'
    }
    const anchor = "  'settings.permissions.inheritance':"
    code = replace(code, anchor, Object.entries(rows).map(([key, value]) => `  '${key}': ${JSON.stringify(value)},`).join('\n') + '\n' + anchor)
    code = code.replace(/('settings.permissions.inheritance': )'[^\n]*'/, (_all, prefix) => prefix + JSON.stringify(ko ? '권한은 이 iPad에서 관리합니다. 설정 앱에서 변경한 뒤 돌아오면 상태를 다시 확인합니다.' : 'Permissions are managed on this iPad. Status refreshes when you return from Settings.'))
    const replacements = {
      'settings.advanced.logs.open': ko ? '로그 보기' : 'View logs',
      'settings.advanced.logs.openFailed': ko ? '로그 파일을 열지 못했어요.' : 'Could not open the log file.',
      'settings.privacy.diagnostics.revealed': ko ? '미리보기에서 열림' : 'Opened in preview',
      'settings.privacy.data.promise': ko ? '자료는 기기에 먼저 저장됩니다.' : 'Materials are saved on this device first.',
      'settings.privacy.data.description': ko ? '계정을 연결하면 자료·필기·학습 기록을 계정 동기화 서버와 주고받습니다. AI를 사용할 때 선택한 자료와 대화는 해당 AI 제공자에게 전송됩니다. API 키와 브라우저 쿠키는 일반 동기화에 포함하지 않습니다.' : 'When an account is connected, materials, drawings and study records are exchanged with account sync servers. Using AI sends the selected material and conversation to that provider. API keys and browser cookies are excluded from general sync.'
    }
    for (const [key, value] of Object.entries(replacements)) {
      const expression = new RegExp(`('${key.replaceAll('.', '\\.')}': )'[^\\n]*'`)
      if (!expression.test(code)) throw new Error(`Native settings translation anchor changed: ${key}`)
      code = code.replace(expression, (_all, prefix) => prefix + JSON.stringify(value))
    }
  }
  return code === source ? null : { code, map: null }
}
