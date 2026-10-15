import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import vm from 'node:vm'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import { adaptInputSource } from './index.mjs'

// Run the production lifecycle after its iPad build transform. Only the
// original writer modules are injected, so their attempts and rejected values
// can be observed without retrying an uncertain mutation or changing storage.
const ts = dependencies().require('typescript')
const file = resolve(runtime, 'renderer/lifecycle.ts')
const source = adaptInputSource(await readFile(file, 'utf8'), file).code
const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText
const noteError = new Error('original note writer rejected'), layoutError = new Error('original layout writer rejected')

for (const note of ['saved', 'conflict', 'reject']) for (const layout of ['saved', 'pending', 'reject']) {
  const attempts = { notes: 0, ink: 0, layout: 0 }
  const notes = {
    readOpenNoteSnapshots: () => [{ courseId: 'course', relPath: 'note.md', markdown: 'unsaved value' }],
    async flushOpenNoteSession() {
      attempts.notes++
      if (note === 'reject') throw noteError
      return { result: { status: note } }
    }
  }
  const ink = { nativeInkRevision: () => 0, async flushNativeInk() { attempts.ink++; return { ok: true, pending: [] } } }
  const context = { exports: {}, window: {}, require(name) {
    if (name.endsWith('noteSessionRegistry')) return notes
    if (name.endsWith('pencil/persistence')) return ink
    if (name.endsWith('workspacePersistence.ts')) return { async flushIPadWorkspaceLayout() {
      attempts.layout++
      if (layout === 'reject') throw layoutError
      return layout === 'saved'
    } }
    throw new Error(`Unexpected lifecycle dependency ${name}`)
  } }
  vm.runInNewContext(code, context)
  context.exports.installNativeLifecycle()
  let report, failure
  try { report = await context.window.__bandalFlushNative() } catch (error) { failure = error }
  assert.equal(attempts.layout, 1, `${note}/${layout}: layout receives exactly one attempt even after document failure`)
  assert.equal(attempts.notes, note === 'saved' ? 2 : 1, 'The original stable-note verification remains unchanged; rejected writes are not replayed')
  assert.equal(attempts.ink, note === 'saved' ? 1 : 0, 'The original document/ink phase semantics remain unchanged')
  if (note === 'reject' || layout === 'reject') {
    assert.equal(failure, note === 'reject' ? noteError : layoutError, 'Preserve the first actual rejection object')
    assert.equal(report, undefined)
  } else {
    assert.equal(failure, undefined)
    assert.equal(report.ok, note === 'saved' && layout === 'saved')
    assert.deepEqual(JSON.parse(JSON.stringify(report.pending)), [
      ...(note === 'conflict' ? [{ courseId: 'course', relPath: 'note.md', status: 'conflict' }] : []),
      ...(layout === 'pending' ? [{ courseId: '', relPath: '', status: 'layout-save' }] : [])
    ], 'Document and layout pending information must both survive a combined failure')
  }
}
console.log('PASS independent document/layout save attempts, merged pending reports and first-rejection identity without uncertain-write replay')
