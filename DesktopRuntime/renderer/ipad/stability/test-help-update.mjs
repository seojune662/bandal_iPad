import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import { adaptPlatformSource } from '../../platform/index.mjs'
import { adaptLayoutSource } from '../layout/index.mjs'
import { adaptInputSource } from '../input/index.mjs'
import { adaptStabilitySource } from './index.mjs'

const { require } = dependencies(), ts = require('typescript'), { JSDOM } = require('jsdom')
const { build } = createRequire(require.resolve('vite'))('esbuild')
const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'https://bandal.test', runScripts: 'outside-only', pretendToBeVisual: true })
const { window } = dom, { document } = window
window.bandal = { platform: 'ipad' }
const bundle = await build({ stdin: { contents: `
export * as React from 'react'
export * as JSX from 'react/jsx-runtime'
export { create } from 'zustand'
export { createRoot } from 'react-dom/client'
export { flushSync } from 'react-dom'
`, resolveDir: runtime }, bundle: true, write: false, platform: 'browser', format: 'iife', globalName: 'Fixture', define: { 'process.env.NODE_ENV': '"production"' } })
window.eval(bundle.outputFiles[0].text)
const api = window.Fixture, calls = [], subscriptions = new Map()
let locale = 'ko-KR', messages
const t = key => messages[key] ?? key
const ipc = {
  invoke: async channel => { calls.push(channel); if (channel === 'update:status') return { phase: 'unsupported', currentVersion: 'fixture' }; throw Error('Unexpected IPC: ' + channel) },
  onPush: (channel, callback) => { subscriptions.set(channel, callback); return () => subscriptions.delete(channel) }
}
const emptyComponent = () => null
const modules = new Map([
  ['react', api.React], ['react/jsx-runtime', api.JSX], ['zustand', { create: api.create }],
  ['../lib/ipc', ipc], ['../../lib/ipc', ipc],
  ['../../../shared/appearance', { pickAppearance: () => ({}) }],
  ['../../../shared/types/settings', { DEFAULT_SETTINGS: { theme: 'light' } }],
  ['../features/settings/settingsTheme', { applyTheme: () => 'light', resolveRendererTheme: () => 'light' }],
  ['./settingsSnapshot', { ensureSettingsLoaded: () => { throw Error('Theme loading is outside this fixture') } }],
  ['../features/updates/prepareUpdateInstall', { prepareUpdateInstall: () => { throw Error('Help must never prepare an install') } }],
  ['../../lib/useViewportBounds', { useViewportBounds() {} }],
  ['../../i18n', { useT: () => t, useLocale: () => locale }],
  ['../../components/Tooltip', { Tooltip: ({ children }) => children }],
  ['../../components/BandalMark', { BandalMark: emptyComponent }],
  ['../../components/ProviderMark', { ProviderMark: emptyComponent }],
  ['../../app/icons', { Icon: emptyComponent }], ['./SettingsIcon', { Icon: emptyComponent }],
  ['../../app/shortcuts', { ADD_COURSE_SHORTCUT_EVENT: 'add-course', IMPORT_MATERIALS_SHORTCUT_EVENT: 'import', SHORTCUT_HELP_EVENT: 'shortcuts' }],
  ['../../stores/coursesStore', { useCoursesStore: selector => selector({ selectedCourseId: null }) }],
  ['../../stores/workspaceStore', { useWorkspaceStore: { getState: () => ({ openTab() { throw Error('Help update must not open a browser tab') } }) } }],
  ['../workspace/tabIdentity', { descriptorFor() { throw Error('Unexpected tab creation') } }],
  ['../onboarding/tour/tourStore', { useTourStore: { getState: () => ({}) } }],
  ['./FeedbackDialog', { FeedbackDialog: emptyComponent, OPEN_FEEDBACK_EVENT: 'feedback' }],
  ['./MilestonesOverlay', { MilestonesOverlay: emptyComponent }], ['./ProgressRing', { ProgressRing: emptyComponent }],
  ['./milestonesStore', { useMilestones: selector => selector({ progress: {}, refresh: async () => {} }) }],
  ['../chat/agentConnectionStore', {}], ['../chat/AgentConnectionControls', {}],
  ['../onboarding/onboardingModel', {}], ['./savePreference', {}], ['./AppearancePanel', {}],
  [resolve(runtime, 'renderer/platform/api.ts'), {}]
])
async function load(relative, adapt = false) {
  const id = resolve(runtime, 'upstream/src', relative)
  let source = await readFile(id, 'utf8')
  if (adapt) for (const transform of [adaptPlatformSource, adaptLayoutSource, adaptInputSource, adaptStabilitySource]) source = transform(source, id)?.code ?? source
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2022 } }).outputText
  const exports = {}
  window.Function('require', 'exports', code)(id => {
    if (id.endsWith('.css')) return {}
    if (!modules.has(id)) throw Error('Unexpected fixture dependency: ' + id)
    return modules.get(id)
  }, exports)
  return exports
}
modules.set('../../../../shared/appLinks', await load('shared/appLinks.ts'))
modules.set('../../../../shared/keymap', { SHORTCUT_SPECS: [], parseChord: () => null, formatChord: () => '—' })
modules.set('../../../../shared/types/agent-events', { AGENT_PROVIDERS: [] })
const { useUiStore } = await load('renderer/src/stores/uiStore.ts')
const { useUpdateStore } = await load('renderer/src/stores/updateStore.ts')
modules.set('../../stores/uiStore', { useUiStore })
modules.set('../../stores/updateStore', { useUpdateStore })
modules.set('./primitives', await load('renderer/src/features/settings/primitives.tsx'))
const { HelpHub } = await load('renderer/src/features/help/HelpHub.tsx', true)
const { AboutPanel } = await load('renderer/src/features/settings/SettingsPanels.tsx', true)
const translated = {
  'ko-KR': (await load('renderer/src/i18n/messages/ko-KR.ts', true)).koKR,
  'en-US': (await load('renderer/src/i18n/messages/en-US.ts', true)).enUS
}
const root = api.createRoot(document.getElementById('root'))
function Screen() {
  const open = useUiStore(state => state.isSettingsOpen), category = useUiStore(state => state.settingsCategory)
  return api.React.createElement(api.React.Fragment, null, api.React.createElement(HelpHub), open && category === 'about' && api.React.createElement(AboutPanel))
}
for (const [nextLocale, label] of [['ko-KR', '업데이트 안내'], ['en-US', 'Update instructions']]) {
  locale = nextLocale; messages = translated[locale]
  api.flushSync(() => { useUiStore.getState().closeSettings(); root.render(api.React.createElement(Screen)) })
  await new Promise(resolve => setTimeout(resolve, 0))
  assert.equal(useUpdateStore.getState().status.phase, 'unsupported')
  api.flushSync(() => document.querySelector('[aria-label="더 보기"]').click())
  const button = [...document.querySelectorAll('[role="menuitem"]')].find(element => element.textContent === label)
  assert.ok(button, 'The update action must be labeled as instructions in the selected language')
  assert.equal(button.disabled, false)
  const beforeClick = calls.length
  api.flushSync(() => button.click())
  assert.equal(useUiStore.getState().isSettingsOpen, true)
  assert.equal(useUiStore.getState().settingsCategory, 'about')
  assert.equal(document.querySelector('.help-menu'), null, 'Opening settings closes the Help menu')
  const distribution = document.querySelector('.settings-stack').textContent
  assert.ok(distribution.includes(messages['settings.update.ipadDistribution']), 'The actual adapted AboutPanel must display the existing distribution instructions')
  assert.match(distribution, /App Store/)
  assert.match(distribution, /TestFlight/)
  assert.match(distribution, locale === 'ko-KR' ? /개발용.*새 빌드/ : /development.*new build/)
  assert.equal(calls.length, beforeClick, 'Clicking instructions must send zero update IPC requests')
}
assert.deepEqual(calls, ['update:status'], 'Only the existing one-time version/status read is allowed; check/download/install stay unused')
api.flushSync(() => root.unmount()); dom.window.close()
console.log('PASS: adapted Help update instructions open actual about state and translated distribution card, with zero action IPC calls')
