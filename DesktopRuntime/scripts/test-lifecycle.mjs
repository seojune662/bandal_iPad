import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import vm from 'node:vm'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies(), ts = require('typescript')
const source = await readFile(resolve(runtime, 'renderer/lifecycle.ts'), 'utf8')
const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText
const context = { exports: {}, window: {} }; vm.runInNewContext(code, context)
const { flushNativeNotes } = context.exports
let markdown = 'one', calls = 0, written = ''
const registry = { readOpenNoteSnapshots: () => [{ courseId: 'course', relPath: 'note.md', markdown }], async flushOpenNoteSession() { written = markdown; calls++; if (calls === 1) { await Promise.resolve(); markdown = 'edited while saving' }; return { result: { status: 'saved' } } } }
assert.equal((await flushNativeNotes(registry)).ok, true); assert.equal(calls, 2); assert.equal(written, markdown)
assert.equal((await flushNativeNotes({ ...registry, async flushOpenNoteSession() { return { result: { status: 'conflict' } } } })).pending[0].status, 'conflict')
calls = 0
const active = await flushNativeNotes({ ...registry, async flushOpenNoteSession() { calls++; markdown += '.'; return { result: { status: 'saved' } } } })
assert.equal(active.ok, false); assert.equal(active.pending[0].status, 'editing'); assert.equal(calls, 8)
await assert.rejects(flushNativeNotes({ ...registry, async flushOpenNoteSession() { throw new Error('disk full') } }), /disk full/)
console.log('Native lifecycle: concurrent edit retries, conflict retention, bounded active input and disk errors passed')

const { flushNativeWorkspace } = context.exports
let inkRevision = 0, inkFlushes = 0, noteFlushes = 0
const crossed = { readOpenNoteSnapshots: () => [{ courseId: 'course', relPath: 'note.md', markdown }], async flushOpenNoteSession() { noteFlushes++; if (noteFlushes === 2) inkRevision++; written = markdown; return { result: { status: 'saved' } } } }
const drawing = { nativeInkRevision: () => inkRevision, async flushNativeInk() { inkFlushes++; if (inkFlushes === 1) markdown = 'edited while ink saved'; return { ok: true, pending: [] } } }
assert.equal((await flushNativeWorkspace(crossed, drawing)).ok, true)
assert.equal(inkFlushes, 2); assert.equal(written, markdown)
const inkFailure = await flushNativeWorkspace(registry, { nativeInkRevision: () => 0, async flushNativeInk() { return { ok: false, pending: [{ courseId: 'course', relPath: 'pdf.pdf', status: 'error' }] } } })
assert.equal(inkFailure.ok, false); assert.equal(inkFailure.pending[0].relPath, 'pdf.pdf')
console.log('Native workspace lifecycle: cross-editor changes and failed ink queue prevent premature process release')
