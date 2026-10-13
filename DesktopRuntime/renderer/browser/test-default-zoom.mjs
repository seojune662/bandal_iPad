import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
import browserPlugin from './index.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-browser-zoom-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, plugins: [browserPlugin(), react()],
  server: { host: '127.0.0.1', port: 0 }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage(), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(server.resolvedUrls.local[0] + 'renderer/browser/zoom-fixture.html')
  const zoomCalls = id => page.evaluate(id => window.zoomFixture.calls.filter(call => call.channel === 'browser:pageAction' &&
    call.request.tabId === id && call.request.action === 'setZoomLevel').map(call => call.request.args[0]), id)
  const waitZoom = (id, level) => page.waitForFunction(({id,level}) => window.zoomFixture.calls.some(call => call.channel === 'browser:pageAction' &&
    call.request.tabId === id && call.request.action === 'setZoomLevel' && call.request.args[0] === level), {id,level})
  await waitZoom('first', 1.22)
  assert.equal((await page.evaluate(() => window.zoomFixture.levels())).first, 1.22)
  await page.evaluate(() => window.zoomFixture.settings(3.07))
  await page.evaluate(() => { window.zoomFixture.navigate('first'); window.zoomFixture.add('second') })
  await waitZoom('second', 3.07)
  assert.ok((await zoomCalls('first')).every(value => value === 1.22), 'New-tab defaults never alter an existing tab while navigating')
  await page.evaluate(() => window.zoomFixture.zoom('first', 0))
  await waitZoom('first', 0)
  const count = (await zoomCalls('first')).length
  await page.evaluate(() => window.zoomFixture.navigate('first'))
  await page.waitForFunction(count => window.zoomFixture.calls.filter(call => call.channel === 'browser:pageAction' &&
    call.request.tabId === 'first' && call.request.action === 'setZoomLevel').length > count, count)
  assert.equal((await zoomCalls('first')).at(-1), 0, 'An explicit 100% must be reapplied, not skipped as a default')
  await page.evaluate(() => window.zoomFixture.remove('first'))
  await page.locator('[data-tab-id="first"]').waitFor({ state: 'detached' })
  await page.evaluate(() => window.zoomFixture.add('first'))
  await page.locator('[data-tab-id="first"]').waitFor({ state: 'attached' })
  await page.waitForFunction(() => window.zoomFixture.calls.filter(call => call.channel === 'browser:createPage' && call.request.tabId === 'first').length === 2)
  assert.equal((await zoomCalls('first')).at(-1), 0, 'Presentation remount retains the tab override')
  await page.evaluate(() => window.zoomFixture.add('private-tab'))
  await waitZoom('private-tab', 3.07)
  await page.evaluate(() => { window.zoomFixture.failOnce('failed'); window.zoomFixture.add('failed') })
  await page.getByRole('button', { name: '페이지 크기를 적용하지 못했어요. 다시 불러오면 재시도합니다.', exact: true }).waitFor()
  assert.equal((await page.evaluate(() => window.zoomFixture.levels())).failed, undefined, 'A failed native command cannot become a confirmed tab preference')
  await page.evaluate(() => window.zoomFixture.settings(0.53))
  await page.evaluate(() => window.zoomFixture.navigate('failed'))
  await page.waitForFunction(() => window.zoomFixture.levels().failed === 3.07)
  assert.ok((await zoomCalls('failed')).every(value => value === 3.07), 'Retry uses this tab’s captured default, not a later settings change')
  await page.getByRole('button', { name: '페이지 크기를 적용하지 못했어요. 다시 불러오면 재시도합니다.', exact: true }).click()
  await page.evaluate(() => { window.zoomFixture.deferOnce('late'); window.zoomFixture.add('late') })
  await waitZoom('late', 0.53)
  await page.evaluate(() => window.zoomFixture.zoom('late', 0))
  await waitZoom('late', 0)
  await page.evaluate(async () => { window.zoomFixture.rejectDeferred('late'); await new Promise(resolve => setTimeout(resolve, 0)) })
  assert.equal((await page.evaluate(() => window.zoomFixture.levels())).late, 0)
  assert.equal(await page.getByRole('button', { name: '페이지 크기를 적용하지 못했어요. 다시 불러오면 재시도합니다.', exact: true }).count(), 0,
    'A stale default failure cannot report an error after the user successfully chose another zoom')
  await page.evaluate(() => window.zoomFixture.settings(3.07))
  await page.reload(); await waitZoom('first', 3.07)
  assert.equal((await page.evaluate(() => window.zoomFixture.levels())).first, 3.07, 'Relaunch reads the persisted preference before mounting the original guest')
  assert.deepEqual(errors, [])
  console.log('PASS: original BrowserGuestView/nativePageHandle default zoom, private/relaunch/navigation/remount, explicit 100%, native failure feedback and retry without premature confirmation')
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
