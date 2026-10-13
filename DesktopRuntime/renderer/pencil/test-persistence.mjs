import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
import pencilPlugin, { transformDrawingPersistence, transformCanvasPersistence, transformCanvasQueue } from './index.mjs'

const { require } = dependencies()
const { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
for (const [path, transform] of [
  ['pdf/tools/useDrawings.ts', transformDrawingPersistence],
  ['canvas/CanvasTab.tsx', transformCanvasPersistence],
  ['canvas/canvasSaveQueue.ts', transformCanvasQueue]
]) {
  const source = await readFile(resolve(runtime, 'upstream/src/renderer/src/features', path), 'utf8')
  assert.ok(transform(source).includes('persistence.ts'))
}
const server = await createServer({ configFile: false, root: runtime, server: { host: '127.0.0.1', port: 0 },
  plugins: [pencilPlugin(), react()], resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage()
  const failures = []; page.on('pageerror', error => failures.push(error.message))
  await page.goto(`${server.resolvedUrls.local[0]}renderer/pencil/test-fixture.html`)
  const passes = await page.evaluate(async () => (await import('/renderer/pencil/persistence-fixture.tsx')).runPersistenceFixture())
  assert.deepEqual(failures, [])
  for (const pass of passes) console.log(`PASS ${pass}`)
} finally { await browser.close(); await server.close() }
