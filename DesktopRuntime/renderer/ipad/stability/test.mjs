import assert from 'node:assert/strict'
import vm from 'node:vm'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import { adaptPlatformSource } from '../../platform/index.mjs'
import { adaptStabilitySource } from './index.mjs'
const { require } = dependencies(), ts = require('typescript')
const { build } = createRequire(require.resolve('vite'))('esbuild')
async function compile(entry) {
  const result = await build({ entryPoints: [resolve(runtime, entry)], bundle: true, write: false, platform: 'browser', format: 'iife', globalName: 'Fixture', define: { 'process.env.NODE_ENV': '"production"' } })
  return result.outputFiles[0].text
}
class CustomEvent extends Event { constructor(type, init = {}) { super(type, init); this.detail = init.detail } }
const calls = [], notices = [], globalErrors = []
let next = { ok: true }
const target = Object.assign(new EventTarget(), {
  crypto: { randomUUID: () => 'renderer-fixture' }, performance: { now: () => 0 },
  webkit: { messageHandlers: { bandal: { async postMessage(message) { calls.push(message); if (next instanceof Error) throw next; return next } } } }
})
target.addEventListener('bandal:operation-error', event => notices.push(event.detail))
target.addEventListener('error', event => globalErrors.push(event))
const context = { window: target, Event, CustomEvent, Uint8Array, atob, Date }
vm.runInNewContext(await compile('renderer/bridge.ts'), context)
context.Fixture.installNativeBridge(target)
next = { __bandalError: { code: 'SQLITE_BUSY', message: '저장할 수 없습니다.', category: 'operation', retryable: false, requestId: 'request-1' } }
await assert.rejects(target.bandal.invoke('notes:write', {}), error => error.name === 'BandalOperationError' && error.code === 'SQLITE_BUSY' && error.channel === 'notes:write' && error.requestId === 'request-1')
next = { __bandalError: { code: 'UNSUPPORTED_CHANNEL', message: '지원하지 않습니다.', category: 'unsupported', retryable: false } }
await assert.rejects(target.bandal.invoke('plugins:approve', {}), error => error.category === 'unsupported')
next = new Error('The WebKit connection closed')
await assert.rejects(target.bandal.invoke('notes:write', {}), error => error.category === 'transport' && error.retryable === false)
next = { ok: true }
await target.bandal.invoke('runtime:rendererReady', {})
assert.equal(calls.at(-1).request.rendererSessionId, 'renderer-fixture')
await target.bandal.invoke('materials:watch', { courseId: 'course', subscriptionId: 'pane-1' })
assert.equal(calls.at(-1).request.subscriptionId, 'pane-1')
assert.equal(calls.at(-1).request.rendererSessionId, 'renderer-fixture')
const beforeDrag = calls.length
target.bandal.startMaterialDrag('course', 'file.pdf')
assert.equal(calls.length, beforeDrag, 'Legacy OS drag cannot invoke an unregistered channel')
assert.equal(notices.at(-1).reason.category, 'unsupported')
assert.equal(globalErrors.length, 0)
target.bandal.on('fixture:event', () => { throw Error('view failure') })
target.__bandalReceive('fixture:event', {})
assert.equal(notices.at(-1).operation, '화면 갱신')
assert.equal(globalErrors.length, 0)

const dragWindow = Object.assign(new EventTarget(), { setTimeout, removeEventListener: EventTarget.prototype.removeEventListener })
const dragContext = { window: dragWindow, setTimeout, clearTimeout, console, Event, CustomEvent, URL, TextEncoder, TextDecoder }
vm.runInNewContext(await compile('renderer/ipad/stability/materialActions.tsx'), dragContext)
const transfer = new Map(), event = { dataTransfer: { setData: (type, data) => transfer.set(type, data) }, preventDefault: () => { throw Error('An internal drag must not be cancelled') } }
dragContext.Fixture.startIPadMaterialDrag(event, 'course', { kind: 'pdf', relPath: 'document.pdf', name: 'document.pdf' })
assert.equal(JSON.parse(transfer.get('application/x-bandal-material-move')).relPath, 'document.pdf')
dragWindow.dispatchEvent(new Event('dragend'))
const folders = dragContext.Fixture.materialMoveFolders([{ kind: 'dir', relPath: 'one', name: 'one', children: [{ kind: 'dir', relPath: 'one/inside', name: 'inside' }] }, { kind: 'dir', relPath: 'two', name: 'two' }], { kind: 'dir', relPath: 'one', name: 'one' })
assert.deepEqual(JSON.parse(JSON.stringify(folders)), [{ path: 'two', name: 'two' }])

const files = ['features/materials/MaterialTree.tsx', 'features/materials/MaterialsSidebar.tsx', 'features/materials/MaterialsContextMenu.tsx', 'app/RendererErrorBoundary.tsx', 'features/workspace/panelContentHost.tsx', 'features/notes/NoteTab.tsx', 'stores/pluginsStore.ts', 'features/plugins/PluginPanelTab.tsx', 'features/plugins/PluginMenuItems.tsx', 'features/chat/AddMenu.tsx', 'features/chat/AgentConnectionControls.tsx', 'features/settings/PluginDevelopmentPanel.tsx', 'features/settings/PluginsCategoryPanel.tsx', 'features/settings/ExtensionsPanel.tsx', 'features/settings/catalog/CatalogCard.tsx']
for (const file of files) {
  const id = resolve(runtime, 'upstream/src/renderer/src', file), original = await readFile(id, 'utf8')
  const platform = adaptPlatformSource(original, id)?.code ?? original
  const code = adaptStabilitySource(platform, id)?.code
  assert.ok(code && code !== original, file)
  const diagnostics = ts.transpileModule(code, { reportDiagnostics: true, compilerOptions: { target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX } }).diagnostics
  assert.equal(diagnostics.length, 0, file)
  if (file.endsWith('MaterialTree.tsx')) assert.ok(!code.includes('startNativeMaterialDrag(courseId, node.relPath)'))
  if (file.endsWith('PluginDevelopmentPanel.tsx')) assert.ok(!code.includes("invoke('plugins:devFolders'"))
  if (file.endsWith('RendererErrorBoundary.tsx')) assert.ok(!code.includes('window.location.reload()'))
  if (file.endsWith('panelContentHost.tsx')) assert.ok(code.includes('<DocumentErrorBoundary><Component {...entry.props} /></DocumentErrorBoundary>'))
  if (file.endsWith('AddMenu.tsx')) assert.ok(!code.includes("invoke('agent:skills'"))
  if (file.endsWith('PluginPanelTab.tsx')) assert.ok(!code.includes('<webview'))
}
const recovery = await readFile(resolve(runtime, 'renderer/ipad/stability/recovery.ts'), 'utf8')
assert.ok(recovery.indexOf("('runtime:prepareReload', {})") < recovery.indexOf('window.location.reload()'))

const hostRoot = resolve(runtime, '../App/Desktop'), contract = await readFile(resolve(hostRoot, 'DesktopBridgeContract.swift'), 'utf8')
const inventory = new Set([...contract.matchAll(/"([A-Za-z]+:[A-Za-z]+)"/g)].map(match => match[1]))
const hostFiles = ['DesktopShell.swift', 'DesktopBrowserHost.swift', 'DesktopSystemServices.swift', 'DesktopRecordingService.swift', 'DesktopFileServices.swift', 'DesktopAccountService.swift', 'DesktopCredentialsService.swift', 'DesktopCaptureService.swift', 'DesktopMiniPlayer.swift', 'PDF/NativePDFHost.swift']
for (const file of hostFiles) {
  let source = await readFile(resolve(hostRoot, file), 'utf8')
  if (file === 'DesktopShell.swift') source = source.slice(source.indexOf('private func handle(_ channel'), source.indexOf('private func handlePlatform'))
  const cases = [...source.matchAll(/case ((?:"[^"]+"(?:,\s*)?)+):/g)].flatMap(match => [...match[1].matchAll(/"([A-Za-z]+:[A-Za-z]+)"/g)].map(value => value[1]))
  if (file === 'PDF/NativePDFHost.swift') cases.push(...[...source.matchAll(/if channel == "([^"]+)"/g)].map(match => match[1]))
  for (const channel of cases.filter(channel => !channel.startsWith('native'))) assert.ok(inventory.has(channel), `${file}: missing capability ${channel}`)
}

const readinessContext = { window: target, Event, CustomEvent }; vm.runInNewContext(await compile('renderer/ipad/stability/operations.ts'), readinessContext)
const readiness = readinessContext.Fixture.featureReadiness
assert.equal(readiness('ai', { installed: true, loggedIn: false }).state, 'requiresSetup')
assert.equal(readiness('ai', { installed: true, loggedIn: true }).state, 'available')
assert.equal(readiness('ai', { installed: true, loggedIn: true }).reachability, 'unverified')
assert.equal(readiness('account', { phase: 'unconfigured' }).state, 'requiresSetup')
assert.equal(readiness('account', { phase: 'signed-in' }).state, 'available')
assert.equal(readiness('appleCalendar', { supported: false }).state, 'unsupported')
assert.equal(readiness('appleCalendar', { supported: true, connected: true, authorization: 'denied' }).state, 'requiresSetup')
assert.equal(readiness('appleCalendar', { supported: true, connected: true, authorization: 'authorized' }).state, 'available')
assert.equal(readiness('credentials', { state: 'unavailable', reason: 'Keychain unavailable' }).state, 'requiresSetup')
assert.equal(readiness('remoteMCP', { availability: { available: true }, servers: [{ transport: 'stdio', enabled: true, lastTest: { ok: true } }] }).state, 'requiresSetup')
assert.equal(readiness('remoteMCP', { availability: { available: true }, servers: [{ transport: 'http', enabled: true, lastTest: { ok: true } }] }).state, 'available')
assert.equal(readiness('mail', { status: 'unconfigured' }).state, 'requiresSetup')
assert.equal(readiness('legacyPresentation', { status: 'missing' }).state, 'requiresSetup')
assert.equal(readiness('legacyPresentation', { status: 'ready' }).reachability, 'unverified')
assert.equal(readiness('nativePDF', { enabled: false, development: false }).state, 'unsupported')
assert.equal(readiness('nativePDF', { enabled: false, development: true }).state, 'requiresSetup')
assert.equal(readiness('nativePDF', { enabled: true, development: true }).state, 'available')

// The actual transformed chat setup button must enter the API settings flow,
// never dispatch CLI installation/login from the separate chat entry point.
const controlID = resolve(runtime, 'upstream/src/renderer/src/features/chat/AgentConnectionControls.tsx')
const controlCode = adaptStabilitySource(await readFile(controlID, 'utf8'), controlID).code
assert.ok(!/startAgent|prepareAgent|reopenAgent|submitAgent/.test(controlCode))
let providerAvailability = { installed: true, loggedIn: false }, openedSettings
const controls = { exports: {}, require: id => {
  if (id === 'react/jsx-runtime') return { jsx: (type, props) => ({ type, props }), jsxs: (type, props) => ({ type, props }) }
  if (id === '../../i18n') return { useLocale: () => 'ko-KR' }
  if (id === '../../stores/uiStore') return { useUiStore: { getState: () => ({ openSettings: category => { openedSettings = category } }) } }
  if (id === './agentConnectionStore') return { useAgentConnectionStore: selector => selector({ connections: { codex: { availability: providerAvailability, availabilityError: null } } }) }
  if (id.endsWith('/operations.ts')) return { featureReadiness: readiness }
  if (id.endsWith('.css')) return {}
  throw Error('Unexpected setup dependency: ' + id)
} }
vm.runInNewContext(ts.transpileModule(controlCode, { compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2022 } }).outputText, controls)
let setupCard = controls.exports.AgentConnectionControls({ provider: 'codex', availability: providerAvailability })
assert.equal(setupCard.props['data-state'], 'requiresSetup')
setupCard.props.children.find(child => child?.type === 'button').props.onClick()
assert.equal(openedSettings, 'ai')
providerAvailability = { installed: true, loggedIn: true }
setupCard = controls.exports.AgentConnectionControls({ provider: 'codex', availability: providerAvailability })
assert.equal(setupCard.props['data-state'], 'available')
assert.match(setupCard.props.children[0].props.children, /실제 요청/)


class Element {
  constructor(tag) { this.tag = tag; this.style = {}; this.children = []; this.attributes = {}; this.listeners = {}; this.isConnected = false }
  setAttribute(name, value) { this.attributes[name] = value }
  addEventListener(name, callback) { this.listeners[name] = callback }
  append(...children) { for (const child of children) { child.parent = this; child.connect(this.isConnected); this.children.push(child) } }
  connect(value) { this.isConnected = value; this.children.forEach(child => child.connect(value)) }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); this.connect(false) }
  find(id) { return this.id === id ? this : this.children.map(child => child.find(id)).find(Boolean) }
}
const body = new Element('body'); body.connect(true)
const document = { body, createElement: tag => new Element(tag), getElementById: id => body.find(id) }
const recoveryCalls = [], recoveryNotices = []
let saveError, reloadCount = 0
const recoveryWindow = Object.assign(new EventTarget(), { setTimeout, location: { reload: () => reloadCount++ }, bandal: { invoke: async (channel, request) => { recoveryCalls.push({ channel, request }); if (channel === 'runtime:prepareReload' && saveError) throw saveError; return { ok: true } } } })
recoveryWindow.addEventListener('bandal:operation-error', event => recoveryNotices.push(event.detail))
const recoveryContext = { window: recoveryWindow, document, Event, CustomEvent, setTimeout, clearTimeout, Error }
vm.runInNewContext(await compile('renderer/ipad/stability/recovery.ts'), recoveryContext)
const recover = recoveryContext.Fixture, tick = () => new Promise(resolve => setTimeout(resolve, 5))
recover.showOperationNotice({ reason: Error('initial'), retry: () => { throw Error('sync retry failure') } })
const notice = document.getElementById('bandal-operation-notice')
assert.equal(notice.attributes['aria-label'], '작업 오류'); assert.equal(notice.attributes['data-bandal-native-overlay'], '')
notice.children[2].children[0].listeners.click(); await tick()
assert.equal(notice.children[1].textContent, 'sync retry failure'); assert.ok(notice.isConnected)
const layoutRetry = async () => {}
recover.showOperationNotice({ reason: Error('native layout failed'), operation: 'layout', retry: layoutRetry })
const layoutNotice = document.getElementById('bandal-operation-notice')
for (let repeat = 0; repeat < 100; repeat++) recover.showOperationNotice({ reason: Error('native layout failed'), operation: 'layout', retry: layoutRetry })
assert.equal(document.getElementById('bandal-operation-notice'), layoutNotice, 'Repeated surface failures cannot recreate DOM and retrigger the mask observer')
recover.showStartupFailure(Error('startup'))
const startup = document.getElementById('bandal-native-diagnostic')
assert.equal(startup.attributes['aria-label'], '시작 오류'); assert.equal(startup.attributes['data-bandal-native-overlay'], '')
saveError = Error('conflict')
await assert.rejects(recover.recoverRenderer(), /conflict/); assert.equal(reloadCount, 0)
assert.equal(recoveryNotices.at(-1).reason.message, 'conflict')
saveError = undefined
let finishClose
const closing = recover.trackDocumentClose(() => new Promise(resolve => { finishClose = resolve }))
await tick()
const beforeClose = recoveryCalls.length, waitingRecovery = recover.recoverRenderer(); await tick()
assert.equal(recoveryCalls.length, beforeClose, 'Close preservation must finish before native save/reload')
finishClose({ status: 'saved' }); await closing; await waitingRecovery; assert.equal(reloadCount, 1)
let closeAttempts = 0
await recover.trackDocumentClose(async () => ({ status: ++closeAttempts < 3 ? 'failed' : 'saved' }))
await assert.rejects(recover.recoverRenderer(), /저장하지 못했습니다/); assert.equal(reloadCount, 1)
await recover.recoverRenderer(); assert.equal(closeAttempts, 3); assert.equal(reloadCount, 2)

vm.runInNewContext(await compile('renderer/ipad/stability/DocumentErrorBoundary.tsx'), recoveryContext)
const Boundary = recoveryContext.Fixture.DocumentErrorBoundary
const failed = new Boundary({ children: 'failed document' }), sibling = new Boundary({ children: 'other document' })
failed.setState = update => { failed.state = { ...failed.state, ...update } }
failed.componentDidMount(); failed.state = { ...failed.state, ...Boundary.getDerivedStateFromError(Error('render failed')) }
assert.equal(failed.render().props['data-bandal-native-overlay'], ''); assert.equal(sibling.render(), 'other document')
failed.componentDidCatch(Error('private document message'))
assert.equal(recoveryCalls.at(-1).channel, 'runtime:diagnostic'); assert.ok(!JSON.stringify(recoveryCalls.at(-1).request).includes('private document'))
saveError = Error('failed write'); failed.recover(); await failed.recovery
assert.ok(failed.state.error); assert.equal(failed.state.recoveryError, 'failed write'); assert.equal(sibling.render(), 'other document')
saveError = undefined; failed.recover(); await failed.recovery
assert.equal(failed.render(), 'failed document'); assert.equal(reloadCount, 2, 'Document recovery cannot reload its siblings or shell')
console.log('PASS: typed failures, visible retry notices, renderer leases, internal material drag, complete native route inventory, readiness distinctions, disabled unsupported controls, isolated document boundary and save-before-recovery')
await import('./test-background-errors.mjs')
await import('./test-help-update.mjs')
