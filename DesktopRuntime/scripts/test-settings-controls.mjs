import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname } from 'node:path'
import { dependencies, runtime } from './dependencies.mjs'
import { adaptPlatformSource } from '../renderer/platform/index.mjs'
import nativeRecordingPlugin from '../renderer/recording/index.mjs'

const { require } = dependencies()
const { build } = createRequire(require.resolve('vite'))('esbuild')
const { webkit, expect } = require('@playwright/test')
const recording = nativeRecordingPlugin()
const built = await build({ stdin: { resolveDir: runtime, loader: 'tsx', contents: `
import React, { useEffect, useState } from 'react'; import {createRoot} from 'react-dom/client';
import {DEFAULT_SETTINGS} from './upstream/src/shared/types/settings';
import {TabsSettingsPanel} from './upstream/src/renderer/src/features/settings/TabsSettingsPanel';
import {PermissionsPanel} from './upstream/src/renderer/src/features/settings/permissions/PermissionsPanel';
import {WebExtensionsCard} from './upstream/src/renderer/src/features/settings/browser/BrowserSettingsPanel';
import {ToastHost} from './upstream/src/renderer/src/app/toast';
import {GeneralPanel,AboutPanel} from './upstream/src/renderer/src/features/settings/SettingsPanels';
import {AdvancedPanel} from './upstream/src/renderer/src/features/settings/advanced/AdvancedPanel';
import {PrivacyPanel} from './upstream/src/renderer/src/features/settings/privacy/PrivacyPanel';
import {DockviewReact} from 'dockview';
import {createMarkdownTab,defaultMarkdownTitle} from './upstream/src/renderer/src/app/tabCommands';
import {useWorkspaceStore} from './upstream/src/renderer/src/stores/workspaceStore';
import {useCoursesStore,flushLastActiveCoursePersist} from './upstream/src/renderer/src/stores/coursesStore';
import {useUniversityStore} from './upstream/src/renderer/src/stores/universityStore';
import {ensureSettingsLoaded} from './upstream/src/renderer/src/stores/settingsSnapshot';
import {descriptorFor} from './upstream/src/renderer/src/features/workspace/tabIdentity';
import BoardPanel from './upstream/src/renderer/src/features/board/BoardPanel';
const dockComponents = {note:({params})=><p>{params.descriptor.payload.relPath}</p>,browser:()=> <p>Browser content boundary</p>};
window.fixture.consumers = {createMarkdownTab,defaultMarkdownTitle,useWorkspaceStore,useCoursesStore,useUniversityStore,ensureSettingsLoaded,flushLastActiveCoursePersist,descriptorFor};
import {CalendarSettingsPanel} from './upstream/src/renderer/src/features/calendar/CalendarSettingsPanel';
import {NotificationsPanel} from './upstream/src/renderer/src/features/settings/notifications/NotificationsPanel';
import {AppearancePanel} from './upstream/src/renderer/src/features/settings/AppearancePanel';
import {WidgetSettingsPanel} from './upstream/src/renderer/src/features/settings/WidgetSettingsPanel';
import {applyTheme} from './upstream/src/renderer/src/features/settings/settingsTheme';
import {invoke} from './upstream/src/renderer/src/lib/ipc';
import {NativeBrowserImportCard} from './renderer/settings/NativeBrowserImportCard';
import {NativePDFDevelopmentSetting} from './renderer/nativePDF/NativePDFDevelopmentSetting';
function App() {
 const [settings, setSettings] = useState(window.fixture.saved ?? DEFAULT_SETTINGS);
 const [section, setSection] = useState('tabs');
 useEffect(() => { window.fixture.update = setSettings; window.fixture.section = setSection }, []);
 useEffect(() => { applyTheme(settings) }, [settings]);
 if (section === 'general') return <GeneralPanel settings={settings}/>;
 if (section === 'advanced') return <><AdvancedPanel settings={settings}/><ToastHost/></>;
 if (section === 'privacy') return <><PrivacyPanel/><ToastHost/></>;
 if (section === 'about') return <AboutPanel/>;
 if (section === 'nativePDFDevelopment') return <NativePDFDevelopmentSetting/>;
 if (section === 'workspace') return <div style={{width:900,height:600}}><DockviewReact components={dockComponents} onReady={event=>{window.fixture.dock=event.api;useWorkspaceStore.getState().attachApi(event.api)}}/></div>;
 if (section === 'board') return <BoardPanel params={{descriptor:descriptorFor('board',{})}}/>;
 if (section === 'calendar') return <><CalendarSettingsPanel/><ToastHost/></>;
 if (section === 'notifications') return <><NotificationsPanel settings={settings}/><ToastHost/></>;
 if (section === 'widgets') return <><WidgetSettingsPanel settings={settings}/><ToastHost/></>;
 if (section === 'appearance') return <AppearancePanel {...settings} saving={false} error={null} onSelect={theme => invoke('settings:set',{theme})} onSelectFontScale={fontScale => invoke('settings:set',{fontScale})} onSelectEditorFont={editorFont => invoke('settings:set',{editorFont})} onSelectDensity={density => invoke('settings:set',{density})}/>;
 return <><button onClick={() => setSettings(window.fixture.saved ?? DEFAULT_SETTINGS)}>reload settings</button><TabsSettingsPanel settings={settings} aiPanel={<p>AI tab</p>} browserPanel={<p>Browser tab</p>} onNavigate={() => {}}/><PermissionsPanel/><WebExtensionsCard profileId="default"/><NativeBrowserImportCard profileId="00000000-0000-4000-8000-000000000007"/><ToastHost/></>;
}
window.fixture.saved ??= structuredClone(DEFAULT_SETTINGS);
createRoot(document.getElementById('root')).render(<App/>);
` }, bundle: true, write: false, format: 'iife', platform: 'browser', jsx: 'automatic', define: { 'process.env.NODE_ENV': '"test"', 'import.meta.env.DEV': 'false' }, loader: { '.css': 'empty' }, plugins: [{ name: 'actual-ipad-settings', setup(b) {
  b.onLoad({ filter: /\.[tj]sx?$/ }, async args => {
    let code = await readFile(args.path, 'utf8')
    code = adaptPlatformSource(code, args.path)?.code ?? code
    code = recording.transform(code, args.path)?.code ?? code
    if (args.path.endsWith('/settings/browser/BrowserSettingsPanel.tsx')) code += '\nexport { WebExtensionsCard }\n'
    return { contents: code, loader: args.path.endsWith('tsx') ? 'tsx' : 'ts', resolveDir: dirname(args.path) }
  })
}}] })
const browser = await webkit.launch()
try {
  const page = await browser.newPage(), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.setContent('<div id="root"></div>')
  await page.evaluate(() => {
    // Force the same custom-scheme condition that used to crash the settings subtab.
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, get() { throw new Error('Web microphone APIs must not be used by native recording settings') } })
    const listeners = new Map()
    window.fixture = { notes:[], courses: [{id:'course1',name:'첫 과목',folderPath:'/fixture/c1',color:'blue',archived:false,sortOrder:0},{id:'course2',name:'복원 과목',folderPath:'/fixture/c2',color:'green',archived:false,sortOrder:1}], calendar: { supported: true, connected: false, authorization: 'denied', calendars: [{id:'read',title:'구독 일정',source:'iCloud',color:'#777777',writable:false},{id:'write',title:'수업',source:'iCloud',color:'#888888',writable:true}], selectedCalendarIds:[],destinationCalendarId:null }, calendarFail:false, notificationDenied:false, calls: [], saved: null, failSave: false, importMode: 'success', permissions: [
      { id: 'microphone', state: 'not-determined', canRequest: true, canOpenSettings: true },
      { id: 'calendar', state: 'denied', canRequest: false, canOpenSettings: true }
    ], devices: [{ deviceId: 'AVAudioSession:built-in', label: 'iPad 마이크', kind: 'audioinput', groupId: 'builtin' }],
      emit(channel, event) { for (const fn of listeners.get(channel) ?? []) fn(event) } }
    const merge = (a, b) => Object.fromEntries([...new Set([...Object.keys(a), ...Object.keys(b)])].map(key => [key, b[key] === undefined ? a[key] : b[key] && typeof b[key] === 'object' && !Array.isArray(b[key]) ? merge(a[key] ?? {}, b[key]) : b[key]]))
    window.bandal = { platform: 'ipad', on(channel, fn) { const set = listeners.get(channel) ?? new Set(); set.add(fn); listeners.set(channel, set); return () => set.delete(fn) }, async invoke(channel, request) {
      window.fixture.calls.push({ channel, request })
      if (channel === 'settings:get') return window.fixture.saved
      if (channel === 'settings:set') {
        if (window.fixture.failSave) throw new Error('Fixture storage full')
        window.fixture.saved = merge(window.fixture.saved, request); window.fixture.update(window.fixture.saved)
        window.fixture.emit('settings:changed', { settings: window.fixture.saved }); return window.fixture.saved
      }
      if (channel === 'settings:pickDataRoot') {
        if (window.fixture.maintenanceError) throw new Error(window.fixture.maintenanceError)
        if (window.fixture.cancelPicker) return null
        const dataRoot = '/private/fixture/Files/Documents/Bandal'
        await window.bandal.invoke('settings:set', { dataRoot }); return { dataRoot }
      }
      if (channel === 'settings:reset') {
        if (window.fixture.maintenanceError) throw new Error(window.fixture.maintenanceError)
        await window.bandal.invoke('settings:set', { theme:'system',fontScale:1 }); return window.fixture.saved
      }
      if (channel === 'app:diagnostics' || channel === 'app:openLogs' || channel === 'app:clearCache') {
        if (window.fixture.maintenanceError) throw new Error(window.fixture.maintenanceError)
        return channel === 'app:diagnostics' ? {path:'/private/fixture/Diagnostics/report.zip',contents:['App version','Redacted settings']} : {ok:true}
      }
      if (channel === 'update:status') return {phase:'unsupported',currentVersion:'0.9.8-fixture'}
      if (channel === 'pdfNative:capabilities') {
        if (window.fixture.nativePDFLoadFailure) throw new Error('Unavailable native host')
        return window.fixture.nativePDFCapabilities ?? {development:true,enabled:false}
      }
      if (channel === 'pdfNative:setEnabled') {
        if (window.fixture.nativePDFSaveFailure) throw new Error('개발 설정을 저장하지 못했습니다.')
        window.fixture.nativePDFCapabilities={development:true,enabled:request.enabled};return {enabled:request.enabled}
      }
      if (channel === 'courses:list') return window.fixture.courses.filter(course => request.includeArchived || !course.archived)
      if (channel === 'courseGroups:list') return []
      if (channel === 'courses:archive') { const item = window.fixture.courses.find(item=>item.id===request.courseId); item.archived=request.archived; return {...item} }
      if (channel === 'layout:get') return {layout:null}
      if (channel === 'layout:save' || channel === 'layout:saveMany') return {ok:true}
      if (channel === 'notes:create') { const ref={courseId:request.courseId,relPath:request.title+'.md'}; window.fixture.notes.push({...request,...ref}); return ref }
      if (channel === 'materials:tree') return []
      if (channel === 'board:listTasks') return ['todo','done'].map(status=>({id:status,courseId:'course1',title:status==='todo'?'미완료 과제':'완료된 과제',notes:'',kind:'task',status,color:'blue',allDay:true,startAt:null,dueAt:null,sortOrder:0}))
      if (channel === 'appleCalendar:state') return structuredClone(window.fixture.calendar)
      if (channel === 'appleCalendar:permissions') return { ok: true }
      if (channel === 'appleCalendar:connect' || channel === 'appleCalendar:disconnect') {
        window.fixture.calendar.connected = channel.endsWith(':connect'); return structuredClone(window.fixture.calendar)
      }
      if (channel === 'appleCalendar:configure') {
        if (window.fixture.calendarFail) throw new Error('Calendar storage full')
        Object.assign(window.fixture.calendar, request); return structuredClone(window.fixture.calendar)
      }
      if (channel === 'notifications:test') {
        if (window.fixture.notificationDenied) throw new Error('설정 앱의 반달 → 알림에서 알림을 허용해 주세요.')
        return {ok:true,reason:null}
      }
      if (channel === 'runtime:recordingDevices') return window.fixture.devices
      if (channel === 'recordings:models') return ['zipformer-ko', 'sensevoice'].map(id => ({ id, name: id, bytes: 1_000_000, description: id, status: 'available', downloadedBytes: 0, error: null, unavailableReason: null }))
      if (channel === 'recordings:downloadModel') return { ok: true }
      if (channel === 'permissions:status') return { platform: 'ios', permissions: window.fixture.permissions, checkedAt: new Date().toISOString() }
      if (channel === 'permissions:request') {
        const row = window.fixture.permissions.find(row => row.id === request.id); row.state = 'granted'; row.canRequest = false; return { ...row }
      }
      if (channel === 'permissions:openSettings') return { ok: true }
      if (channel === 'favorites:list') return []
      if (channel === 'browser:importBookmarkFile' || channel === 'credentials:importCsv') {
        if (window.fixture.importMode === 'failure') throw new Error('읽기 실패 <script>window.importUnsafe=true</script>')
        return { imported: 2, skipped: 1, cancelled: window.fixture.importMode === 'cancel' }
      }
      if (channel === 'browser:extensions') return { extensions: [] }
      throw new Error('Unexpected settings fixture channel: ' + channel)
    } }
  })
  await page.addScriptTag({ content: built.outputFiles[0].text })
  const saved = () => page.evaluate(() => window.fixture.saved)
  for (const label of ['마크다운', '브라우저', 'AI', '녹음', '화이트보드', '학업 보드']) await page.getByRole('tab', { name: label, exact: true }).click()
  await page.getByRole('tab', { name: '녹음', exact: true }).click()
  await expect(page.getByRole('combobox', { name: /기본 마이크/ })).toHaveCount(1)
  await page.getByRole('combobox', { name: /기본 마이크/ }).selectOption('AVAudioSession:built-in')
  assert.equal((await saved()).tabs.recordingDeviceId, 'AVAudioSession:built-in')
  await expect(page.getByRole('radio').nth(0)).toBeChecked()
  await page.getByRole('radio').nth(1).check()
  assert.equal((await saved()).tabs.recordingModel, 'sensevoice')
  await page.getByRole('combobox', { name: /기본 재생 속도/ }).selectOption('1.5')
  assert.equal((await saved()).tabs.recordingPlaybackRate, 1.5)
  await page.getByRole('switch', { name: '실시간 자막 자동 따라가기' }).click()
  assert.equal((await saved()).tabs.recordingFollowTranscript, false)
  await page.getByRole('switch', { name: '설정·자료 패널 열어 두기' }).click()
  assert.equal((await saved()).tabs.recordingSidebarOpen, false)
  await page.getByRole('button', { name: '모델 다운로드', exact: false }).nth(1).click()
  assert.ok((await page.evaluate(() => window.fixture.calls)).some(call => call.channel === 'recordings:downloadModel' && call.request.modelId === 'sensevoice'))
  await page.evaluate(() => { window.fixture.devices.push({ deviceId: 'AVAudioSession:usb', label: 'USB 마이크', kind: 'audioinput', groupId: 'usb' }); window.fixture.emit('runtime:recordingDevicesChanged', {}) })
  await expect(page.getByRole('combobox', { name: /기본 마이크/ }).locator('option[value="AVAudioSession:usb"]')).toHaveCount(1)
  await page.getByRole('button', { name: 'reload settings' }).click()
  await expect(page.getByRole('combobox', { name: /기본 재생 속도/ })).toHaveValue('1.5')
  await page.getByRole('tab', { name: '마크다운', exact: true }).click()
  await page.getByLabel('새 파일 제목 접두어', { exact: true }).fill('물리 수업')
  await page.getByRole('button', { name: '저장', exact: true }).click()
  assert.equal((await saved()).tabs.markdownTitlePrefix, '물리 수업')
  await page.getByRole('combobox', { name: /본문 글꼴/ }).selectOption('serif')
  assert.equal((await saved()).editorFont, 'serif')
  await page.getByRole('tab', { name: '화이트보드', exact: true }).click()
  await page.getByRole('combobox', { name: /기본 배경/ }).selectOption('dots')
  assert.equal((await saved()).tabs.whiteboardBackground, 'dots')
  await page.getByRole('tab', { name: '학업 보드', exact: true }).click()
  await page.getByRole('combobox', { name: /시작 화면/ }).selectOption('board')
  await page.getByRole('switch', { name: '완료한 항목 숨기기' }).click()
  assert.equal((await saved()).tabs.boardDefaultView, 'board'); assert.equal((await saved()).tabs.boardHideDone, true)
  await page.getByRole('switch', { name: '현재 탭 바로 옆에 열기' }).click()
  await page.getByRole('switch', { name: '마지막 과목 복원' }).click()
  assert.equal((await saved()).openAdjacentTab, true); assert.equal((await saved()).restoreLastCourse, false)
  await page.evaluate(() => { window.fixture.failSave = true })
  await page.getByRole('switch', { name: '완료한 항목 숨기기' }).click()
  await expect(page.getByText('설정을 저장하지 못했습니다. 다시 시도해 주세요.')).toBeVisible()
  assert.equal((await saved()).tabs.boardHideDone, true, 'A failed write must not silently claim the change persisted')
  const microphone = page.locator('.settings-permissions-row').filter({ has: page.getByText('마이크', { exact: true }) })
  const calendar = page.locator('.settings-permissions-row').filter({ has: page.getByText('캘린더', { exact: true }) })
  await microphone.getByRole('button').click()
  await expect(microphone.locator('.status-pill')).toContainText('허용')
  await calendar.getByRole('button').click()
  assert.ok((await page.evaluate(() => window.fixture.calls)).some(call => call.channel === 'permissions:openSettings' && call.request.id === 'calendar'))
  await page.evaluate(() => { window.fixture.permissions[1].state = 'granted'; document.dispatchEvent(new Event('visibilitychange')) })
  await expect(calendar.locator('.status-pill')).toContainText('허용')
  await expect(page.getByText('Chromium 확장은 iPad의 WebKit 브라우저에서 실행할 수 없습니다.')).toBeVisible()
  await expect(page.locator('.settings-browser__extension-add')).toBeDisabled()
  assert.equal((await page.evaluate(() => window.fixture.calls)).filter(call => call.channel === 'browser:installExtension').length, 0)
  await page.getByRole('button', { name: 'HTML 북마크 가져오기', exact: true }).click()
  await expect(page.getByRole('status').filter({ hasText: '2개 가져옴 · 1개 건너뜀' })).toBeVisible()
  assert.ok((await page.evaluate(() => window.fixture.calls)).some(call => call.channel === 'browser:importBookmarkFile' && call.request.profileId === '00000000-0000-4000-8000-000000000007'))
  assert.ok((await page.evaluate(() => window.fixture.calls)).some(call => call.channel === 'favorites:list' && call.request.courseId === null))
  await page.evaluate(() => { window.fixture.importMode = 'cancel' })
  await page.getByRole('button', { name: 'CSV 로그인 가져오기', exact: true }).click()
  await expect(page.getByRole('status').filter({ hasText: '가져옴' })).toHaveCount(0)
  assert.ok((await page.evaluate(() => window.fixture.calls)).some(call => call.channel === 'credentials:importCsv' && call.request.profileId === '00000000-0000-4000-8000-000000000007'))
  await page.evaluate(() => { window.fixture.importMode = 'failure' })
  await page.getByRole('button', { name: 'HTML 북마크 가져오기', exact: true }).click()
  await expect(page.getByRole('alert').filter({ hasText: '읽기 실패 <script>' })).toBeVisible()
  assert.equal(await page.evaluate(() => window.importUnsafe), undefined)
  await page.evaluate(() => { window.fixture.failSave = false; window.fixture.section('calendar') })
  await expect(page.getByText('설정 앱의 반달 → 캘린더에서 전체 접근을 허용해 주세요.')).toBeVisible()
  await expect(page.locator('body')).not.toContainText('macOS')
  await page.getByRole('button', { name: '시스템 설정 열기' }).click()
  assert.ok((await page.evaluate(() => window.fixture.calls)).some(call => call.channel === 'appleCalendar:permissions'))
  await page.evaluate(() => { window.fixture.calendar.authorization = 'authorized'; document.dispatchEvent(new Event('visibilitychange')) })
  await expect(page.getByText('설정 앱의 반달 → 캘린더에서 전체 접근을 허용해 주세요.')).toHaveCount(0)
  await page.getByRole('button', {name:'Apple 캘린더 연결',exact:true}).click()
  await page.getByRole('checkbox', {name:/구독 일정/}).check()
  assert.deepEqual(await page.evaluate(() => window.fixture.calendar.selectedCalendarIds), ['read'])
  const destination = page.getByRole('combobox', {name:/저장할 캘린더/})
  await expect(destination.locator('option[value="read"]')).toHaveCount(0)
  await destination.selectOption('write')
  assert.equal(await page.evaluate(() => window.fixture.calendar.destinationCalendarId), 'write')
  await page.evaluate(() => { window.fixture.calendarFail = true })
  await page.getByRole('checkbox', {name:/구독 일정/}).click()
  await expect(page.getByRole('alert')).toContainText('Calendar storage full')
  await expect(page.getByRole('checkbox', {name:/구독 일정/})).toBeChecked()
  await page.getByRole('button',{name:'연결 해제',exact:true}).click()
  await expect(page.getByRole('checkbox')).toHaveCount(0)
  assert.deepEqual(await page.evaluate(() => window.fixture.calendar.selectedCalendarIds), ['read'])
  await page.evaluate(() => window.fixture.section('notifications'))
  const notificationSwitches = [['마감','deadlines'], ['AI 응답 완료','agentComplete'], ['다운로드 완료','downloads'], ['플러그인 알림','pluginNotices'], ['소리','sound'], ['포커스 중 억제','suppressWhileFocused']]
  await page.getByRole('button',{name:'7일 전',exact:true}).click()
  assert.equal((await saved()).notifications.deadlineLeadDays.includes(7), true)
  for (const [label,key] of notificationSwitches) {
    const previous = (await saved()).notifications[key]
    await page.getByRole('switch',{name:label,exact:true}).click()
    assert.equal((await saved()).notifications[key], !previous, key)
  }
  await page.getByRole('switch',{name:'알림 켜기',exact:true}).click()
  await expect(page.getByRole('switch',{name:'마감',exact:true})).toBeDisabled()
  await expect(page.getByRole('switch',{name:'소리',exact:true})).toBeEnabled()
  await page.getByRole('button',{name:'테스트 알림 보내기',exact:true}).click()
  await expect(page.getByText('테스트 알림을 보냈어요',{exact:true})).toBeVisible()
  await page.evaluate(() => { window.fixture.notificationDenied = true })
  await page.getByRole('button',{name:'테스트 알림 보내기',exact:true}).click()
  await expect(page.getByText('설정 앱의 반달 → 알림에서 알림을 허용해 주세요.')).toBeVisible()
  await page.evaluate(() => window.fixture.section('appearance'))
  for (const [label,value] of [['라이트','light'],['다크','dark']]) {
    await page.getByRole('radiogroup',{name:'테마 선택'}).getByRole('radio',{name:new RegExp('^'+label)}).click()
    assert.equal((await saved()).theme,value)
    assert.equal(await page.locator('html').getAttribute('data-theme'), value)
  }
  const scale = page.getByRole('radiogroup',{name:'글자 크기 선택'})
  await scale.getByRole('radio').last().click()
  assert.equal(await page.locator('html').evaluate(el => el.style.getPropertyValue('--font-scale')), String((await saved()).fontScale))
  await scale.getByRole('radio').last().press('Home')
  assert.equal((await saved()).fontScale,.9)
  for (const [group,value,attr] of [['필기 글꼴 선택','mono','data-editor-font'],['밀도 선택','compact','data-density']]) {
    await page.getByRole('radiogroup',{name:group}).getByRole('radio').last().click()
    assert.equal(await page.locator('html').getAttribute(attr),value)
  }
  await page.getByRole('radiogroup',{name:'테마 선택'}).getByRole('radio',{name:/^시스템/}).click()
  await page.emulateMedia({colorScheme:'dark'})
  await page.evaluate(() => window.fixture.update({...window.fixture.saved}))
  await expect(page.locator('html')).toHaveAttribute('data-theme','dark')
  await page.evaluate(() => window.fixture.section('widgets'))
  for (const label of ['투두','학업 보드','메일함']) await page.getByRole('switch',{name:label,exact:true}).click()
  assert.deepEqual((await saved()).widgets.enabled,['todo','board','mail'])
  await page.locator('.widget-setting-row').filter({has:page.getByRole('switch',{name:'메일함',exact:true})}).getByRole('button',{name:'↑',exact:true}).click()
  assert.deepEqual((await saved()).widgets.enabled,['todo','mail','board'])
  await page.getByRole('switch',{name:'투두',exact:true}).click()
  assert.equal((await saved()).widgets.active,'mail')
  for (const label of ['메일함','학업 보드']) await page.getByRole('switch',{name:label,exact:true}).click()
  assert.deepEqual((await saved()).widgets.enabled,[])
  const url = page.getByPlaceholder('https://mail.example.edu')
  await url.fill('https://mail.example.test'); await url.blur()
  assert.equal((await saved()).widgets.mailUrl,'https://mail.example.test')
  await page.evaluate(async () => {
    const {useUniversityStore} = window.fixture.consumers
    await useUniversityStore.getState().selectPreset('snu')
  })
  const schoolMail = page.getByRole('combobox',{name:/학교 메일/})
  await expect(schoolMail.locator('option[value="snu.mail"]')).toHaveCount(1)
  await schoolMail.selectOption('snu.mail')
  assert.equal((await saved()).widgets.mailServiceId,'snu.mail')
  await page.evaluate(async () => window.fixture.consumers.useUniversityStore.getState().setServiceHidden('snu.mail',true))
  await expect(schoolMail.locator('option[value="snu.mail"]')).toHaveCount(0)
  await page.evaluate(async () => window.fixture.consumers.useUniversityStore.getState().setServiceHidden('snu.mail',false))
  await expect(schoolMail.locator('option[value="snu.mail"]')).toHaveCount(1)
  await page.evaluate(async () => {
    const {useCoursesStore,ensureSettingsLoaded} = window.fixture.consumers
    await ensureSettingsLoaded()
    await window.bandal.invoke('settings:set',{restoreLastCourse:true,lastActiveCourseId:'course2'})
    await useCoursesStore.getState().loadCourses()
  })
  assert.equal(await page.evaluate(()=>window.fixture.consumers.useCoursesStore.getState().selectedCourseId),'course2')
  await page.evaluate(async () => {
    const {useCoursesStore} = window.fixture.consumers
    await window.bandal.invoke('settings:set',{restoreLastCourse:false,lastActiveCourseId:'course2'})
    useCoursesStore.setState({selectedCourseId:null}); await useCoursesStore.getState().loadCourses()
  })
  assert.equal(await page.evaluate(()=>window.fixture.consumers.useCoursesStore.getState().selectedCourseId),'course1')
  await page.evaluate(async () => {
    const {useCoursesStore,flushLastActiveCoursePersist} = window.fixture.consumers
    useCoursesStore.getState().selectCourse('course2'); flushLastActiveCoursePersist()
  })
  await expect.poll(async ()=>(await saved()).lastActiveCourseId).toBe('course2')
  await page.evaluate(async () => {
    const {useCoursesStore} = window.fixture.consumers
    await useCoursesStore.getState().archiveCourse('course2',true)
  })
  assert.equal(await page.evaluate(()=>window.fixture.consumers.useCoursesStore.getState().selectedCourseId),'course1')
  await page.evaluate(async () => window.fixture.consumers.useCoursesStore.getState().archiveCourse('course2',false))
  assert.deepEqual(await page.evaluate(()=>window.fixture.consumers.useCoursesStore.getState().courses.map(course=>course.id)),['course1','course2'])
  await page.evaluate(()=>window.fixture.section('workspace'))
  await expect.poll(()=>page.evaluate(()=>window.fixture.consumers.useWorkspaceStore.getState().hydration)).toBe('ready')
  await page.evaluate(async () => {
    const c=window.fixture.consumers
    await c.createMarkdownTab()
  })
  assert.match((await page.evaluate(()=>window.fixture.notes))[0].title,/^물리 수업 \d{4}-\d{2}-\d{2}/)
  const insertion = await page.evaluate(async () => {
    const {useWorkspaceStore,descriptorFor}=window.fixture.consumers, store=useWorkspaceStore.getState(),dock=window.fixture.dock
    await window.bandal.invoke('settings:set',{openAdjacentTab:false})
    store.openTab(descriptorFor('note',{courseId:'course1',relPath:'second.md'}))
    store.openTab(descriptorFor('note',{courseId:'course1',relPath:'third.md'}))
    const first=dock.panels[0];first.api.setActive()
    await window.bandal.invoke('settings:set',{openAdjacentTab:true})
    store.openTab(descriptorFor('note',{courseId:'course1',relPath:'adjacent.md'}))
    const adjacent=first.group.panels.map(panel=>panel.params.descriptor.payload.relPath)
    await window.bandal.invoke('settings:set',{openAdjacentTab:false});first.api.setActive()
    store.openTab(descriptorFor('note',{courseId:'course1',relPath:'append.md'}))
    return {adjacent,appended:first.group.panels.map(panel=>panel.params.descriptor.payload.relPath)}
  })
  assert.equal(insertion.adjacent[1],'adjacent.md');assert.equal(insertion.adjacent[2],'second.md')
  assert.equal(insertion.appended.at(-1),'append.md')
  await page.evaluate(()=>{window.fixture.consumers.useWorkspaceStore.getState().detachApi();window.fixture.section('board')})
  await expect(page.getByRole('button',{name:'목록',exact:true})).toHaveAttribute('aria-pressed','true')
  await expect(page.getByRole('checkbox',{name:'완료 숨기기'})).toBeChecked()
  await expect(page.getByRole('button',{name:'미완료 과제 상세 편집'})).toHaveCount(1)
  await expect(page.getByRole('button',{name:'완료된 과제 상세 편집'})).toHaveCount(0)
  await page.getByRole('checkbox',{name:'완료 숨기기'}).uncheck()
  await expect(page.getByRole('button',{name:'완료된 과제 상세 편집'})).toHaveCount(1)
  await page.evaluate(async()=>{await window.bandal.invoke('settings:set',{onboarding:{closedAt:'2026-10-01T00:00:00Z',lastCompletedStep:1},tutorial:{seenVersion:99}});window.fixture.section('general')})
  await page.getByRole('combobox',{name:'언어 선택'}).selectOption('en-US')
  assert.equal((await saved()).locale,'en-US')
  await expect(page.getByRole('button',{name:'Replay tutorial',exact:true})).toBeVisible()
  await page.getByRole('combobox').selectOption('ko-KR')
  assert.equal((await saved()).locale,'ko-KR')
  await page.evaluate(()=>{window.fixture.failSave=true})
  await page.getByRole('combobox').selectOption('en-US')
  await expect(page.getByRole('combobox')).toHaveValue('ko-KR')
  assert.equal((await saved()).locale,'ko-KR')
  await page.evaluate(()=>{window.fixture.failSave=false})
  const originalTutorial=(await saved()).tutorial
  await page.getByRole('button',{name:'튜토리얼 다시 보기',exact:true}).click()
  assert.deepEqual((await saved()).tutorial,{...originalTutorial,seenVersion:0})
  await page.getByRole('button',{name:'시작 안내 다시 보기',exact:true}).click()
  assert.equal((await saved()).onboarding.closedAt,null)
  assert.equal((await saved()).onboarding.lastCompletedStep,0)
  // Actual advanced controls: cancel leaves the path untouched; a selected
  // iPad folder is never abbreviated to a non-existent macOS home directory.
  await page.evaluate(async()=>{await window.bandal.invoke('settings:set',{dataRoot:''});window.fixture.section('advanced')})
  const folderPath = page.getByRole('textbox')
  await expect(folderPath).toHaveValue('—')
  await page.evaluate(()=>{window.fixture.cancelPicker=true})
  await page.getByRole('button',{name:'위치 변경',exact:true}).click()
  await expect(folderPath).toHaveValue('—')
  await page.evaluate(()=>{window.fixture.cancelPicker=false})
  await page.getByRole('button',{name:'위치 변경',exact:true}).click()
  await expect(folderPath).toHaveValue('/private/fixture/Files/Documents/Bandal')
  assert.equal((await saved()).dataRoot,'/private/fixture/Files/Documents/Bandal')
  await page.evaluate(()=>{window.fixture.maintenanceError='파일 제공자 연결이 끊겼습니다.'})
  await page.getByRole('button',{name:'위치 변경',exact:true}).click()
  await expect(page.getByRole('alert')).toContainText('파일 제공자 연결이 끊겼습니다.')
  await expect(folderPath).toHaveValue('/private/fixture/Files/Documents/Bandal')
  await page.evaluate(()=>{window.fixture.maintenanceError=null})
  await page.getByRole('button',{name:'로그 보기',exact:true}).click()
  assert.ok((await page.evaluate(()=>window.fixture.calls)).some(call=>call.channel==='app:openLogs'))
  await page.getByRole('button',{name:'캐시 비우기',exact:true}).click()
  assert.ok((await page.evaluate(()=>window.fixture.calls)).some(call=>call.channel==='app:clearCache'))
  const resetCount=()=>page.evaluate(()=>window.fixture.calls.filter(call=>call.channel==='settings:reset').length)
  await page.getByRole('button',{name:'초기화',exact:true}).click()
  assert.equal(await resetCount(),0)
  await page.getByRole('button',{name:'취소',exact:true}).click()
  assert.equal(await resetCount(),0)
  await page.getByRole('button',{name:'초기화',exact:true}).click()
  await page.evaluate(()=>{window.fixture.maintenanceError='Storage full'})
  await page.getByRole('button',{name:'초기화',exact:true}).click()
  await expect(page.getByRole('button',{name:'취소',exact:true})).toBeVisible()
  assert.equal(await resetCount(),1)
  await page.evaluate(()=>{window.fixture.maintenanceError=null})
  await page.getByRole('button',{name:'초기화',exact:true}).click()
  await expect(page.getByRole('button',{name:'취소',exact:true})).toHaveCount(0)
  assert.equal(await resetCount(),2)
  // Diagnostics surface native presentation errors and retain a prior bundle
  // when a later attempt fails, instead of claiming another file was opened.
  await page.evaluate(()=>{window.fixture.section('privacy')})
  await expect(page.getByText('자료는 기기에 먼저 저장됩니다.',{exact:true})).toBeVisible()
  await expect(page.getByText(/계정 동기화 서버와 주고받습니다/)).toBeVisible()
  await page.getByRole('button',{name:'진단 파일 만들기',exact:true}).click()
  await expect(page.getByText('미리보기에서 열림',{exact:true})).toBeVisible()
  await expect(page.getByRole('textbox')).toHaveValue('/private/fixture/Diagnostics/report.zip')
  await page.evaluate(()=>{window.fixture.maintenanceError='열린 창을 닫은 뒤 다시 시도해 주세요.'})
  await page.getByRole('button',{name:'진단 파일 만들기',exact:true}).click()
  await expect(page.getByText('열린 창을 닫은 뒤 다시 시도해 주세요.',{exact:true})).toBeVisible()
  await expect(page.getByRole('textbox')).toHaveValue('/private/fixture/Diagnostics/report.zip')
  await page.evaluate(()=>{window.fixture.maintenanceError=null;window.fixture.section('about')})
  await expect(page.getByText('버전 0.9.8-fixture',{exact:true})).toBeVisible()
  await expect(page.getByText(/App Store 또는 TestFlight로 설치한 앱/)).toBeVisible()
  assert.equal((await page.evaluate(()=>window.fixture.calls)).filter(call=>['update:check','update:download','update:install'].includes(call.channel)).length,0)
  await page.evaluate(async()=>{await window.bandal.invoke('settings:set',{locale:'en-US'})})
  await expect(page.getByText(/Apps installed from the App Store or TestFlight/)).toBeVisible()
  await page.evaluate(async()=>{await window.bandal.invoke('settings:set',{locale:'ko-KR'});window.fixture.section('nativePDFDevelopment')})
  const nativeToggle=page.getByRole('switch',{name:'네이티브 PDF와 Pencil 입력',exact:true})
  await expect(nativeToggle).toHaveAttribute('aria-checked','false')
  await expect(page.getByText(/변경 후 열려 있는 PDF를 닫고 다시 열어 주세요/)).toBeVisible()
  await nativeToggle.click();await expect(nativeToggle).toHaveAttribute('aria-checked','true')
  await expect(page.getByRole('status')).toHaveText('저장했습니다. PDF를 닫고 다시 열면 적용됩니다.')
  const nativeCalls=await page.evaluate(()=>window.fixture.calls.filter(call=>call.channel.startsWith('pdfNative:')))
  assert.deepEqual(nativeCalls.map(call=>call.channel),['pdfNative:capabilities','pdfNative:setEnabled'])
  assert.deepEqual(nativeCalls[1].request,{enabled:true})
  await page.evaluate(()=>{window.fixture.nativePDFSaveFailure=true})
  await nativeToggle.click();await expect(nativeToggle).toHaveAttribute('aria-checked','true')
  await expect(page.getByRole('alert')).toHaveText('개발 설정을 저장하지 못했습니다.')
  await page.evaluate(()=>{window.fixture.nativePDFSaveFailure=false})
  await nativeToggle.click();await expect(nativeToggle).toHaveAttribute('aria-checked','false')
  // Remount probes host persistence; Release and unavailable host both hide
  // this control instead of pretending a renderer build flag is permission.
  await page.evaluate(()=>window.fixture.section('about'))
  await expect(page.getByText('버전 0.9.8-fixture',{exact:true})).toBeVisible()
  await page.evaluate(()=>window.fixture.section('nativePDFDevelopment'))
  await expect(nativeToggle).toHaveAttribute('aria-checked','false')
  await page.evaluate(()=>{window.fixture.section('about');window.fixture.nativePDFCapabilities={development:false,enabled:false}})
  await expect(page.getByText('버전 0.9.8-fixture',{exact:true})).toBeVisible()
  const releaseLoadCount=await page.evaluate(()=>window.fixture.calls.filter(call=>call.channel==='pdfNative:capabilities').length)
  await page.evaluate(()=>window.fixture.section('nativePDFDevelopment'))
  await expect.poll(()=>page.evaluate(()=>window.fixture.calls.filter(call=>call.channel==='pdfNative:capabilities').length)).toBe(releaseLoadCount+1)
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(resolve)))
  await expect(nativeToggle).toHaveCount(0)
  await page.evaluate(()=>{window.fixture.section('about');window.fixture.nativePDFLoadFailure=true})
  await expect(page.getByText('버전 0.9.8-fixture',{exact:true})).toBeVisible()
  const failureLoadCount=await page.evaluate(()=>window.fixture.calls.filter(call=>call.channel==='pdfNative:capabilities').length)
  await page.evaluate(()=>window.fixture.section('nativePDFDevelopment'))
  await expect.poll(()=>page.evaluate(()=>window.fixture.calls.filter(call=>call.channel==='pdfNative:capabilities').length)).toBe(failureLoadCount+1)
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(resolve)))
  await expect(nativeToggle).toHaveCount(0)
  assert.deepEqual(errors, [])
  console.log('Actual adapted settings: all 6 subtabs, native microphone IDs/change events, model/default controls, failed persistence, permission recovery, calendar selection/failure/recovery, appearance DOM effects, notification toggles, widget order, profile imports, real Dockview insertion, restored/archived courses, school mail linkage, board filtering, language, advanced cancellation/reset recovery, diagnostics, iPad update information and DEBUG-only native PDF load/save/failure/reopen/Release hiding passed in WebKit')
} finally { await browser.close() }
