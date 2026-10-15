import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import { adaptPlatformSource } from '../../platform/index.mjs'
import { adaptLayoutSource } from '../layout/index.mjs'
import { adaptInputSource } from '../input/index.mjs'
import { adaptStabilitySource } from './index.mjs'

const { require } = dependencies(), { JSDOM } = require('jsdom')
const { build } = createRequire(require.resolve('vite'))('esbuild')
const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'https://bandal.test', runScripts: 'outside-only' })
const { window } = dom, { document } = window
const calls = [], failures = [], pending = []
let nativeWatchers
window.webkit = { messageHandlers: { bandal: { postMessage(message) {
  calls.push(message)
  if (nativeWatchers && message.channel === 'materials:watch') return nativeWatchers.watch(message.request).then(() => ({ ok: true }), error => ({ __bandalError: { code: 'EACCES', message: error.message, category: 'operation', retryable: false } }))
  if (nativeWatchers && message.channel === 'materials:unwatch') { nativeWatchers.unwatch(message.request); return Promise.resolve({ ok: true }) }
  if (message.channel === 'materials:watch') return new Promise(resolve => pending.push({ message, resolve }))
  return Promise.resolve({ ok: true })
} } } }
window.addEventListener('bandal:operation-error', event => failures.push(event.detail))
const bundled = await build({ stdin: { contents: `
export { installNativeBridge } from './renderer/bridge'
export { installBackendOperationErrors } from './renderer/ipad/stability/operations'
export { installOperationNotices } from './renderer/ipad/stability/recovery'
export { MaterialWatchNotice } from './renderer/ipad/stability/MaterialWatchNotice'
export { createMaterialWatchers } from './backend/material-watch'
export { createElement } from 'react'
export { createRoot } from 'react-dom/client'
export { flushSync } from 'react-dom'
`, resolveDir: runtime }, bundle: true, write: false, platform: 'browser', format: 'iife', globalName: 'Fixture', define: { 'process.env.NODE_ENV': '"production"' } })
window.eval(bundled.outputFiles[0].text)
const api = window.Fixture
api.installNativeBridge(window)
api.installOperationNotices()
let disposeErrors = api.installBackendOperationErrors(window)
const backend = value => window.__bandalReceive('backend:error', value)
const notice = () => document.getElementById('bandal-operation-notice')
const initialCalls = calls.length
backend({ operation: 'materials.watch', message: '폴더 접근이 거부되었습니다.', code: 'EACCES', channel: 'materials:watch', requestId: 'watch-1' })
assert.equal(failures.at(-1).reason.message, '폴더 접근이 거부되었습니다.')
assert.equal(failures.at(-1).reason.code, 'EACCES')
assert.equal(failures.at(-1).reason.channel, 'materials:watch')
assert.equal(failures.at(-1).reason.requestId, 'watch-1')
assert.equal(failures.at(-1).operation, '자료 변경 감시')
assert.equal(notice().getAttribute('data-bandal-native-overlay'), '')
const sameNotice = notice()
for (let index = 0; index < 100; index++) backend({ operation: 'materials.watch', message: '폴더 접근이 거부되었습니다.', code: 'EACCES', channel: 'materials:watch', requestId: `watch-${index}` })
assert.equal(notice(), sameNotice, 'Repeated polling failures must not replace DOM and trigger more surface layouts')
backend({ operation: 'learning.pathRecovery', message: '경로 복구 실패' })
assert.equal(failures.at(-1).reason.channel, 'learning.pathRecovery')
assert.equal(failures.at(-1).reason.code, 'BACKEND_OPERATION_FAILED')
assert.equal(failures.at(-1).operation, '학습 경로 복구')
backend({ operation: 'learning.settle', __bandalError: { message: '학습 저장 실패', code: 'SQLITE_BUSY', channel: 'learning:complete', category: 'operation', retryable: true, requestId: 'settle-1' } })
assert.equal(failures.at(-1).reason.message, '학습 저장 실패')
assert.equal(failures.at(-1).reason.code, 'SQLITE_BUSY')
assert.equal(failures.at(-1).reason.channel, 'learning:complete')
assert.equal(failures.at(-1).reason.requestId, 'settle-1')
assert.equal(failures.at(-1).reason.retryable, false)
assert.equal(failures.at(-1).retry, undefined)
assert.deepEqual([...notice().querySelectorAll('button')].map(button => button.textContent), ['닫기'], 'Async settlement errors cannot replay an AI run or write')
backend({ operation: 'learning.settle', error: { message: '저장 연결 종료', code: 'OFFLINE', channel: 'learning:save' } })
assert.equal(failures.at(-1).reason.code, 'OFFLINE')
assert.equal(failures.at(-1).reason.channel, 'learning:save')
assert.equal(failures.at(-1).reason.message, '저장 연결 종료')
assert.equal(calls.length, initialCalls, 'Reporting a push error must perform no bridge mutation')
const previousFailures = failures.length
disposeErrors(); backend({ message: 'retired subscription' })
assert.equal(failures.length, previousFailures)
disposeErrors = api.installBackendOperationErrors(window)
notice().remove()

const root = api.createRoot(document.getElementById('root')), changed = []
const mount = courseId => api.flushSync(() => root.render(api.createElement(api.MaterialWatchNotice, { courseId, onChange: id => { changed.push(id) } })))
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
async function until(predicate, description) {
  for (let attempt = 0; attempt < 100; attempt++) { if (predicate()) return; await tick() }
  assert.fail(description)
}
const localNotice = () => document.querySelector('[aria-label="자료 변경 감시 오류"]')
const rejectScan = (entry, message) => entry.resolve({ __bandalError: { code: 'EACCES', message, category: 'operation', retryable: false } })
mount('course-a')
await until(() => pending.length === 1, 'Initial watch did not start')
const first = pending.shift(), lease = first.message.request.subscriptionId
assert.ok(lease)
assert.ok(first.message.request.rendererSessionId)
rejectScan(first, '과목 A 폴더를 읽을 수 없습니다.')
await until(() => localNotice(), 'Initial watch failure was not displayed in the materials view')
assert.match(localNotice().textContent, /과목 A 폴더를 읽을 수 없습니다/)
assert.equal(localNotice().getAttribute('data-bandal-native-overlay'), '')
assert.equal(window.getComputedStyle(localNotice().querySelector('button')).minHeight, '44px')
assert.equal(window.getComputedStyle(localNotice().querySelector('button')).minWidth, '44px')
assert.equal(failures.length, previousFailures, 'The local failure must not also create a global notice')
api.flushSync(() => { const retry = localNotice().querySelector('button'); retry.click(); retry.click() })
assert.equal(pending.length, 1, 'Repeated taps share one pending watch retry')
assert.equal(localNotice().querySelector('button').disabled, true)
const retry = pending.shift()
assert.equal(retry.message.request.subscriptionId, lease, 'Retry must not create an extra lease')
rejectScan(retry, '여전히 읽을 수 없습니다.')
await until(() => localNotice()?.textContent.includes('여전히 읽을 수 없습니다.'), 'Failed retry lost its local error')
api.flushSync(() => localNotice().querySelector('button').click())
const success = pending.shift()
assert.equal(success.message.request.subscriptionId, lease)
success.resolve({ ok: true })
await until(() => !localNotice(), 'Successful retry did not clear the warning')
window.__bandalReceive('materials:changed', { courseId: 'course-b' })
window.__bandalReceive('materials:changed', { courseId: 'course-a' })
await tick()
assert.deepEqual(changed, ['course-a'])
mount('course-b')
await until(() => pending.length === 1, 'Changed course did not establish its own watch')
assert.equal(calls.find(call => call.channel === 'materials:unwatch' && call.request.courseId === 'course-a').request.subscriptionId, lease)
const retired = pending.shift()
mount('course-c')
await until(() => pending.length === 1, 'New course did not establish its own watch')
const current = pending.shift()
rejectScan(retired, '이전 과목의 늦은 오류')
await tick(); await tick()
assert.equal(localNotice(), null, 'A retired course failure cannot appear on the new course')
window.__bandalReceive('materials:changed', { courseId: 'course-b' })
await tick()
assert.deepEqual(changed, ['course-a'], 'Retired views must unsubscribe from change pushes')
api.flushSync(() => root.unmount())
rejectScan(current, '닫힌 화면의 늦은 오류')
await tick(); await tick()
assert.equal(localNotice(), null)
const unwatch = calls.filter(call => call.channel === 'materials:unwatch')
assert.deepEqual(unwatch.map(call => call.request.courseId), ['course-a', 'course-b', 'course-c'])
assert.equal(new Set(unwatch.map(call => call.request.subscriptionId)).size, 3)
assert.ok(calls.every(call => ['materials:watch', 'materials:unwatch'].includes(call.channel)), 'Recovery must not perform document or AI writes')

// Use the production backend watcher, including its retained failed lease and
// single-flight scan. A mutation push alone cannot establish watch recovery.
const timers = new Map()
let nextTimer = 0, folderFailure = true, folderTree = [], scans = 0
nativeWatchers = api.createMaterialWatchers({
  tree: async () => { scans++; if (folderFailure) throw Error('폴더 연결 실패'); return folderTree },
  invalidate() {},
  changed: courseId => window.__bandalReceive('materials:changed', { courseId }),
  failed: error => backend({ operation: 'materials.watch', message: error.message }),
  schedule: callback => { timers.set(++nextTimer, callback); return nextTimer },
  cancel: id => timers.delete(id)
})
const recoveredRoot = api.createRoot(document.getElementById('root'))
api.flushSync(() => recoveredRoot.render(api.createElement(api.MaterialWatchNotice, { courseId: 'recovery-course', onChange() {} })))
await until(() => localNotice(), 'The real backend initial failure was not displayed')
assert.equal(nativeWatchers.inspect().leases, 1, 'Initial failure retains its original subscription')
assert.equal(timers.size, 1)
api.flushSync(() => window.__bandalReceive('materials:changed', { courseId: 'recovery-course' }))
await until(() => !localNotice()?.querySelector('button').disabled, 'Watch revalidation did not settle')
assert.match(localNotice().textContent, /폴더 연결 실패/, 'A mutation push must not hide a failed watch')
assert.equal(nativeWatchers.inspect().leases, 1)
const firePoll = () => { const [id, callback] = timers.entries().next().value; timers.delete(id); callback() }
folderFailure = false
firePoll(); await tick(); await tick()
assert.ok(localNotice(), 'An initial recovered scan sends no changed event: do not invent a renderer acknowledgement')
const beforeRecoveryPush = calls.length, beforeRecoveryScans = scans
folderTree = ['recovered file']
firePoll()
await until(() => !localNotice(), 'Recovered polling plus a successful same-lease ACK must clear the local error')
assert.equal(scans, beforeRecoveryScans + 1, 'Revalidation joins the real polling scan without adding a full rescan')
assert.equal(calls.slice(beforeRecoveryPush).filter(call => call.channel === 'materials:watch').length, 1)
assert.equal(nativeWatchers.inspect().leases, 1)
api.flushSync(() => recoveredRoot.unmount())
assert.equal(nativeWatchers.inspect().leases, 0)
assert.equal(timers.size, 0)

const bootstrap = await readFile(resolve(runtime, 'renderer/bootstrap.ts'), 'utf8')
assert.ok(bootstrap.indexOf('  installNativeBridge()') < bootstrap.indexOf('  installBackendOperationErrors()'))
assert.ok(bootstrap.indexOf('  installBackendOperationErrors()') < bootstrap.indexOf("import('../upstream/src/renderer/src/main')"))
const sidebarID = resolve(runtime, 'upstream/src/renderer/src/features/materials/MaterialsSidebar.tsx')
let sidebar = await readFile(sidebarID, 'utf8')
for (const transform of [adaptPlatformSource, adaptLayoutSource, adaptInputSource, adaptStabilitySource]) sidebar = transform(sidebar, sidebarID)?.code ?? sidebar
assert.equal((sidebar.match(/<MaterialWatchNotice /g) ?? []).length, 1)
assert.ok(!sidebar.includes("invoke('materials:watch'"), 'The old watch effect must not establish a second subscription')
assert.ok(sidebar.includes('key={course?.folderPath}'), 'Relinking a folder must retire its previous watch')
disposeErrors(); dom.window.close()
console.log('PASS: backend push metadata, deduplicated errors without write retries, 44px watch retry, React failure/retry/retirement and real watcher recovery ACK')
