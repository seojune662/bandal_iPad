import assert from 'node:assert/strict'
import { readFile, readdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import vm from 'node:vm'
import { dependencies, runtime } from './dependencies.mjs'
import { verifySnapshot } from './verify-snapshot.mjs'

await verifySnapshot(process.env.BANDAL_DESKTOP_SOURCE)
const { require } = dependencies()
const ts = require('typescript')
const originalBridge = await readFile(resolve(runtime, 'renderer/bridge.ts'), 'utf8')
const transpiled = ts.transpileModule(originalBridge, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, strict: true } }).outputText
const calls = []
let nextReply = { actual: true }
class NativeErrorEvent extends Event { constructor(name, values) { super(name); Object.assign(this, values) } }
const target = Object.assign(new EventTarget(), { webkit: { messageHandlers: { bandal: { async postMessage(message) {
  calls.push(message)
  if (nextReply instanceof Error) throw nextReply
  return nextReply
} } } } })
const context = { exports: {}, window: target, ErrorEvent: NativeErrorEvent, Uint8Array, atob }
vm.runInNewContext(transpiled, context, { filename: 'native-bridge.js' })
assert.throws(() => context.exports.installNativeBridge({}), /네이티브 연결/)
context.exports.installNativeBridge(target)
assert.equal(target.bandal.platform, 'ipad')
const request = { courseId: 'fixture-course' }
assert.equal((await target.bandal.invoke('courses:list', request)).actual, true)
assert.equal(calls.at(-1).channel, 'courses:list')
assert.equal(calls.at(-1).request, request)
nextReply = new Error('Native storage is full')
await assert.rejects(target.bandal.invoke('notes:write', {}), /Native storage is full/)
nextReply = { nested: [{ __bandalBytes: 'AAH+/w==' }] }
assert.deepEqual(Array.from((await target.bandal.invoke('browser:pageAction', {})).nested[0]), [0, 1, 254, 255])
let update
const stop = target.bandal.on('settings:changed', value => { update = value })
target.__bandalReceive('settings:changed', { settings: { theme: 'source-theme' } })
assert.equal(update.settings.theme, 'source-theme')
stop(); update = null
target.__bandalReceive('settings:changed', { settings: {} })
assert.equal(update, null)
nextReply = { ok: true }
await target.bandal.openSettings()
assert.equal(calls.at(-1).channel, 'window:openSettings')
console.log('Native transport: real replies, rejection, binary buffers, push unsubscribe and settings routing passed')

const bootstrap = await readFile(resolve(runtime, 'renderer/bootstrap.ts'), 'utf8')
assert.ok(bootstrap.indexOf('installNativeBridge()') < bootstrap.indexOf("import('../upstream/src/renderer/src/main')"))
assert.ok(!bootstrap.includes('web-demo/'))
assert.ok(!bootstrap.includes('Math.random('))
const output = resolve(runtime, '../App/Resources/Desktop')
const viteManifest = JSON.parse(await readFile(resolve(output, '.vite/manifest.json'), 'utf8'))
const allChunks = Object.values(viteManifest)
const bundledSources = JSON.parse(await readFile(resolve(output, 'bundled-source.json'), 'utf8'))
assert.ok(bundledSources.includes('upstream/src/renderer/src/main.tsx'), 'Actual desktop main entry must be bundled')
assert.ok(allChunks.some(chunk => chunk.src?.endsWith('/features/settings/SettingsApp.tsx')), 'Actual 20-route settings application must be bundled')
const files = await readdir(resolve(output, 'assets'))
assert.ok(files.filter(file => file.startsWith('PretendardVariable.subset.') && file.endsWith('.woff2')).length > 50, 'Original Korean font subsets must ship locally')
assert.ok(files.some(file => file.startsWith('pdf.worker') && file.endsWith('.mjs')), 'PDF.js worker must ship locally')
assert.ok(files.some(file => file.endsWith('.wasm')), 'Original PPTX renderer WASM must ship locally')
const html = await readFile(resolve(output, 'index.html'), 'utf8')
assert.ok(html.includes('./assets/'), 'Resources must be relative to bandal-app://shell/')
assert.ok(!html.includes('/app-demo/'))
assert.ok(html.includes('bandal-media:'))
console.log('Full renderer bundle: original entry/settings, local Pretendard, PDF worker, PPTX WASM and relative URLs passed')
