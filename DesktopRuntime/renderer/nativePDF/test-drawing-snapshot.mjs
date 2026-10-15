import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
const { require } = dependencies(), ts = require('typescript')
const folder = await mkdtemp(resolve(tmpdir(), 'bandal-drawing-snapshot-'))
const row = (id, pressure = .5) => ({ id, page: 1, kind: 'ink', data: { inkVersion: 4,
  points: Array.from({ length: 96 }, (_, i) => ({ x: .1 + i * .008, y: .2, p: pressure, t: i * 4 })) },
  style: { color: 'blue', width: .003, opacity: .6 } })
const state = n => ({ active: true, loading: false, annotations: [{ id: 'highlight', nativeOpacity: n / 1000 }], tool: { name: 'pen', style: { width: .003 } } })
try {
  const source = await readFile(resolve(runtime, 'renderer/nativePDF/drawingSnapshot.ts'), 'utf8')
  const output = resolve(folder, 'publisher.mjs')
  await writeFile(output, ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText)
  const { NativePDFDrawingSnapshotPublisher: Publisher } = await import(pathToFileURL(output))
  // Apply the actual wire messages with the native revision/order contract.
  const receiver = () => ({ revision: 0, rows: new Map(), order: [], state: null, apply(payload) {
    const p = payload.drawingPatch
    assert.ok(p.reset ? p.baseRevision === 0 && p.revision > this.revision : p.baseRevision === this.revision && p.revision === this.revision + 1)
    const next = p.reset ? new Map() : new Map(this.rows)
    assert.equal(new Set(p.order).size, p.order.length)
    const seen = new Set()
    for (const value of p.upserts) { assert.ok(!seen.has(value.id) && p.order.includes(value.id)); seen.add(value.id); next.set(value.id, value) }
    for (const id of p.order) assert.ok(next.has(id))
    this.rows = new Map(p.order.map(id => [id, next.get(id)])); this.order = p.order; this.revision = p.revision; this.state = payload
  } })
  const accepted = receiver(), calls = [], publisher = new Publisher(async payload => { calls.push(payload); accepted.apply(payload) })
  const drawings = []
  for (let i = 0; i < 200; i++) {
    drawings.push(row(`ink-${i}`))
    await publisher.publish(state(i), drawings)
    assert.equal(calls.at(-1).drawingPatch.upserts.length, 1, `stroke ${i}: only its own 96 raw points cross the bridge`)
    assert.equal(accepted.rows.size, i + 1)
  }
  const before = calls.length
  await publisher.publish(state(201), drawings)
  assert.equal(calls.length, before + 1); assert.equal(calls.at(-1).drawingPatch.upserts.length, 0)
  assert.deepEqual(accepted.state.annotations, state(201).annotations, 'UI state is not lost when no ink changes')
  drawings[10] = row('ink-10', .9)
  await publisher.publish(state(202), drawings)
  assert.deepEqual(calls.at(-1).drawingPatch.upserts.map(value => value.id), ['ink-10'])
  await publisher.publish(state(203), [drawings[2], drawings[0]])
  assert.equal(calls.at(-1).drawingPatch.upserts.length, 0)
  assert.deepEqual(accepted.order, ['ink-2', 'ink-0']); assert.equal(accepted.rows.size, 2)
  await assert.rejects(publisher.publish({}, [row('same'), row('same')]), /중복/)
  await assert.rejects(publisher.publish({}, [{ page: 1 }]), /식별자/)
  assert.deepEqual(accepted.order, ['ink-2', 'ink-0'])

  // Hold the first RPC while many states arrive: there is only one sender,
  // intermediate states disappear, and each caller awaits the latest state.
  let release, started
  const gate = new Promise(resolve => { release = resolve }), entered = new Promise(resolve => { started = resolve })
  const serial = receiver(), serialized = []; let concurrent = 0, maximumConcurrent = 0
  const coalescing = new Publisher(async payload => {
    concurrent++; maximumConcurrent = Math.max(maximumConcurrent, concurrent); serialized.push(payload)
    if (serialized.length === 1) { started(); await gate }
    serial.apply(payload); concurrent--
  })
  const first = coalescing.publish(state(0), [row('first')]); await entered
  const waiting = []
  for (let i = 1; i <= 20; i++) waiting.push(coalescing.publish(state(i), [row('first'), row(`latest-${i}`)]))
  release(); await Promise.all([first, ...waiting])
  assert.equal(maximumConcurrent, 1); assert.equal(serialized.length, 2)
  assert.deepEqual(serial.order, ['first', 'latest-20']); assert.deepEqual(serial.state.annotations, state(20).annotations)

  for (const appliedBeforeFailure of [false, true]) {
    const native = receiver(), sent = []; let fail = true
    const recovery = new Publisher(async payload => {
      sent.push(payload)
      if (fail) { fail = false; if (appliedBeforeFailure) native.apply(payload); throw new Error('unknown snapshot result') }
      native.apply(payload)
    })
    await recovery.publish(state(1), [row('survives')])
    assert.equal(sent.length, 2); assert.equal(sent[1].drawingPatch.reset, true)
    assert.equal(sent[1].drawingPatch.baseRevision, 0); assert.equal(sent[1].drawingPatch.revision, 2)
    assert.deepEqual(native.order, ['survives'])
    await recovery.publish(state(2), [row('survives'), row('next')])
    assert.equal(sent.at(-1).drawingPatch.reset, false); assert.equal(sent.at(-1).drawingPatch.upserts.length, 1)
  }
  let unavailable = true, retries = 0
  const resumed = receiver(), retry = new Publisher(async payload => { retries++; if (unavailable) throw new Error('offline'); resumed.apply(payload) })
  await assert.rejects(retry.publish(state(1), [row('old')]), /offline/)
  assert.equal(retries, 2, 'Automatic retry is bounded')
  unavailable = false; await retry.publish(state(2), [row('new')])
  assert.deepEqual(resumed.order, ['new']); assert.equal(resumed.revision, 3)

  const frozen = [], freeze = new Publisher(async payload => { frozen.push(payload) })
  const changing = row('mutable'), submitted = freeze.publish(state(4), [changing])
  changing.data.points[0].p = .99
  await submitted
  assert.equal(frozen[0].drawingPatch.upserts[0].data.points[0].p, .5, 'Queued raw points are immutable')
  await freeze.publish(state(5), [changing])
  assert.equal(frozen.at(-1).drawingPatch.upserts[0].data.points[0].p, .99, 'Same-reference edits are detected by JSON comparison')

  const legacy = [], oldHost = new Publisher(async payload => { legacy.push(payload) }, false)
  await oldHost.publish(state(8), [row('legacy')])
  assert.equal(legacy[0].drawingPatch, undefined); assert.equal(legacy[0].drawings.length, 1)
  oldHost.dispose(); await oldHost.publish(state(9), []); assert.equal(legacy.length, 1)
  console.log('Drawing snapshots: 200×96 incremental rows, zero-upsert UI updates, correction/delete/reorder, serialized coalescing, unknown-result reset, bounded retry, immutable queue, legacy fallback PASS')
} finally { await rm(folder, { recursive: true, force: true }) }
