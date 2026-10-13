import assert from 'node:assert/strict'
import { readFile, stat } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'
import { runtime } from './dependencies.mjs'
import { verifyPDFResources } from './pdf-resources.mjs'
const embedded = resolve(runtime, '../App/Resources/Desktop'), native = resolve(runtime, '../App/Resources/DesktopNative')
await verifyPDFResources(embedded)
const hash = value => createHash('sha256').update(value).digest('hex')
const source = await readFile(resolve(runtime, 'backend/dist/backend.js')), bundled = await readFile(resolve(embedded, 'backend.js'))
assert.equal(hash(bundled), hash(source), 'Packaged backend must match the freshly built runtime')
assert.ok(bundled.includes('BandalBackend'), 'Backend global entry missing')
const html = await readFile(resolve(embedded, 'index.html'), 'utf8')
assert.ok(!html.includes('backend.js'), 'Privileged backend must not be loaded into renderer')
for (const match of html.matchAll(/(?:src|href)="(\.\/[^"]+)"/g)) assert.ok((await stat(resolve(embedded, match[1]))).size > 0, 'Missing shell resource')
for (const name of ['pip.html', 'capture.html']) {
  const entry = await readFile(resolve(embedded, name), 'utf8')
  assert.ok(!entry.includes('backend.js'), 'Privileged backend must not be loaded into an auxiliary renderer')
  for (const match of entry.matchAll(/(?:src|href)="(\.\/[^"]+)"/g)) assert.ok((await stat(resolve(embedded, match[1]))).size > 0, `Missing ${name} resource`)
}
const sourceModules = JSON.parse(await readFile(resolve(embedded, 'bundled-source.json'), 'utf8'))
assert.ok(sourceModules.some(name => name.endsWith('/features/overlay/ScreenSelectionApp.tsx')), 'Original desktop region selection UI must ship')
const article = await readFile(resolve(native, 'article-extraction.js'), 'utf8')
assert.ok(article.includes('new Readability(page') && article.includes('maxElemsToParse: 30000') && article.length > 50_000)
const browserAgent = await readFile(resolve(native, 'browser-agent.js'), 'utf8')
assert.ok(browserAgent.includes('__bandalBrowserAgent') && browserAgent.length > 10_000, 'Original isolated browser page driver must ship')
assert.ok((await stat(resolve(native, 'hover-worker.js'))).size > 10_000, 'Original hover preview parsers must ship')
for (const font of ['NotoSansKR-Regular.otf', 'NotoSansKR-Bold.otf']) assert.ok((await stat(resolve(native, 'fonts', font))).size > 1_000_000)
const xcode = await readFile(resolve(runtime, '../project.yml'), 'utf8')
assert.match(xcode, /Resources\/Desktop/); assert.match(xcode, /Resources\/DesktopNative/)
console.log('Packaged full renderer, matching privileged backend, PDF fonts and original article extractor verified')
