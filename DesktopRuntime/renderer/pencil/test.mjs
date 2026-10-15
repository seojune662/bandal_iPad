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
await import('./test-live-preview.mjs')

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
  assert.equal(dot.data.inkVersion, 5)
  assert.ok(await page.locator('.ink-layer__mark').last().getAttribute('d'), 'Dots render as visible ink')
  await page.evaluate(() => window.dispatchInkFixture('pointerdown', 'pen', 120, 50, 190, 0.3))
  // Hold the animation-frame scheduler closed. A measured path must be present
  // before pointermove returns, including after a long coalesced input stream.
  const live = await page.evaluate(async () => {
    const svg = document.querySelector('.ink-layer')
    const originalFrame = window.requestAnimationFrame
    let frameRequests = 0
    window.requestAnimationFrame = () => { frameRequests++; return 1000000 }
    const commits = window.__pencilTest.commits
    const measured = () => [...svg.querySelectorAll('[data-ink-measured]')].map(path => path.getAttribute('d')).join(' ')
    const initial = measured()
    let livePath, firstPath
    const durations = []
    try {
      for (let batch = 0; batch < 80; batch++) {
        const samples = Array.from({ length: 8 }, (_, offset) => {
          const i = batch * 8 + offset
          return [55 + i * 0.7, 195 + Math.sin(i / 12) * 30, 0.2 + (i % 8) * 0.1]
        })
        const last = samples.at(-1)
        const start = performance.now()
        window.dispatchInkFixture('pointermove', 'pen', 120, ...last, samples)
        durations.push(performance.now() - start)
        if (batch === 5) {
          livePath = svg.querySelector('[data-ink-measured]')
          // Exclude the mutable trailing segment; these first pieces have future measured neighbors.
          firstPath = livePath.getAttribute('d').split(' Z ').slice(0, 12).join(' Z ') + ' Z'
        }
      }
      // Yield beyond React's scheduler as well: live movement must not rerender
      // the page, even though the browser can paint the immediate SVG changes.
      await new Promise(resolve => setTimeout(resolve, 30))
      return { initial, measured: measured(), frameRequests,
        commits: window.__pencilTest.commits - commits,
        stablePrefix: livePath === svg.querySelector('[data-ink-measured]') && livePath.getAttribute('d').startsWith(firstPath),
        paths: svg.querySelectorAll('[data-ink-measured]').length,
        durations }
    } finally { window.requestAnimationFrame = originalFrame }
  })
  assert.ok(live.initial.length > 0, 'The first Pencil contact is visible in the input event')
  assert.notEqual(live.measured, live.initial, 'Measured ink updates while animation frames are blocked')
  assert.equal(live.frameRequests, 0, 'Freehand input must not wait for requestAnimationFrame')
  assert.equal(live.commits, 0, 'Moving a live stroke must not rerender InkLayer through React')
  assert.ok(live.stablePrefix, 'The measured geometry prefix remains unchanged as the stroke grows')
  assert.equal(live.paths, 1, 'Measured and predicted geometry share one fill and one coverage mask')
  await page.evaluate(() => {
    const i = 639
    window.dispatchInkFixture('pointerup', 'pen', 120, 55 + i * 0.7, 195 + Math.sin(i / 12) * 30, 0.2 + (i % 8) * 0.1)
  })
  await page.waitForFunction(() => window.__pencilTest.created.length === 5)
  assert.equal(await page.locator('.ink-layer__mark').last().getAttribute('d'), live.measured,
    'The incremental preview is exactly the canonical committed v5 path')
  assert.equal(await page.locator('[data-ink-measured]').count(), 0, 'Ending the stroke removes its transient preview')

  // Predictions may extend the live tail, but are replaced on the next event
  // and never enter the committed source points, including pointercancel.
  const prediction = await page.evaluate(() => {
    const svg = document.querySelector('.ink-layer')
    window.dispatchInkFixture('pointerdown', 'pen', 121, 70, 230, 0.5)
    const event = new PointerEvent('pointermove', { bubbles: true, pointerType: 'pen', pointerId: 121, clientX: 100, clientY: 230, pressure: 0.5 })
    const predictedEvent = (x, delta, pointerId = 121) => {
      const predicted = new PointerEvent('pointermove', { pointerType: 'pen', pointerId, clientX: x, clientY: 230, pressure: 0.5 })
      Object.defineProperty(predicted, 'timeStamp', { value: event.timeStamp + delta })
      return predicted
    }
    Object.defineProperty(event, 'getPredictedEvents', { value: () => [
      predictedEvent(105, -1), predictedEvent(110, 4), predictedEvent(120, 8),
      predictedEvent(900, 12, 999), predictedEvent(950, 1000)
    ] })
    svg.dispatchEvent(event)
    const measured = svg.querySelector('[data-ink-measured]').getAttribute('d')
    const predicted = svg.querySelector('[data-ink-prediction]').getAttribute('d')
    window.dispatchInkFixture('pointermove', 'pen', 121, 102, 233, 0.6)
    const cleared = svg.querySelector('[data-ink-prediction]') === null
    window.dispatchInkFixture('pointercancel', 'pen', 121, 102, 233, 0.6)
    return { measured, predicted, cleared }
  })
  assert.ok(prediction.predicted.length > 0)
  assert.ok(prediction.cleared, 'Each input replaces rather than accumulates prediction tails')
  await page.waitForFunction(() => window.__pencilTest.created.length === 6)
  const predictedStroke = await page.evaluate(() => window.__pencilTest.created[5])
  assert.equal(predictedStroke.data.points.length, 3, 'Only the three measured points survive cancellation')
  await page.waitForFunction(() => document.querySelectorAll('.ink-layer__mark').length === 6)
  assert.equal(await page.locator('[data-ink-prediction]').count(), 0)
  const handoff = await page.evaluate(async () => (await import('/renderer/pencil/handoff-fixture.tsx')).runHandoffFixture())
  console.log(handoff)
  console.log(await page.evaluate(async () => (await import('/renderer/pencil/raster-fixture.ts')).verifyPreviewCoverage()))
  assert.deepEqual(failures, [])
  const sorted = [...live.durations].sort((a, b) => a - b)
  console.log(`WebKit live ink: 640 measured samples, 1 canonical compound path, 0 queued frames, 0 React commits, exact saved geometry; 8-sample event median ${sorted[40].toFixed(2)}ms, p95 ${sorted[76].toFixed(2)}ms (synthetic host timings, not device latency)`)
  console.log('WebKit: original InkLayer mouse, Pencil sample fixtures, first-zero pressure, dots, stationary pressure, palm ownership, finger pan, pinch and interruption passed')
} finally { await browser.close(); await server.close() }

await import('./navigation-test.mjs')
