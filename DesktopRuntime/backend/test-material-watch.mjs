import assert from 'node:assert/strict'
import vm from 'node:vm'
import { readFile } from 'node:fs/promises'
import { dependencies, runtime } from '../scripts/dependencies.mjs'
const ts = dependencies().require('typescript')
const code = ts.transpileModule(await readFile(runtime + '/backend/material-watch.ts', 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText
const module = { exports: {}, setTimeout, clearTimeout }; vm.runInNewContext(code, module)
const create = module.exports.createMaterialWatchers
const tick = () => new Promise(resolve => setImmediate(resolve))
function fixture() {
  const timers = new Map(), delays = [], changed = [], errors = [], pending = []
  let sequence = 0, tree = [], deferred = false, failure, scans = 0
  const watchers = create({ tree: () => { scans++; return deferred ? new Promise((resolve, reject) => pending.push({ resolve, reject })) : failure ? Promise.reject(failure) : Promise.resolve(tree) }, invalidate() {}, changed: id => changed.push(id), failed: error => errors.push(error), schedule: (callback, delay) => { delays.push(delay); timers.set(++sequence, callback); return sequence }, cancel: id => timers.delete(id) })
  return { watchers, timers, delays, pending, changed, errors, setDeferred: value => deferred = value, setTree: value => tree = value, setFailure: value => failure = value, scans: () => scans,
    fire() { const [id, fn] = timers.entries().next().value; timers.delete(id); fn() } }
}
for (let i = 0; i < 100; i++) {
  const f = fixture(); f.setDeferred(true)
  const req = { courseId: 'course', subscriptionId: 'pane', rendererSessionId: 'session' }
  const waiting = f.watchers.watch(req)
  f.watchers.unwatch(req); f.pending.shift().resolve([]); await waiting
  assert.equal(f.timers.size, 0, 'unwatch while initial scan awaits cannot create an orphan')
  assert.equal(f.watchers.inspect().leases, 0)
}
const f = fixture(), a = { courseId: 'course', subscriptionId: 'a', rendererSessionId: 'session' }, b = { ...a, subscriptionId: 'b' }
f.setDeferred(true)
const first = f.watchers.watch(a), second = f.watchers.watch(b), duplicate = f.watchers.watch(a)
assert.equal(f.scans(), 1)
assert.equal(f.watchers.inspect().leases, 2)
f.pending.shift().resolve([]); await Promise.all([first, second, duplicate]); f.setDeferred(false)
assert.equal(f.timers.size, 1)
f.watchers.unwatch(a); assert.equal(f.timers.size, 1)
f.watchers.setActive(false); assert.equal(f.timers.size, 0)
f.setTree(['changed while backgrounded']); f.watchers.setActive(true); await tick()
assert.equal(f.changed.length, 1); assert.equal(f.timers.size, 1)
f.watchers.setSession('next-session'); assert.equal(f.timers.size, 0)
await assert.rejects(f.watchers.watch(b), error => error.code === 'STALE_RENDERER_SESSION')
assert.equal(f.watchers.inspect().leases, 0)
const g = fixture(); g.setDeferred(true)
const stale = g.watchers.watch(a); g.watchers.reset(); const fresh = g.watchers.watch(a)
g.pending.shift().resolve(['old']); await stale
assert.equal(g.timers.size, 0)
g.pending.shift().resolve(['new']); await fresh
assert.equal(g.timers.size, 1); assert.equal(g.changed.length, 0)
g.watchers.reset(); assert.equal(g.timers.size, 0)
const h = fixture(); await h.watchers.watch(a)
for (let step = 0; step < 5; step++) { h.fire(); await tick() }
assert.deepEqual(h.delays, [2500, 5000, 10000, 30000, 30000, 30000])
const beforeDuplicate = h.scans(); await h.watchers.watch(a); assert.equal(h.scans(), beforeDuplicate)
h.watchers.mutated('course'); assert.equal(h.delays.at(-1), 2500); assert.equal(h.timers.size, 1)
h.fire(); await tick(); assert.equal(h.delays.at(-1), 5000)
h.setTree(['new external file']); h.fire(); await tick(); assert.equal(h.delays.at(-1), 2500); assert.equal(h.changed.length, 1)
h.fire(); await tick(); h.watchers.setActive(false); assert.equal(h.timers.size, 0)
h.watchers.setActive(true); await tick(); assert.equal(h.delays.at(-1), 2500)
h.setFailure(Error('temporarily unavailable'))
for (let step = 0; step < 4; step++) { h.fire(); await tick() }
assert.deepEqual(h.delays.slice(-4), [5000, 10000, 30000, 30000]); assert.equal(h.errors.length, 4)
h.watchers.reset(); assert.equal(h.timers.size, 0)
const retire = (watchers, action) => {
  if (action === 'unwatch') watchers.unwatch(a)
  else if (action === 'reset') watchers.reset()
  else watchers.setSession('next-session')
}
const startBackgroundScan = (fixture, trigger) => {
  if (trigger === 'poll') fixture.fire()
  else { fixture.watchers.setActive(false); fixture.watchers.setActive(true) }
}
for (const trigger of ['poll', 'foreground']) {
  for (const action of ['unwatch', 'reset', 'setSession']) {
    const retired = fixture(); await retired.watchers.watch(a); retired.setDeferred(true)
    startBackgroundScan(retired, trigger)
    const oldScan = retired.pending.shift()
    retire(retired.watchers, action)
    assert.equal(retired.watchers.inspect().leases, 0)
    assert.equal(retired.timers.size, 0)
    const freshRequest = { ...a, rendererSessionId: action === 'setSession' ? 'next-session' : a.rendererSessionId }
    const freshWatch = retired.watchers.watch(freshRequest), freshScan = retired.pending.shift()
    oldScan.reject(Error('retired folder failed')); await tick()
    assert.equal(retired.errors.length, 0, `${trigger} failure after ${action} must not notify the replacement view`)
    assert.equal(retired.changed.length, 0)
    assert.equal(retired.watchers.inspect().leases, 1, 'old completion must retain the replacement lease')
    assert.equal(retired.timers.size, 0, 'old completion must not schedule a timer')
    freshScan.resolve([]); await freshWatch
    startBackgroundScan(retired, trigger)
    const failure = Error('current folder failed')
    retired.pending.shift().reject(failure); await tick()
    assert.equal(retired.errors.length, 1, `${trigger} must still report the current generation failure`)
    assert.equal(retired.errors[0], failure)
    assert.equal(retired.timers.size, 1)
    retired.watchers.reset()
  }
  const shared = fixture(); await shared.watchers.watch(a); await shared.watchers.watch(b)
  shared.setDeferred(true); startBackgroundScan(shared, trigger)
  shared.watchers.unwatch(a)
  const failure = Error('remaining subscriber folder failed')
  shared.pending.shift().reject(failure); await tick()
  assert.equal(shared.errors[0], failure, 'removing one lease must not silence the remaining subscriber')
  assert.equal(shared.errors.length, 1)
  assert.equal(shared.watchers.inspect().leases, 1)
  assert.equal(shared.timers.size, 1)
  shared.watchers.reset()
}
for (const action of ['unwatch', 'reset', 'setSession']) {
  const initial = fixture(); initial.setDeferred(true)
  const failure = Error('initial scan failed')
  const rejection = assert.rejects(initial.watchers.watch(a), error => error === failure)
  retire(initial.watchers, action)
  initial.pending.shift().reject(failure); await rejection
  assert.equal(initial.errors.length, 0, 'initial watch reports through its promise, not a background notice')
  assert.equal(initial.watchers.inspect().leases, 0)
  assert.equal(initial.timers.size, 0)
}
console.log('PASS: 100 cancelled initial scans, concurrent/idempotent leases, bounded idle/error backoff, mutation/foreground reset, stale renderer rejection, retired poll/foreground errors suppressed, current/shared lease failures retained and initial watch rejection preserved')
