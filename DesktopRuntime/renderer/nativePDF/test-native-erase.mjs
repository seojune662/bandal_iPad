import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'

const { require } = dependencies(), ts = require('typescript')
const temporary = await mkdtemp(join(tmpdir(), 'bandal-native-erase-'))
const revision = 'a'.repeat(64)
const identity = { surfaceId: 'synthetic', generation: 'generation-one', courseId: 'course', relPath: 'fixture.pdf' }
const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`
const stroke = (sequence, n = sequence) => ({ type: 'stroke', operationSequence: sequence,
  courseId: identity.courseId, relPath: identity.relPath, page: 1, documentRevision: revision,
  clientMutationId: uuid(n), kind: 'ink', data: { inkVersion: 4, points: [{ x: -0, y: .2, p: .7, t: 0 }] },
  style: { color: 'ink', width: .003, opacity: 1 } })
const erase = (sequence, targets = [{ drawingId: 'old-row' }], n = sequence) => ({ type: 'eraseCommit',
  operationId: uuid(1000 + n), operationSequence: sequence, originToolEpoch: 4, page: 1,
  documentRevision: revision, targets })
const gate = () => { let release; const promise = new Promise(resolve => { release = resolve }); return { promise, release } }
const turn = () => new Promise(resolve => setImmediate(resolve))
let groups = 0
const pass = text => { groups++; console.log(`PASS ${text}`) }

try {
  const sources = await Promise.all(['operationDigest.ts', 'types.ts', 'session.ts'].map(name => readFile(resolve(runtime, 'renderer/nativePDF', name), 'utf8')))
  await writeFile(join(temporary, 'module.mjs'), ts.transpileModule(sources.map(source => source.replace(/^import .*$/gm, '')).join('\n'),
    { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText)
  const { NativePDFSession } = await import(pathToFileURL(join(temporary, 'module.mjs')))
  function fixture({ remove = async () => true, create = async input => ({ ...input, id: `saved-${input.clientMutationId}` }), response, failResult = 0, wrongResult = 0, failStrokeAck = 0 } = {}) {
    const calls = [], pending = new Map(), replies = []
    let through = 0
    const transport = { on: () => () => {}, async invoke(channel, payload) {
      assert.equal(payload.surfaceId, identity.surfaceId); assert.equal(payload.generation, identity.generation)
      calls.push({ channel, payload })
      if (channel === 'pdfNative:mutationStatus') return { status: 'missing' }
      if (channel === 'pdfNative:ack') {
        for (const [sequence, operation] of pending) if (operation.type === 'stroke' && operation.clientMutationId === payload.clientMutationId) pending.delete(sequence)
        if (failStrokeAck-- > 0) throw new Error('lost stroke ACK')
      }
      if (channel === 'pdfNative:eraseResult') {
        replies.push(payload); pending.delete(payload.operationSequence)
        if (failResult-- > 0) throw new Error('lost result ACK')
        if (wrongResult-- > 0) return { operationId: payload.operationId, operationSequence: payload.operationSequence + 1, outcome: payload.outcome }
        return { operationId: payload.operationId, operationSequence: payload.operationSequence, outcome: payload.outcome }
      }
      if (channel === 'pdfNative:flush') return response ? response() : { pending: [], pendingOperations: [...pending.values()], throughOperationSequence: through }
      return {}
    } }
    const writer = { async create(input) { calls.push({ channel: 'writer.create', payload: input }); return create(input) },
      async remove(ids) { calls.push({ channel: 'writer.remove', payload: ids }); return remove(ids) },
      async flush() { calls.push({ channel: 'writer.flush' }) } }
    const session = new NativePDFSession(identity, transport, writer)
    session.configureNativeErase(true, revision)
    const offer = operation => { pending.set(operation.operationSequence, operation); through = Math.max(through, operation.operationSequence); return session.acceptOperation(operation) }
    const stash = operation => { pending.set(operation.operationSequence, operation); through = Math.max(through, operation.operationSequence) }
    return { session, calls, replies, pending, offer, stash }
  }

  {
    const f=fixture(), input=stroke(1); input.data.inkVersion=5
    const frozen=structuredClone(input)
    await f.offer(input); await f.session.flush()
    const saved=f.calls.find(call=>call.channel==='writer.create').payload
    assert.deepEqual(saved.data,frozen.data,'v5 operation preserves measured pressure/time/coordinates')
    assert.ok(Object.is(saved.data.points[0].x,-0))
    assert.equal(f.calls.filter(call=>call.channel==='writer.create').length,1)
    await f.offer(structuredClone(input)); await f.session.flush()
    assert.equal(f.calls.filter(call=>call.channel==='writer.create').length,1,'v5 duplicate cannot resave')
    pass('v5 measured operation flush/ACK and duplicate raw fidelity')
  }

  {
    const started = gate(), finish = gate(), f = fixture({ create: async input => { started.release(); await finish.promise; return { ...input, id: 'saved' } } })
    const original = stroke(1), first = f.offer(original); await started.promise
    assert.match(f.session.operations.get(1).fingerprint, /^[0-9a-f]{64}$/)
    const reordered = Object.fromEntries(Object.entries(original).reverse())
    reordered.style = Object.fromEntries(Object.entries(original.style).reverse())
    reordered.data = { points: original.data.points.map(point => Object.fromEntries(Object.entries(point).reverse())), inkVersion: 4 }
    const duplicate = f.session.acceptOperation(reordered)
    await assert.rejects(f.session.acceptOperation({ ...original, data: { ...original.data, points: [{ ...original.data.points[0], x: 0 }] } }), /서로 다른/)
    finish.release(); await Promise.all([first, duplicate])
    assert.equal(f.session.operations.size, 0, 'ACK releases the ordered raw input')
    assert.match(f.session.completedOperationFingerprints.get(1), /^[0-9a-f]{64}$/)
    await assert.rejects(f.session.acceptOperation({ ...original, data: { ...original.data, points: [{ ...original.data.points[0], x: .8 }] } }), /재사용/)
    await assert.rejects(f.session.acceptOperation({ ...original, style: { ...original.style, opacity: .5 } }), /재사용/)
    await f.session.acceptOperation(reordered)
    assert.equal(f.calls.filter(call => call.channel === 'writer.create').length, 1)
    pass('push/flush key order is irrelevant; pending signed-zero and completed stroke mutations are rejected')
  }
  {
    const started = gate(), finish = gate()
    const f = fixture({ create: async input => { if (input.clientMutationId === uuid(1)) { started.release(); await finish.promise } return { ...input, id: `saved-${input.clientMutationId}` } } })
    const first = stroke(1), p1 = f.offer(first); await started.promise
    first.data.points[0].x = .9
    const p2 = f.offer(erase(2, [{ clientMutationId: uuid(1) }])), p3 = f.offer(stroke(3))
    await turn(); assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 0)
    finish.release(); await Promise.all([p1, p2, p3]); await f.session.flush()
    assert.deepEqual(f.calls.filter(call => call.channel.startsWith('writer.') && call.channel !== 'writer.flush').map(call => call.channel), ['writer.create', 'writer.remove', 'writer.create'])
    assert.ok(Object.is(f.calls.find(call => call.channel === 'writer.create').payload.data.points[0].x, -0), 'writer receives original measured -0, not a JSON round trip or later mutable value')
    assert.deepEqual(f.calls.find(call => call.channel === 'writer.remove').payload, [`saved-${uuid(1)}`])
    assert.deepEqual(f.replies[0].resolvedTargets, [{ clientMutationId: uuid(1), drawingId: `saved-${uuid(1)}` }])
    assert.equal(f.session.eraseReceipts.get(uuid(1002)).result, undefined, 'confirmed result releases target replay array')
    assert.match(f.session.eraseReceipts.get(uuid(1002)).fingerprint, /^[0-9a-f]{64}$/)
    assert.equal(f.calls.at(-1).channel, 'writer.flush')
    pass('ordered pen → mutation-only erase → pen, raw bits and frozen input, original writer')
  }
  {
    const started = gate(), finish = gate(), f = fixture({ remove: async () => { started.release(); await finish.promise; return true } })
    const input = erase(1); f.stash(input) // Native flush seals before WK event delivery.
    let flushed = false
    const pending = f.session.flush().then(() => { flushed = true })
    await started.promise; assert.equal(flushed, false)
    const lateEvent = f.session.acceptOperation(input)
    finish.release(); await Promise.all([pending, lateEvent])
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 1)
    assert.equal(f.replies.length, 1)
    assert.ok(f.calls.findIndex(call => call.channel === 'pdfNative:eraseResult') < f.calls.findIndex(call => call.channel === 'writer.flush'))
    pass('flush reply before erase event waits delete/result ACK; duplicate event creates one undo write')
  }
  {
    const f = fixture({ failResult: 1 }), input = erase(1)
    await assert.rejects(f.offer(input), /lost result ACK/)
    assert.equal(f.pending.size, 0, 'native accepted result before losing ACK')
    await f.session.flush()
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 1)
    assert.equal(f.replies.length, 2)
    assert.deepEqual(f.replies[0], f.replies[1])
    await f.session.acceptOperation(input)
    assert.equal(f.replies.length, 2)
    pass('lost result ACK retries immutable result only, even when native pending list is empty')
  }
  {
    const f = fixture({ wrongResult: 1 }), input = erase(1)
    await assert.rejects(f.offer(input), /응답이 일치/)
    await f.session.flush()
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 1)
    assert.equal(f.replies.length, 2)
    pass('mismatched result ACK cannot complete erase; retry sends no second delete')
  }
  {
    const f = fixture({ failStrokeAck: 1 })
    await assert.rejects(f.offer(stroke(1)), /lost stroke ACK/)
    const deleting = f.offer(erase(2, [{ clientMutationId: uuid(1) }]))
    await f.session.flush(); await deleting
    assert.equal(f.calls.filter(call => call.channel === 'writer.create').length, 1)
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 1)
    assert.deepEqual(f.calls.find(call => call.channel === 'writer.remove').payload, [`saved-${uuid(1)}`])
    pass('lost ordered stroke ACK recovers before dependent erase without duplicate pen history')
  }
  for (const throws of [false, true]) {
    const f = fixture({ remove: async () => { if (throws) throw new Error('ambiguous IPC outcome'); return false } })
    const input = erase(1)
    await assert.rejects(f.offer(input), /저장 결과/)
    assert.equal(f.replies[0].outcome, 'unknown')
    await f.offer(stroke(2))
    await assert.rejects(f.session.flush(), /저장 결과/)
    await assert.rejects(f.session.close(), /저장 결과/)
    await assert.rejects(f.session.acceptOperation(input), /저장 결과/)
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 1)
    assert.equal(f.calls.filter(call => call.channel === 'writer.create').length, 1, 'later Pencil durability still drains')
    assert.equal(f.calls.filter(call => call.channel === 'pdfNative:close').length, 0)
  }
  pass('false/thrown delete remains unknown; later pen saves, flush/close fail, no blind retry')
  {
    const f = fixture()
    const second = f.offer(erase(2)); await turn()
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 0)
    await assert.rejects(f.session.flush(), /도착하지/)
    await f.offer(stroke(1)); await second; await f.session.flush()
    pass('out-of-order event buffers until predecessor; missing flush watermark fails without deadlock')
  }
  {
    const first = stroke(1), second = erase(2, [{ clientMutationId: uuid(1) }]), third = stroke(3)
    const f = fixture({ response: () => ({ pending: [first, third], pendingOperations: [third, second, first], throughOperationSequence: 3 }) })
    await f.session.flush()
    assert.deepEqual(f.calls.filter(call => call.channel.startsWith('writer.') && call.channel !== 'writer.flush').map(call => call.channel), ['writer.create', 'writer.remove', 'writer.create'])
    pass('journal/live overlap and unsorted flush reply cannot reorder erase after later stroke')
  }
  {
    const f = fixture(), input = erase(1)
    await f.offer(input)
    await assert.rejects(f.session.acceptOperation({ ...input, targets: [{ drawingId: 'different' }] }), /서로 다른|재사용/)
    await assert.rejects(f.session.acceptOperation({ ...input, operationSequence: 2 }), /서로 다른/)
    await assert.rejects(f.session.acceptOperation(erase(1, [{ drawingId: 'other' }], 5)), /재사용/)
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 1)
    pass('operation UUID/content and completed sequence identity cannot be reused')
  }
  {
    const invalid = [erase(1, []), { ...erase(1), page: 0 }, { ...erase(1), documentRevision: 'b'.repeat(64) },
      { ...erase(1), operationSequence: 1.2 }, { ...erase(1), originToolEpoch: false }, erase(1, [{}]),
      erase(1, [{ drawingId: 'same' }, { drawingId: 'same' }]), erase(1, [{ clientMutationId: 'not-a-receipt' }]), erase(1, [{ drawingId: '\ud800' }])]
    for (const input of invalid) {
      const f = fixture({ response: () => ({ pendingOperations: [erase(1), input], throughOperationSequence: 2 }) })
      await assert.rejects(f.session.flush()); assert.equal(f.calls.filter(call => call.channel.startsWith('writer.')).length, 0)
    }
    const f = fixture(); await f.offer(erase(1, [{ drawingId: 'é' }, { drawingId: 'e\u0301' }]))
    assert.deepEqual(f.calls.find(call => call.channel === 'writer.remove').payload, ['é', 'e\u0301'])
    pass('malformed batch rejected before writes; Unicode IDs stay exact and distinct')
  }
  {
    const f = fixture(); await f.offer(stroke(1))
    await assert.rejects(f.offer(erase(2, [{ clientMutationId: uuid(1), drawingId: 'wrong-row' }])), /一致|일치/)
    assert.equal(f.calls.filter(call => call.channel === 'writer.remove').length, 0)
    const other = fixture(); await assert.rejects(other.offer(erase(1, [{ clientMutationId: uuid(99) }])), /저장 완료/)
    assert.equal(other.replies.length, 0)
    pass('conflicting/unresolved mutation identity never reaches delete or success ACK')
  }
  {
    const start = gate(), finish = gate(), f = fixture({ remove: async () => { start.release(); await finish.promise; return true } })
    f.stash(erase(1))
    const close = f.session.close(); await start.promise
    assert.equal(f.calls.some(call => call.channel === 'pdfNative:close'), false)
    finish.release(); await close
    assert.equal(f.calls.at(-1).channel, 'pdfNative:close')
    await assert.rejects(f.session.acceptOperation(erase(2)), /닫힌/)
    pass('retired owner close waits sealed erase and writer flush before native close')
  }
  {
    const hook = await readFile(resolve(runtime, 'renderer/nativePDF/useNativePDF.ts'), 'utf8')
    assert.ok(hook.indexOf("event.type === 'eraseCommit'") < hook.indexOf('if (cancelled) return', hook.indexOf("const unsubscribe = bridge.on")), 'late erase must retain original session owner')
    assert.ok(hook.includes('entry.configureNativeErase(capabilities.nativeInkErase === 1, state.documentRevision)'))
    assert.ok(hook.includes('...(entry.nativeInkErase ? { nativeInkErase: true } : {})'))
    assert.ok(hook.indexOf('entry.configureNativeErase(') < hook.indexOf('await publishCurrent(entry, publisher'))
    const f = new NativePDFSession(identity, { invoke: async () => ({}), on: () => () => {} }, { create: async () => null })
    await assert.rejects(f.acceptOperation(erase(1)), /연결/)
    assert.throws(() => f.configureNativeErase(true, revision), /연결/)
    pass('capability/snapshot opt-in and pre-cancel owner routing source guards (not mounted React proof)')
  }
  console.log(`Native erase ${groups} groups PASS; pure Session/writer/transport tests, no browser/device or physical latency claim`)
} finally { await rm(temporary, { recursive: true, force: true }) }
