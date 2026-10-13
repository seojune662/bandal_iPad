import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-native-layout-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, plugins: [react()],
  server: { host: '127.0.0.1', port: 0 }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1024, height: 900 } }), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(server.resolvedUrls.local[0] + 'renderer/nativePDF/layout-fixture.html')
  const latest = () => page.evaluate(() => window.nativeLayoutTrace.calls.findLast(call => call.channel === 'pdfNative:layout')?.payload)
  const visible = async value => page.waitForFunction(value => window.nativeLayoutTrace.active &&
    window.nativeLayoutTrace.calls.findLast(call => call.channel === 'pdfNative:layout')?.payload.visible === value, value)
  await visible(true)
  const assertHole = async locator => {
    const box = await locator.boundingBox(), viewport = await page.locator('.pdf-scroller').boundingBox()
    assert.ok(box && viewport)
    await page.waitForFunction(({ box, viewport }) => {
      const layout = window.nativeLayoutTrace.calls.findLast(call => call.channel === 'pdfNative:layout')?.payload
      return layout?.visible === true && layout.holes.some(hole => Math.abs(hole.x-(box.x-viewport.x-2))<1 &&
        Math.abs(hole.y-(box.y-viewport.y-2))<1 && Math.abs(hole.width-(box.width+4))<1 && Math.abs(hole.height-(box.height+4))<1)
    }, { box, viewport })
  }
  await page.getByRole('button', { name: '필기 스타일', exact: true }).click()
  const palette = page.getByRole('dialog', { name: '필기 스타일', exact: true })
  await palette.waitFor(); await assertHole(palette)
  assert.equal((await latest()).visible, true, 'The original portal palette keeps the native body on screen')
  await palette.locator('button[data-color="red"]').click()
  assert.equal(await palette.locator('button[data-color="red"]').getAttribute('aria-pressed'), 'true')
  assert.equal(await palette.count(), 1, 'A palette action stays open instead of being reported as paper contact')
  await palette.evaluate(node => node.setAttribute('aria-modal', 'true')); await visible(false)
  await palette.evaluate(node => node.removeAttribute('aria-modal')); await visible(true)
  const pointerCount = await page.evaluate(() => window.nativeLayoutTrace.pointerEvents)
  await page.evaluate(() => window.nativeLayoutTrace.contact())
  await palette.waitFor({ state: 'detached' })
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.pointerEvents), pointerCount, 'Native paper contact dismisses using Escape, never a fabricated pointer')
  assert.equal((await latest()).visible, true)
  await page.getByRole('button', { name: 'Open highlight', exact: true }).click()
  const highlight = page.getByRole('dialog', { name: '하이라이트 편집', exact: true })
  await highlight.waitFor(); await assertHole(highlight)
  await highlight.locator('textarea').fill('A comment can be edited above the native PDF')
  assert.equal((await latest()).visible, true, 'The original annotation editor is nonmodal as well')
  await page.getByRole('button', { name: 'Open modal', exact: true }).click(); await visible(false)
  const modal = page.getByRole('dialog', { name: 'Settings fixture', exact: true, includeHidden: true })
  await modal.evaluate(node => node.hidden = true); await visible(true)
  await modal.evaluate(node => node.hidden = false); await visible(false)
  await page.getByRole('button', { name: 'Close modal', exact: true }).click(); await visible(true)
  assert.deepEqual(errors, [])
  console.log('PASS: production useNativePDF hook keeps original style/highlight popovers visible with exact apertures, hides for true modals, restores after close/hidden changes')
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
