import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
import pencilPlugin from './index.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const server = await createServer({ configFile: false, root: runtime, plugins: [pencilPlugin(), react()], server: { host: '127.0.0.1', port: 0 }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1024, height: 900 } }), errors = []
  page.on('pageerror', e => errors.push(e.message))
  await page.goto(server.resolvedUrls.local[0] + 'renderer/pencil/scribble-fixture.html')
  await page.locator('.ink-layer').waitFor()
  await page.getByRole('button', { name: '주석 도구', exact: true }).click()
  const jump = page.getByRole('textbox', { name: '페이지 이동', exact: true })
  await jump.fill('12'); await jump.press('Enter')
  assert.ok((await page.evaluate(() => window.scribbleTrace.jumped)).includes(12), 'The original PDF page field remains editable')
  const jumpBounds = await jump.boundingBox()
  await page.waitForFunction(box => {
    const value = window.scribbleTrace.regions.at(-1), x = box.x + box.width / 2, y = box.y + box.height / 2
    const contains = rect => rect.x <= x && rect.x + rect.width > x && rect.y <= y && rect.y + rect.height > y
    return value?.editors.some(contains) && !value.controls.some(contains)
  }, jumpBounds)
  // These are deterministic fixtures, not physical Pencil or Scribble tests.
  for (const label of ['펜', '형광펜', '지우개', '텍스트']) {
    const button = page.getByRole('button', { name: label, exact: true })
    await button.evaluate((element, label) => {
      for (let i = 0; i < 100; i++) {
        const box = element.getBoundingClientRect()
        for (const type of ['pointerdown', 'pointerup']) element.dispatchEvent(new PointerEvent(type, { pointerType: 'pen', pointerId: i + 100, clientX: box.x + 10, clientY: box.y + 10, bubbles: true, cancelable: true }))
      }
    }, label)
  }
  assert.equal((await page.evaluate(() => window.scribbleTrace.created)).length, 0)
  assert.equal(await page.locator('.ink-layer__textbox-editor').count(), 0, 'Toolbar presses cannot create text boxes')
  // The actual original palette is a portal outside the toolbar. Previously
  // its class did not match the protection selector at all.
  await page.getByRole('button', { name: '필기 스타일', exact: true }).click()
  const popover = page.getByRole('dialog', { name: '필기 스타일' })
  await popover.waitFor()
  const paletteBounds = await popover.boundingBox()
  await page.waitForFunction(box => window.scribbleTrace.regions.at(-1)?.controls.some(rect =>
    Math.abs(rect.x-box.x) < 1 && Math.abs(rect.y-box.y) < 1 && Math.abs(rect.width-box.width) < 1), paletteBounds)
  const paletteResult = await popover.locator('button[data-color="red"]').evaluate(element => {
    let clicks = 0, moves = 0
    element.addEventListener('click', () => clicks++)
    element.addEventListener('pointermove', () => moves++)
    const box = element.getBoundingClientRect(), options = { pointerType: 'pen', pointerId: 77, clientX: box.x+box.width/2, clientY: box.y+box.height/2, bubbles: true, cancelable: true }
    const events = ['pointerdown', 'pointermove', 'pointerup'].map(type => new PointerEvent(type, options))
    for (const event of events) element.dispatchEvent(event)
    return { prevented: events.every(event => event.defaultPrevented), clicks, moves }
  })
  assert.deepEqual(paletteResult, { prevented: true, clicks: 1, moves: 0 }, 'A palette Pencil gesture belongs to its button for its whole lifetime')
  assert.equal(await popover.locator('button[data-color="red"]').getAttribute('aria-pressed'), 'true')
  await page.getByRole('button', { name: '필기 스타일', exact: true }).click()
  await page.getByRole('button', { name: '펜', exact: true }).click()
  const blocked = await page.locator('.ink-layer').evaluate(layer => {
    const field = document.createElement('div'); field.contentEditable = 'true'; layer.append(field)
    const event = new InputEvent('beforeinput', { inputType: 'insertText', data: 'unintended handwriting', bubbles: true, cancelable: true })
    field.dispatchEvent(event); field.remove(); return event.defaultPrevented
  })
  assert.equal(blocked, true, 'Late handwriting input must be rejected after selecting pen')
  await page.getByRole('button', { name: '텍스트', exact: true }).click()
  await page.locator('.ink-layer').click({ position: { x: 160, y: 180 } })
  const editor = page.locator('.ink-layer__textbox-editor [contenteditable="true"]')
  await editor.waitFor()
  await editor.fill('intentional text')
  await page.waitForFunction(() => window.scribbleTrace.regions.at(-1).editors.length === 2)
  const beforeProjection = await editor.boundingBox()
  await editor.evaluate(element => {
    const object = element.closest('foreignObject')
    object.setAttribute('transform', 'translate(.12 .05) ' + object.getAttribute('transform'))
  })
  const projected = await editor.boundingBox()
  assert.ok(Math.abs(projected.x-beforeProjection.x) > 20)
  await page.waitForFunction(box => window.scribbleTrace.regions.at(-1).editors.some(rect => Math.abs(rect.x-box.x)<1 && Math.abs(rect.y-box.y)<1), projected)
  await page.getByRole('button', { name: '펜', exact: true }).click()
  await page.waitForFunction(() => window.scribbleTrace.regions.at(-1).editors.length === 1)
  await page.getByRole('button', { name: '선택', exact: true }).click()
  await page.locator('.ink-layer__textbox-hit-target').dblclick()
  await editor.waitFor()
  await page.keyboard.type(' keyboard edit')
  assert.ok((await editor.textContent()).includes('keyboard edit'), 'Selecting an existing text object retains ordinary keyboard editing')
  await page.waitForFunction(() => window.scribbleTrace.regions.at(-1).editors.length === 1)
  const selectedBounds = await editor.boundingBox()
  assert.equal(await page.evaluate(box => window.scribbleTrace.regions.at(-1).editors.some(rect => {
    const x = box.x + box.width/2, y = box.y + box.height/2
    return rect.x <= x && rect.x+rect.width > x && rect.y <= y && rect.y+rect.height > y
  }), selectedBounds), false, 'A select-tool keyboard editor does not opt into Pencil text conversion')
  await page.getByRole('textbox', { name: 'normal search' }).fill('normal input')
  assert.equal(await page.getByRole('textbox', { name: 'normal search' }).inputValue(), 'normal input')
  const logs = JSON.stringify(await page.evaluate(() => window.scribbleTrace.regions))
  assert.ok(!logs.includes('intentional text') && !logs.includes('normal input'))
  assert.deepEqual(errors, [])
  console.log('PASS: original PDF toolbar/palette Pencil ownership, page input/search, projected text-tool Scribble exceptions, selection keyboard editing, late-input rejection and geometry-only policy')
} finally { await browser.close(); await server.close() }
