import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import pencil from '../pencil/index.mjs'
import nativePDF from './index.mjs'
const { require } = dependencies()
const { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-native-pointer-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, server: { host: '127.0.0.1', port: 0 },
  plugins: [pencil(), nativePDF(), react()], resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 800, height: 800 }, hasTouch: true })
  const errors = []; page.on('pageerror', error => errors.push(error.message))
  await page.goto(`${server.resolvedUrls.local[0]}renderer/nativePDF/test-fixture.html`)
  await page.waitForFunction(() => window.nativeFixture?.ready)
  const send = async (phase, x, y) => page.evaluate(({ phase, x, y }) => window.nativeFixture.send({ phase, page: 1, points: [{ x, y, p: 0.5 }] }), { phase, x, y })
  await send('down', .1, .1); await send('move', .3, .25)
  await page.waitForFunction(() => window.nativeFixture.state.scenes.some(scene => scene.objects.some(o => o.id === 'native-object-preview')))
  await send('up', .3, .25)
  await page.waitForFunction(() => window.nativeFixture.state.creates === 1)
  await page.evaluate(() => window.nativeFixture.tool('select'))
  await page.waitForTimeout(50)
  await send('down', .1, .16); await send('move', .2, .21); await send('up', .2, .21)
  await page.waitForFunction(() => window.nativeFixture.state.updates === 1)
  let state = await page.evaluate(() => window.nativeFixture.state)
  assert.equal(state.creates, 1)
  assert.ok(Math.abs(state.rows[0].data.box.x - .2) < .002, 'selected shape moves using original normalized model')
  assert.ok(state.scenes.some(scene => scene.selection && scene.resizable), 'native receives original selection frame')
  await page.evaluate(() => window.nativeFixture.undo())
  await page.waitForFunction(() => window.nativeFixture.state.updates === 2)
  state = await page.evaluate(() => window.nativeFixture.state)
  assert.ok(Math.abs(state.rows[0].data.box.x - .1) < .002, 'one undo reverses one manipulation')
  await page.evaluate(() => window.nativeFixture.tool('rect')); await page.waitForTimeout(30)
  await send('down', .5, .2); await send('move', .7, .3); await send('cancel', .7, .3)
  await page.waitForTimeout(30)
  assert.equal(await page.evaluate(() => window.nativeFixture.state.creates), 1, 'cancelled native shape does not create an object')
  // Actual WebKit capture remains active for genuine pointers.
  await page.mouse.move(310, 350); await page.mouse.down(); await page.mouse.move(420, 440, { steps: 3 }); await page.mouse.up()
  await page.waitForFunction(() => window.nativeFixture.state.creates === 2)
  await page.evaluate(() => window.nativeFixture.tool('text')); await page.waitForTimeout(30)
  await send('down', .5, .15); await send('up', .5, .15)
  await page.locator('.ink-layer__textbox-editor').waitFor()
  // Mixed-size native pages and horizontal pinch pan must move the explicit
  // HTML editor with the PDF body while keeping its original text model.
  for (const native of [{ x: -120, y: -210, width: 900, height: 1350 }, { x: 24, y: 32, width: 540, height: 810 }]) {
    const bounds = await page.evaluate(native => window.nativeFixture.align(native), native)
    assert.ok(Math.abs(bounds.after.x-(bounds.viewport.x+native.x+(bounds.before.x-bounds.page.x)/bounds.page.width*native.width)) < 1, JSON.stringify(bounds))
    assert.ok(Math.abs(bounds.after.y-(bounds.viewport.y+native.y+(bounds.before.y-bounds.page.y)/bounds.page.height*native.height)) < 1)
    assert.ok(Math.abs(bounds.after.width-bounds.before.width*native.width/bounds.page.width) < 1)
    await page.evaluate(() => window.nativeFixture.resetAlignment())
  }
  await page.keyboard.type('native text editor')
  await page.keyboard.press('Meta+Enter')
  await page.mouse.click(700, 720)
  await page.waitForFunction(() => window.nativeFixture.state.rows.some(row => row.kind === 'textbox'))
  await page.evaluate(() => window.nativeFixture.tool('select')); await page.waitForTimeout(50)
  await send('down', .52, .165); await send('up', .52, .165)
  await page.waitForTimeout(50)
  await send('down', .52, .165); await send('up', .52, .165)
  await page.locator('.ink-layer__textbox-editor').waitFor()
  await page.waitForFunction(() => document.activeElement?.matches('.ink-layer__textbox-editor [contenteditable="true"]'))
  await page.keyboard.type(' edited')
  await page.keyboard.press('Meta+Enter')
  await page.waitForFunction(() => window.nativeFixture.state.rows.some(row => row.data.text?.includes('edited')))
  await page.reload(); await page.waitForFunction(() => window.nativeFixture?.ready)
  assert.equal(await page.locator('#native-pending-undo').isDisabled(), true)
  await page.evaluate(() => window.nativeFixture.provisional())
  await page.waitForFunction(() => !document.querySelector('#native-pending-undo').disabled)
  assert.equal(await page.evaluate(() => window.nativeFixture.state.creates), 0, 'provisional checkpoint has not entered canonical history')
  await page.locator('#native-pending-undo').click()
  await page.waitForFunction(() => window.nativeFixture.state.deletes === 1)
  state = await page.evaluate(() => window.nativeFixture.state)
  assert.equal(state.creates, 1); assert.equal(state.rows.length, 0, 'Undo first finalizes the latest measured stroke, then removes exactly that stroke')
  await page.locator('#native-pending-redo').click()
  await page.waitForFunction(() => window.nativeFixture.state.rows.length === 1)
  assert.equal(await page.evaluate(() => window.nativeFixture.state.creates), 2)
  await page.reload(); await page.waitForFunction(() => window.nativeFixture?.ready)
  await page.evaluate(() => window.nativeFixture.provisional())
  assert.equal(await page.evaluate(() => window.nativeFixture.state.rows.length), 0)
  await page.locator('#native-pending-export').click()
  await page.waitForFunction(() => window.nativeFixture.state.exports.length === 1)
  state = await page.evaluate(() => window.nativeFixture.state)
  assert.equal(state.creates, 1)
  assert.equal(state.exports[0].length, 1, 'Annotated export cannot run before the provisional stroke reaches the canonical drawing repository')
  assert.equal(state.exports[0][0].data.inkVersion, 2)
  assert.equal(state.exports[0][0].data.points[0].p, 0, 'Export must retain measured zero pressure')
  await page.evaluate(() => window.nativeFixture.deferredGesture([
    { phase: 'down', page: 1, points: [{ x: .3, y: .3, p: .5 }] },
    { phase: 'move', page: 1, points: [{ x: .5, y: .4, p: .5 }] },
    { phase: 'up', page: 1, points: [{ x: .5, y: .4, p: .5 }] }
  ]))
  await page.waitForFunction(() => window.nativeFixture.state.rows.some(row => row.kind === 'rect'))
  const deferred = await page.evaluate(() => window.nativeFixture.state.rows.find(row => row.kind === 'rect'))
  assert.ok(Math.abs(deferred.data.box.x-.3) < .002 && Math.abs(deferred.data.box.width-.2) < .002,
    'One-frame split activation deferral must preserve down → move → up order')
  // The canonical snapshots and the live object editor use the same native
  // payload. Moving another object must not re-expand versioned ink into SVG
  // or lose measured pressure/time/tilt; historical paths stay byte-identical.
  await page.reload(); await page.waitForFunction(() => window.nativeFixture?.ready)
  const strokes = await page.evaluate(async () => {
    const rows = []
    for (const inkVersion of [undefined, 2, 3, 4, 5]) for (const kind of ['ink', 'highlighter']) {
      rows.push(await window.nativeFixture.addDrawing({ courseId: 'course', relPath: 'fixture.pdf', page: 1, kind,
        data: { ...(inkVersion ? { inkVersion } : {}), points: [
          { x: .1, y: .65, p: 0, t: 100, tiltX: 13, tiltY: -7 },
          { x: .2, y: .67, p: .15, t: 104, tiltX: 14, tiltY: -8 },
          { x: .3, y: .65, p: .8, t: 108, tiltX: 15, tiltY: -9 }
        ] }, style: { color: kind === 'ink' ? 'blue' : 'yellow', width: .004, opacity: .4 } }))
    }
    return rows
  })
  await page.waitForFunction(count => window.nativeFixture.state.scenes.some(scene => scene.objects.length === count), strokes.length)
  const assertInkPayload = async () => {
    const native = await page.evaluate(() => ({ snapshots: window.nativeFixture.payloads(),
      scene: window.nativeFixture.state.scenes.at(-1),
      legacy: Object.fromEntries(window.nativeFixture.state.rows.filter(row => !row.data.inkVersion && ['ink', 'highlighter'].includes(row.kind))
        .map(row => [row.id, window.nativeFixture.legacyPath(row)])) }))
    for (const rows of [native.snapshots, native.scene.objects]) for (const original of strokes) {
      const payload = rows.find(row => row.id === original.id)
      assert.ok(payload, `native payload contains ${original.kind} v${original.data.inkVersion ?? 'legacy'}`)
      const { nativePath, ...canonical } = payload
      assert.deepEqual(canonical, original, 'native payload keeps canonical raw samples, style, version and identity unchanged')
      if (original.data.inkVersion) assert.equal(Object.hasOwn(payload, 'nativePath'), false, 'Versioned ink must not expand or transmit an SVG path')
      else { assert.equal(nativePath, native.legacy[original.id]); assert.ok(nativePath.startsWith('M'), 'legacy native SVG remains the original path') }
    }
    return native.scene
  }
  await assertInkPayload()
  await send('down', .5, .2); await send('move', .7, .3); await send('up', .7, .3)
  await page.waitForFunction(count => window.nativeFixture.state.creates === count, strokes.length + 1)
  await page.evaluate(() => window.nativeFixture.tool('select')); await page.waitForTimeout(50)
  await send('down', .5, .25); await send('move', .6, .35); await send('up', .6, .35)
  await page.waitForFunction(() => window.nativeFixture.state.updates === 1)
  let mixedScene = await assertInkPayload()
  assert.ok(mixedScene.resizable && Math.abs(mixedScene.selection.x - .6) < .002, 'selection and live movement still reach native scene beside versioned ink')
  await page.evaluate(() => window.nativeFixture.undo())
  await page.waitForFunction(() => window.nativeFixture.state.updates === 2)
  mixedScene = await assertInkPayload()
  assert.ok(Math.abs(mixedScene.objects.find(row => row.kind === 'rect').data.box.x - .5) < .002, 'undo restores the edited object without changing any ink')
  assert.deepEqual(errors, [])
  console.log('Real WebKit + original InkLayer/useDrawings: object edits, aligned text editor, genuine capture, provisional Undo/Redo, export order and raw v2/v3/v4/v5 native payloads with unchanged legacy paths PASS')
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
