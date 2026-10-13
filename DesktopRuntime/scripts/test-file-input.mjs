import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { dependencies, runtime } from './dependencies.mjs'

const { require } = dependencies()
const { chromium, webkit } = require('@playwright/test')
const ts = require('typescript')
const javascript = ts.transpileModule(await readFile(resolve(runtime, 'renderer/fileInput.ts'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
}).outputText
for (const engine of [chromium, webkit]) {
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  const browser = await engine.launch(engine === chromium && existsSync(chrome) ? { executablePath: chrome } : {})
  try {
    const page = await browser.newPage()
    await page.setContent('<input id="pick" type="file"><div id="drop">drop target</div>')
    await page.evaluate(() => {
      window.__bandalFilePaths = new WeakMap()
      window.testState = { calls: [], changes: [], drops: [], errors: [], fail: false, releaseOld: null, sessions: {}, cancelled: [], finished: [], maxChunk: 0 }
      window.webkit = { messageHandlers: { bandal: { async postMessage(call) {
        window.testState.calls.push(call)
        const state = window.testState, request = call.request
        if (call.channel === 'runtime:stageFileCancel') { delete state.sessions[request.id]; state.cancelled.push(request.id); return { ok: true } }
        if (call.channel === 'runtime:stageFileBegin') {
          const id = request.name; state.sessions[id] = { size: request.size, offset: 0 }
          if (request.name === 'old.pdf') await new Promise(resolve => { state.releaseOld = resolve })
          return { id }
        }
        if (call.channel === 'runtime:stageFileWrite') {
          if (state.fail) throw new Error('Native disk full')
          const session = state.sessions[request.id], size = atob(request.data).length
          if (request.offset !== session.offset || size > 256 * 1024) throw new Error('Invalid chunk')
          state.maxChunk = Math.max(state.maxChunk, size); session.offset += size
          return { offset: session.offset }
        }
        if (call.channel === 'runtime:stageFileFinish') {
          if (state.sessions[request.id].offset !== state.sessions[request.id].size) throw new Error('Incomplete file')
          state.finished.push(request.id); return { path: `/Temporary/Imports/fixture/${request.id}` }
        }
        throw new Error('Unexpected channel ' + call.channel)
      } } } }
    })
    await page.addScriptTag({ content: `(() => { const exports = {}; ${javascript}; exports.installFileInputAdapter(error => window.testState.errors.push(String(error))); })()` })
    await page.evaluate(() => {
      document.querySelector('#pick').addEventListener('change', event => {
        const file = event.target.files[0]
        window.testState.changes.push({ name: file.name, path: window.__bandalFilePaths.get(file) })
      })
      document.querySelector('#drop').addEventListener('drop', event => {
        event.preventDefault()
        const file = event.dataTransfer.files[0]
        window.testState.drops.push({ name: file.name, path: window.__bandalFilePaths.get(file), custom: event.dataTransfer.getData('application/x-fixture'), x: event.clientX })
      })
    })
    await page.locator('#pick').setInputFiles({ name: '선택.pdf', mimeType: 'application/pdf', buffer: Buffer.from([0, 1, 254, 255]) })
    await page.waitForFunction(() => window.testState.changes.length === 1)
    let state = await page.evaluate(() => window.testState)
    assert.equal(state.calls[0].channel, 'runtime:stageFileBegin')
    assert.equal(state.calls[1].request.data, 'AAH+/w==')
    assert.equal(state.changes[0].path, '/Temporary/Imports/fixture/선택.pdf')
    await page.evaluate(() => {
      const transfer = new DataTransfer()
      transfer.items.add(new File(['drag-data'], 'drop.md', { type: 'text/markdown' }))
      transfer.setData('application/x-fixture', 'preserved')
      document.querySelector('#drop').dispatchEvent(new DragEvent('drop', { dataTransfer: transfer, bubbles: true, cancelable: true, clientX: 33 }))
    })
    await page.waitForFunction(() => window.testState.drops.length === 1)
    state = await page.evaluate(() => window.testState)
    assert.deepEqual(state.drops[0], { name: 'drop.md', path: '/Temporary/Imports/fixture/drop.md', custom: 'preserved', x: 33 })
    await page.locator('#pick').setInputFiles({ name: 'old.pdf', mimeType: 'application/pdf', buffer: Buffer.from('old') })
    await page.waitForFunction(() => !!window.testState.releaseOld)
    await page.locator('#pick').setInputFiles({ name: 'new.pdf', mimeType: 'application/pdf', buffer: Buffer.from('new') })
    await page.waitForFunction(() => window.testState.changes.some(change => change.name === 'new.pdf'))
    await page.evaluate(() => window.testState.releaseOld())
    await page.waitForTimeout(40)
    state = await page.evaluate(() => window.testState)
    assert.equal(state.changes.filter(change => change.name === 'old.pdf').length, 0)
    assert.ok(state.cancelled.includes('old.pdf'))
    await page.evaluate(() => { window.testState.fail = true })
    await page.locator('#pick').setInputFiles({ name: 'rejected.pdf', mimeType: 'application/pdf', buffer: Buffer.from('not saved') })
    await page.waitForFunction(() => window.testState.errors.length === 1)
    state = await page.evaluate(() => window.testState)
    assert.equal(state.changes.filter(change => change.name === 'rejected.pdf').length, 0)
    assert.match(state.errors[0], /Native disk full/)
    assert.ok(state.cancelled.includes('rejected.pdf'))
    await page.evaluate(() => { window.testState.fail = false; File.prototype.arrayBuffer = () => { throw new Error('Whole file reads are forbidden') } })
    await page.locator('#pick').setInputFiles({ name: 'large.pdf', mimeType: 'application/pdf', buffer: Buffer.alloc(12 * 1024 * 1024 + 17, 71) })
    await page.waitForFunction(() => window.testState.changes.some(change => change.name === 'large.pdf'))
    state = await page.evaluate(() => window.testState)
    const chunks = state.calls.filter(call => call.channel === 'runtime:stageFileWrite' && call.request.id === 'large.pdf')
    assert.equal(chunks.length, 49)
    assert.equal(state.maxChunk, 256 * 1024)
    assert.equal(state.sessions['large.pdf'].offset, 12 * 1024 * 1024 + 17)
    // A batch's earlier completed file must be released if a later file fails.
    await page.evaluate(() => {
      const original = window.webkit.messageHandlers.bandal.postMessage
      window.webkit.messageHandlers.bandal.postMessage = async call => {
        if (call.channel === 'runtime:stageFileWrite' && call.request.id === 'batch-fail.pdf') throw new Error('Native disk full in batch')
        return original(call)
      }
      const transfer = new DataTransfer()
      transfer.items.add(new File(['okay'], 'batch-ok.pdf')); transfer.items.add(new File(['fail'], 'batch-fail.pdf'))
      document.querySelector('#drop').dispatchEvent(new DragEvent('drop', { dataTransfer: transfer, bubbles: true, cancelable: true }))
    })
    await page.waitForFunction(() => window.testState.errors.length === 2)
    state = await page.evaluate(() => window.testState)
    assert.ok(state.cancelled.includes('batch-ok.pdf')); assert.ok(state.cancelled.includes('batch-fail.pdf'))
    assert.equal(state.drops.length, 1)
    console.log(`${engine.name()}: bounded 12MiB chunks without whole-file reads, bytes, change/drop replay, stale cleanup and failed-batch cleanup passed`)
  } finally { await browser.close() }
}
