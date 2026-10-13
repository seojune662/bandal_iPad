import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createRequire } from 'node:module'
import { dependencies, runtime } from './dependencies.mjs'

const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild'), { webkit } = require('@playwright/test')
const temporary = await mkdtemp(resolve(tmpdir(), 'bandal-keyboard-'))
// Bundle the real shortcut parser and PDF toolbar. No copied shortcut handlers
// or user data: the pre-adapter run must expose their actual TypeErrors.
await build({ absWorkingDir: runtime, bundle: true, format: 'esm', platform: 'browser', target: 'es2022', minify: true,
  jsx: 'automatic', outfile: resolve(temporary, 'fixture.js'), stdin: { resolveDir: runtime, loader: 'tsx', contents: `
import { createRoot } from 'react-dom/client'
import { chordFromKeyboardEvent } from './upstream/src/shared/keymap'
import { PdfToolRail } from './upstream/src/renderer/src/features/pdf/tools/PdfToolRail'
import { usePdfToolStore } from './upstream/src/renderer/src/features/pdf/tools/toolStore'
import { installNativeKeyboardCompatibility } from './renderer/keyboard'
const state = { chords: [], keys: [], textEvents: [], undos: 0, redos: 0, malformedReports: 0, reportArguments: [] }
let dispose = () => {}
window.installCompatibility = () => { dispose(); dispose = installNativeKeyboardCompatibility(window, (...args) => { state.malformedReports++; state.reportArguments.push(args) }) }
window.removeCompatibility = () => dispose()
window.keyboardState = () => ({ ...state, tool: usePdfToolStore.getState().activeTool })
window.addEventListener('keydown', event => {
  state.keys.push({ key: event.key, trusted: event.isTrusted, composing: event.isComposing })
  state.chords.push(chordFromKeyboardEvent(event))
})
for (const type of ['compositionstart', 'compositionupdate', 'compositionend', 'beforeinput', 'input']) {
  document.addEventListener(type, event => state.textEvents.push({ type, data: event.data, composing: event.isComposing, prevented: event.defaultPrevented }))
}
const drawingsApi = { drawings: [], byPage: new Map(), error: null, canUndo: true, canRedo: true,
  undo: async () => { state.undos++ }, redo: async () => { state.redos++ } }
createRoot(document.getElementById('root')).render(<div className="pdf-tab">
  <PdfToolRail courseId="fixture" relPath="fixture.pdf" drawingsApi={drawingsApi} />
  <div id="neutral" tabIndex={0}>Keyboard fixture</div><textarea id="editor" />
</div>)
` } })
const server = createServer(async (request, response) => {
  try {
    if (request.url === '/fixture.js' || request.url === '/fixture.css') {
      response.setHeader('Content-Type', request.url.endsWith('.js') ? 'text/javascript' : 'text/css')
      response.end(await readFile(resolve(temporary, '.' + request.url))); return
    }
    response.setHeader('Content-Type', 'text/html')
    response.end('<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/fixture.css"><div id="root"></div><script type="module" src="/fixture.js"></script>')
  } catch { response.statusCode = 404; response.end() }
})
await new Promise(done => server.listen(0, '127.0.0.1', done))
const browser = await webkit.launch()
try {
  const page = await browser.newPage(), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(`http://127.0.0.1:${server.address().port}/`)
  await page.locator('.pdf-tool-rail').waitFor()
  await page.waitForTimeout(50) // Let the original toolbar's effect subscribe.
  await page.evaluate(() => document.getElementById('neutral').dispatchEvent(new Event('keydown', { bubbles: true, cancelable: true })))
  assert.ok(errors.some(message => message.includes('.trim')), 'The original shared keymap must reproduce undefined.trim')
  assert.ok(errors.some(message => message.includes('.key.toLowerCase')), 'The original PDF tool handler must also reproduce its failure')
  const baseline = errors.length
  await page.evaluate(() => window.installCompatibility())
  const malformed = await page.evaluate(() => {
    const target = document.getElementById('neutral'), before = window.keyboardState().keys.length, results = []
    for (const key of [undefined, null, 3, {}, ['p']]) {
      const event = new Event('keydown', { bubbles: true, cancelable: true })
      if (key !== undefined) Object.defineProperty(event, 'key', { value: key })
      results.push({ dispatched: target.dispatchEvent(event), defaultPrevented: event.defaultPrevented })
    }
    return { before, after: window.keyboardState().keys.length, results }
  })
  assert.equal(malformed.before, malformed.after)
  assert.ok(malformed.results.every(result => result.dispatched && !result.defaultPrevented), 'Do not cancel native default editing')
  assert.equal(errors.length, baseline)
  assert.equal((await page.evaluate(() => window.keyboardState())).malformedReports, 1)
  await page.evaluate(() => { window.installCompatibility(); document.getElementById('neutral').dispatchEvent(new Event('keydown', { bubbles: true })) })
  assert.equal((await page.evaluate(() => window.keyboardState())).malformedReports, 1, 'Even reinstalling the adapter cannot report key data or repeat the diagnostic')
  assert.deepEqual((await page.evaluate(() => window.keyboardState())).reportArguments, [[]])

  await page.locator('#neutral').focus()
  await page.keyboard.press('p')
  assert.equal((await page.evaluate(() => window.keyboardState())).tool, 'pen')
  await page.keyboard.press('h')
  await page.keyboard.press('Meta+z')
  await page.keyboard.press('Meta+Shift+z')
  let state = await page.evaluate(() => window.keyboardState())
  assert.equal(state.tool, 'highlighter'); assert.equal(state.undos, 1); assert.equal(state.redos, 1)
  assert.ok(state.keys.some(event => event.key === 'p' && event.trusted), 'Real WebKit key events must reach the unchanged handlers')
  assert.ok(state.chords.includes('mod+z')); assert.ok(state.chords.includes('mod+shift+z'))
  await page.locator('#editor').fill('')
  await page.locator('#editor').focus(); await page.keyboard.type('actual input')
  assert.equal(await page.locator('#editor').inputValue(), 'actual input')
  await page.evaluate(() => {
    const target = document.getElementById('editor')
    target.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }))
    target.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: '한' }))
    target.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Process', isComposing: true }))
    for (const type of ['beforeinput', 'input']) target.dispatchEvent(new InputEvent(type, { bubbles: true, cancelable: type === 'beforeinput', data: '한', inputType: 'insertCompositionText', isComposing: true }))
    target.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '한' }))
  })
  state = await page.evaluate(() => window.keyboardState())
  assert.ok(state.keys.some(event => event.key === 'Process' && event.composing))
  assert.deepEqual(state.textEvents.filter(event => event.data === '한').map(event => event.type), ['compositionupdate', 'beforeinput', 'input', 'compositionend'])
  assert.ok(state.textEvents.every(event => !event.prevented)); assert.equal(errors.length, baseline)

  // An unrelated renderer failure must still be reported, not swallowed.
  await page.evaluate(() => { setTimeout(() => { throw new TypeError('fixture unrelated renderer failure') }, 0) })
  await page.waitForTimeout(30)
  assert.ok(errors.includes('fixture unrelated renderer failure'))
  const beforeDispose = errors.length
  await page.evaluate(() => { window.removeCompatibility(); document.getElementById('neutral').dispatchEvent(new Event('keydown', { bubbles: true })) })
  assert.ok(errors.length > beforeDispose, 'Removing the adapter restores the original malformed-event behavior')
  const bootstrap = await readFile(resolve(runtime, 'renderer/bootstrap.ts'), 'utf8')
  assert.ok(bootstrap.indexOf('installNativeKeyboardCompatibility(window,') < bootstrap.indexOf("import('../upstream/src/renderer/src/main')"))
  console.log('WebKit keyboard compatibility: original keymap/PDF failures reproduced; malformed keys isolated; trusted shortcuts, native text input, IME and unrelated errors preserved')
} finally { await browser.close(); await new Promise(done => server.close(done)); await rm(temporary, { recursive: true, force: true }) }
