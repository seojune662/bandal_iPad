import assert from 'node:assert/strict'
import vm from 'node:vm'
import { readFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { createRequire } from 'node:module'
import { dependencies, runtime } from './dependencies.mjs'
import { adaptPlatformSource } from '../renderer/platform/index.mjs'

const { require } = dependencies()
const { build } = createRequire(require.resolve('vite'))('esbuild')
const calls = [], opened = [], warnings = []
const workspace = { surface: 'course', activeCourseId: 'course', activePanelId: 'pdf:course:one.pdf',
  showCourseWorkspace(id) { this.activeCourseId = id }, openTab(tab) { opened.push(tab) } }
const courses = { selectedCourseId: 'course', courses: [{ id: 'course' }], selectCourse(id) { this.selectedCourseId = id } }
const stores = { useWorkspaceStore: { getState: () => workspace }, useCoursesStore: { getState: () => courses },
  useMaterialsStore: { getState: () => ({ activeCourseId: 'course' }) }, usePluginsStore: { getState: () => ({ plugins: [] }) } }
const mockModules = {
  ...Object.fromEntries(Object.keys(stores).map(name => [name[3].toLowerCase() + name.slice(4), `export const ${name} = globalThis.stores.${name}`])),
  toast: 'export function showToast(...args) { globalThis.warnings.push(args) }',
  settingsStore: 'export const getSettings = () => globalThis.settings',
  agentConnectionStore: `export const isAgentConnectionReady = () => false;
    export const useAgentConnectionStore = {getState: () => ({connections: Object.fromEntries(['codex','claude-code','gemini'].map(provider => [provider,{availability:null,availabilityRevision:0}]))}),subscribe:()=>()=>{}};`
}
const compiled = await build({ stdin: { contents: `
export { openMaterialInCourse } from './upstream/src/renderer/src/features/workspace/openMaterial';
export { materialKindForPath } from './upstream/src/shared/materialKind';
export { acquireChatSession, selectChatSession, refreshChatSession } from './upstream/src/renderer/src/features/chat/chatSessionStore';
export { resolveKeymap, formatChord, parseChord } from './upstream/src/shared/keymap';
export { browserShortcuts } from './backend/browser-shortcuts';
`, resolveDir: runtime, loader: 'ts' }, bundle: true, write: false, platform: 'browser', format: 'iife', globalName: 'Fixture',
  define: { 'process.env.NODE_ENV': '"production"' }, plugins: [{ name: 'original-platform-fixture', setup(b) {
    b.onResolve({ filter: /\/[^/]+$/ }, args => {
      const name = args.path.split('/').at(-1)
      if (Object.hasOwn(mockModules, name)) return { path: name, namespace: 'fixture' }
    })
    b.onLoad({ filter: /.*/, namespace: 'fixture' }, args => ({ contents: mockModules[args.path], loader: 'ts' }))
    b.onLoad({ filter: /\.[tj]sx?$/ }, async args => {
      const original = await readFile(args.path, 'utf8'), changed = adaptPlatformSource(original, args.path)
      return changed ? { contents: changed.code, loader: args.path.endsWith('tsx') ? 'tsx' : 'ts', resolveDir: dirname(args.path) } : undefined
    })
  }}] })
let resolvedSurface = 'desktop', recording = { id: 'recording-1', title: '녹음' }
const context = { stores, warnings, console, setTimeout, clearTimeout, URL, requestAnimationFrame: callback => setTimeout(callback, 0), cancelAnimationFrame: clearTimeout,
  window: { bandal: { on: () => () => {}, async invoke(channel, request) {
    calls.push({ channel, request })
    if (channel === 'recordings:resolve') return recording
    if (channel === 'chat:open') return { history: [], eventSeq: 0, availability: { installed: false }, sessionInfo: { surface: resolvedSurface, provider: 'codex', status: 'idle' } }
    if (['activity:record', 'materials:reveal'].includes(channel)) return { ok: true }
    throw new Error('Unexpected fixture channel ' + channel)
  } } } }
vm.runInNewContext(compiled.outputFiles[0].text, context)
const api = context.Fixture
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
const plain = value => JSON.parse(JSON.stringify(value))
for (const [file, expected] of [['one.PDF','pdf'], ['note.markdown','note'], ['image.heic','image'], ['clip.mp4','file'], ['one.docx','file'], ['one.xlsx','file'], ['one.pptx','file'], ['one.hwp','file']]) {
  api.openMaterialInCourse('course', api.materialKindForPath(file), file)
  assert.equal(opened.at(-1).kind, expected, file)
  assert.equal(opened.at(-1).payload.relPath, file)
}
const count = opened.length
api.openMaterialInCourse('course', api.materialKindForPath('opaque.bin'), 'opaque.bin')
await tick()
assert.equal(opened.length, count)
assert.ok(calls.some(call => call.channel === 'materials:reveal' && call.request.relPath === 'opaque.bin'))
api.openMaterialInCourse('course', api.materialKindForPath('audio.wav'), 'audio.wav')
await tick()
assert.equal(opened.at(-1).kind, 'recording')
assert.equal(opened.at(-1).payload.sessionId, 'recording-1')
recording = null
api.openMaterialInCourse('course', 'other', 'missing.wav')
await tick()
assert.ok(calls.some(call => call.channel === 'materials:reveal' && call.request.relPath === 'missing.wav'))
const appShell = await readFile(resolve(runtime, 'upstream/src/renderer/src/app/AppShell.tsx'), 'utf8')
const appAdapted = adaptPlatformSource(appShell, '/renderer/src/app/AppShell.tsx').code
assert.ok(appAdapted.includes('openMaterialInCourse(pendingMaterial.courseId, materialKindForPath(pendingMaterial.relPath), pendingMaterial.relPath)'))
assert.ok(!appAdapted.includes('nativeMaterialDescriptor('))

const settings = { keybindings: {}, shortcutPriority: 'bandal', locale: 'ko-KR' }
let shortcuts = plain(api.browserShortcuts(settings))
assert.ok(shortcuts.some(item => item.chord === 'mod+shift+space' && item.action === 'open-assistant'))
assert.ok(shortcuts.some(item => item.chord === 'mod+1' && item.action === 'activate-tab-1'))
assert.ok(shortcuts.some(item => item.chord === 'mod+r' && item.action === 'reload'))
assert.equal(api.formatChord(api.parseChord('mod+shift+space'), 'ipad'), '⌘⇧Space')
shortcuts = plain(api.browserShortcuts({ ...settings, shortcutPriority: 'site', keybindings: { 'new-tab': 'x', 'browser-find': 'mod+c', 'open-assistant': 'mod+alt+o' } }))
assert.ok(!shortcuts.some(item => ['x', 'mod+c', 'mod+r'].includes(item.chord)))
assert.ok(shortcuts.some(item => item.chord === 'mod+alt+o' && item.action === 'open-assistant'))
assert.ok(!shortcuts.some(item => item.chord === 'mod+shift+space'))

const release = api.acquireChatSession('course', 'conversation', 'desktop')
await tick()
assert.equal(api.selectChatSession('conversation').surface, 'desktop')
const releaseExpanded = api.acquireChatSession('course', 'conversation', 'app')
api.refreshChatSession('course', 'conversation')
await tick()
assert.equal(calls.filter(call => call.channel === 'chat:open').at(-1).request.surface, 'desktop', 'Expanded conversation keeps actual backend surface')
releaseExpanded(); release()
resolvedSurface = 'app'
const releaseExisting = api.acquireChatSession('course', 'existing-app', 'desktop')
await tick()
assert.equal(api.selectChatSession('existing-app').surface, 'app', 'Existing app conversation cannot acquire MCP surface by UI placement')
releaseExisting()
const chatSurface = await readFile(resolve(runtime, 'upstream/src/renderer/src/features/chat/ChatSurface.tsx'), 'utf8')
const chatAdapted = adaptPlatformSource(chatSurface, '/renderer/src/features/chat/ChatSurface.tsx').code
assert.ok(chatAdapted.includes("surface === 'app' && (variant === 'sidebar' || sourcePanelId)"))
assert.ok(chatAdapted.includes('surface={session.surface ?? effectiveSurface}'))
console.log('Original material resolver, pending-open dispatch, recording/fallback, persisted assistant surface and original customized guest shortcuts passed')
