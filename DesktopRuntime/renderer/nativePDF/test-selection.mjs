import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createRequire } from 'node:module'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
const { require } = dependencies(), esbuild = createRequire(require.resolve('vite'))('esbuild')
const folder = await mkdtemp(join(tmpdir(), 'bandal-native-selection-'))
try {
  await esbuild.build({ entryPoints: [resolve(runtime, 'renderer/nativePDF/nativeSelection.ts')], bundle: true, platform: 'node', format: 'esm', outfile: join(folder, 'selection.mjs'), logLevel: 'silent' })
  const { resolveNativeSelectionAnchor: resolveAnchor } = await import(pathToFileURL(join(folder, 'selection.mjs')))
  const item = (str, x, y, hasEOL = false) => ({ str, dir: 'ltr', width: str.length * 10, height: 20, transform: [20, 0, 0, 20, x, y], fontName: 'font', hasEOL })
  const viewport = { width: 400, height: 400, convertToViewportPoint: (x, y) => [x, 400 - y] }
  function document(items, view = viewport) {
    let extractions = 0
    return { numPages: 1, async getPage() { return { getViewport: () => view, async getTextContent() { extractions++; return { items, styles: { font: { ascent: .8 } } } } } }, get extractions() { return extractions } }
  }
  const repeated = document([item('Alpha repeated first', 10, 350, true), item('Beta repeated last', 10, 200)])
  const second = await resolveAnchor(repeated, { page: 1, quote: 'repeated', rects: [{ x: .15, y: .46, width: .2, height: .05 }] })
  assert.ok(second.prefix.endsWith('\nBeta '), 'repeated phrases must use selection geometry instead of the first occurrence')
  assert.equal(second.suffix, ' last'); assert.equal(second.quote, 'repeated')
  await resolveAnchor(repeated, { page: 1, quote: 'Alpha', rects: [] })
  assert.equal(repeated.extractions, 1, 'successive selections share only this PDF document page extraction')
  assert.deepEqual(await resolveAnchor(repeated, { page: 1, quote: 'repeated', rects: [] }), { quote: 'repeated', prefix: '', suffix: '' }, 'ambiguous geometry cannot invent the first context')
  const whitespace = document([item('앞😀 Hello ', 10, 350, true), item('   world 뒤', 10, 300)])
  const anchor = await resolveAnchor(whitespace, { page: 1, quote: 'Hello\nworld', rects: [] })
  assert.equal(anchor.quote, 'Hello\nworld'); assert.equal(anchor.prefix, '앞😀 '); assert.equal(anchor.suffix, ' 뒤')
  // PDF.js viewport owns rotated CropBox transforms, exactly like desktop.
  const rotated = document([item('Alpha repeated first', 40, 360, true), item('Beta repeated last', 40, 210)],
    { width: 400, height: 400, convertToViewportPoint: (x, y) => [y - 10, x - 30] })
  const rotatedAnchor = await resolveAnchor(rotated, { page: 1, quote: 'repeated', rects: [{ x: .49, y: .15, width: .05, height: .2 }] })
  assert.ok(rotatedAnchor.prefix.endsWith('\nBeta '))
  assert.deepEqual(await resolveAnchor(whitespace, { page: 1, quote: 'missing', rects: [] }), { quote: 'missing', prefix: '', suffix: '' })
  const unavailable = { numPages: 1, async getPage() { throw new Error('PDF replaced') } }
  assert.deepEqual(await resolveAnchor(unavailable, { page: 1, quote: 'keep selection', rects: [] }), { quote: 'keep selection', prefix: '', suffix: '' })
  assert.deepEqual(await resolveAnchor(whitespace, { page: 2, quote: 'wrong page', rects: [] }), { quote: 'wrong page', prefix: '', suffix: '' })
  console.log('Native PDF contextual anchors: repeated text, UTF-16/whitespace, rotated CropBox, bounded extraction and failure fallback PASS')
} finally { await rm(folder, { recursive: true, force: true }) }
