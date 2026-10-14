import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
import pencilPlugin, { transformInkLayer } from './index.mjs'

const { require } = dependencies()
const { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const source = await readFile(resolve(runtime, 'upstream/src/renderer/src/features/ink/InkLayer.tsx'), 'utf8')
assert.throws(() => transformInkLayer(source.replace('const pendingSample = useRef', 'const staleInput = useRef')), /expected 1 source anchor/)

const server = await createServer({ configFile: false, root: runtime, server: { host: '127.0.0.1', port: 0 },
  plugins: [pencilPlugin(), react()], resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 800, height: 700 }, hasTouch: true })
  const failures = []
  page.on('pageerror', error => failures.push(error.message))
  await page.goto(`${server.resolvedUrls.local[0]}renderer/pencil/test-fixture.html`)
  await page.locator('.ink-layer').waitFor()
  // A real WebKit mouse gesture verifies React's actual event/capture path.
  await page.mouse.move(40, 60); await page.mouse.down()
  await page.mouse.move(140, 130, { steps: 8 }); await page.mouse.up()
  await page.waitForFunction(() => window.__pencilTest.created.length === 1)

  await page.evaluate(() => {
    const svg = document.querySelector('.ink-layer')
    // Synthetic pressure/coalescing is fixture data, not a claim of physical
    // Pencil input. Only synthetic IDs bypass the browser's capture registry.
    const capture = svg.setPointerCapture.bind(svg)
    svg.setPointerCapture = id => { if (id < 100) capture(id) }
    window.dispatchInkFixture = (type, pointerType, pointerId, x, y, pressure = 0.5, samples = []) => {
      const event = new PointerEvent(type, { bubbles: true, cancelable: true, pointerType, pointerId, clientX: x, clientY: y, pressure, button: 0, buttons: type === 'pointerup' ? 0 : 1 })
      Object.defineProperty(event, 'getCoalescedEvents', { value: () => samples.map(([clientX, clientY, pressure]) => new PointerEvent(type, { pointerId, pointerType, clientX, clientY, pressure })) })
      svg.dispatchEvent(event)
    }
    const send = window.dispatchInkFixture
    send('pointerdown', 'pen', 101, 60, 180, 0.2)
    send('pointermove', 'pen', 101, 180, 200, 0.7, [[90, 180, 0.3], [120, 185, 0.4], [150, 190, 0.6]])
    // Another pointer must neither replace the stroke nor commit/cancel it.
    send('pointerdown', 'touch', 102, 200, 200)
    send('pointermove', 'touch', 102, 210, 80)
    send('pointercancel', 'touch', 102, 210, 80)
    send('pointerup', 'touch', 102, 210, 80)
    send('pointerup', 'pen', 101, 200, 210, 0)
  })
  await page.waitForFunction(() => window.__pencilTest.created.length === 2)
  let state = await page.evaluate(() => window.__pencilTest)
  const points = state.created[1].data.points
  assert.deepEqual(points.map(point => Math.round(point.p * 100)), [20, 30, 40, 60, 70, 0])
  assert.equal(await page.locator('.pdf-scroller').evaluate(node => node.scrollTop), 0, 'palm must not scroll while writing')

  await page.evaluate(() => {
    const send = window.dispatchInkFixture
    send('pointerdown', 'touch', 103, 300, 280)
    send('pointermove', 'touch', 103, 300, 180)
    send('pointerup', 'touch', 103, 300, 180)
  })
  assert.equal(await page.locator('.pdf-scroller').evaluate(node => node.scrollTop), 100)
  state = await page.evaluate(() => window.__pencilTest)
  assert.equal(state.created.length, 2, 'finger pan must never create ink')

  await page.evaluate(() => {
    const send = window.dispatchInkFixture
    send('pointerdown', 'touch', 104, 150, 200)
    send('pointerdown', 'touch', 105, 350, 200)
    send('pointermove', 'touch', 105, 400, 200)
    send('pointerup', 'touch', 104, 150, 200)
    send('pointerup', 'touch', 105, 400, 200)
    send('pointerdown', 'pen', 106, 80, 150, 0.5)
    send('pointermove', 'pen', 106, 160, 170, 0.9)
    send('pointercancel', 'pen', 106, 170, 180, 0)
  })
  await page.waitForFunction(() => window.__pencilTest.created.length === 3)
  state = await page.evaluate(() => window.__pencilTest)
  assert.equal(state.zooms.length, 1)
  assert.ok(state.zooms[0] < 0, 'outward pinch reaches original PDF zoom handler')
  assert.ok(state.created[2].data.points.length >= 2, 'interrupted stroke preserves measured points')
  assert.deepEqual(failures, [])
  await page.evaluate(() => {
    const send = window.dispatchInkFixture
    send('pointerdown', 'pen', 111, 250, 200, 0)
    send('pointermove', 'pen', 111, 250, 200, 0.9)
    send('pointerup', 'pen', 111, 250, 200, 0.9)
  })
  await page.waitForFunction(() => window.__pencilTest.created.length === 4)
  const dot = await page.evaluate(() => window.__pencilTest.created[3])
  assert.deepEqual(dot.data.points.map(p => Math.round(p.p * 100)), [0, 90], 'A dot and stationary pressure are preserved, including the first zero pressure')
  assert.equal(dot.data.inkVersion, 3)
  assert.ok(await page.locator('.ink-layer__mark').last().getAttribute('d'), 'Dots render as visible ink')
  console.log('WebKit: original InkLayer mouse, Pencil sample fixtures, first-zero pressure, dots, stationary pressure, palm ownership, finger pan, pinch and interruption passed')
} finally { await browser.close(); await server.close() }

await import('./navigation-test.mjs')
