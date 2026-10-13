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
  await page.waitForFunction(() => window.scribbleTrace.regions.at(-1).editors.length === 1)
  await page.getByRole('button', { name: '펜', exact: true }).click()
  await page.waitForFunction(() => window.scribbleTrace.regions.at(-1).editors.length === 0)
  await page.getByRole('textbox', { name: 'normal search' }).fill('normal input')
  assert.equal(await page.getByRole('textbox', { name: 'normal search' }).inputValue(), 'normal input')
  const logs = JSON.stringify(await page.evaluate(() => window.scribbleTrace.regions))
  assert.ok(!logs.includes('intentional text') && !logs.includes('normal input'))
  assert.deepEqual(errors, [])
  console.log('PASS: real PDF toolbar repeated Pencil fixtures, no accidental textboxes, text-tool-only edits, late-input rejection, regular search and geometry-only native policy')
} finally { await browser.close(); await server.close() }
