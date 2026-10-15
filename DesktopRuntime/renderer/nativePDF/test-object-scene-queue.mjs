import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'

const { require } = dependencies(), ts = require('typescript')
const folder = await mkdtemp(resolve(tmpdir(), 'bandal-object-scene-queue-'))
const clone = value => JSON.parse(JSON.stringify(value))
const turn = async () => { for (let i = 0; i < 8; i++) await Promise.resolve() }
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b }); return { promise, resolve, reject } }
const row = (id, p = .5) => ({ id, page: 1, kind: 'ink', data: { inkVersion: 4, points: [{ x: .1, y: .2, p, t: 4 }] },
  style: { color: 'blue', width: .003, opacity: .6 }, createdAt: 'a', updatedAt: 'b' })
const scene = (...objects) => ({ objects, selection: null, resizable: false, textHandles: false })
const wire = (page, value) => clone({ page, ...value })
let groups = 0
const deltaMetrics = {}

try {
  for (const name of ['objectSceneQueue', 'drawingSnapshot']) {
    const source = await readFile(resolve(runtime, `renderer/nativePDF/${name}.ts`), 'utf8')
    const result = ts.transpileModule(source, { reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, strict: true } })
    assert.equal(result.diagnostics?.filter(x => x.category === ts.DiagnosticCategory.Error).length ?? 0, 0)
    await writeFile(resolve(folder, `${name}.mjs`), result.outputText)
  }
  const queueSource = await readFile(resolve(runtime, 'renderer/nativePDF/objectSceneQueue.ts'), 'utf8')
  await writeFile(resolve(folder, 'objectSceneQueue.ts'), queueSource)
  await writeFile(resolve(folder, 'objectScene.ts'), 'export interface NativeObjectScene { objects: unknown[]; selection: unknown; resizable: boolean; textHandles: boolean }')
  const checked = ts.createProgram([resolve(folder, 'objectSceneQueue.ts')], { target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Node10,
    strict: true, noUnusedLocals: true, noUnusedParameters: true, exactOptionalPropertyTypes: true, noUncheckedIndexedAccess: true, noEmit: true, skipLibCheck: true })
  const errors = ts.getPreEmitDiagnostics(checked).filter(x => x.category === ts.DiagnosticCategory.Error)
  assert.deepEqual(errors.map(error => ts.flattenDiagnosticMessageText(error.messageText, '\n')), [])
  const { NativePDFObjectSceneQueue: Queue } = await import(pathToFileURL(resolve(folder, 'objectSceneQueue.mjs')))
  const { NativePDFDrawingSnapshotPublisher: Snapshots } = await import(pathToFileURL(resolve(folder, 'drawingSnapshot.mjs')))
  const ready = (queue, tool = 'eraser') => { queue.resume(tool); queue.acknowledgeTool(queue.observeTool(tool)) }
  const fail = error => { throw error }

  // The same complete serialized scene is sent once. Changes to any nested
  // field, metadata, selection or rendering flags are not ID/ref-deduped.
  {
    const calls = [], q = new Queue(async value => calls.push(clone(value)), fail)
    ready(q)
    const value = scene(row('a'))
    q.publish(1, value, 'eraser'); await q.flush()
    for (let i = 0; i < 20; i++) q.publish(1, i % 2 ? value : clone(value), 'eraser')
    await q.flush(); assert.equal(calls.length, 1)
    const edits = [
      () => { value.objects[0].data.points[0].p = .8 },
      () => { value.objects[0].data.points[0].t = 9 },
      () => { value.objects[0].data.points[0].tiltX = 15 },
      () => { value.objects[0].data.points.push({ x: .4, y: .5, p: .9 }) },
      () => { value.objects[0].data.inkVersion = 3 },
      () => { value.objects[0].kind = 'highlighter' },
      () => { value.objects[0].style.width = .01 },
      () => { value.objects[0].style.opacity = .2 },
      () => { value.objects[0].updatedAt = 'changed' },
      () => { value.objects[0].futureField = { nested: ['preserve', 3] } },
      () => { value.selection = { x: .1, y: .2, width: .3, height: .4 } },
      () => { value.selection.x = .6 },
      () => { value.resizable = true },
      () => { value.textHandles = true },
      () => { value.objects.push({ id: 'native-object-preview', kind: 'line', data: { points: [{ x: .1, y: .4, p: .5 }] }, style: { width: .02 } }) },
      () => { value.objects.at(-1).data.points[0].x = .7 },
      () => { value.objects.reverse() },
      () => { value.objects.splice(0, 1) },
      () => { value.objects = [] },
      () => { value.selection = null; value.resizable = false; value.textHandles = false }
    ]
    for (const edit of edits) { edit(); q.publish(1, value, 'eraser'); await q.flush(); assert.deepEqual(calls.at(-1), wire(1, value)) }
    assert.equal(calls.length, edits.length + 1)
    q.dispose(); groups++
  }

  // Heavy 200×96 visual scene burst: keep exactly first+latest, not stale
  // intermediate eraser previews. The actual sender never overlaps.
  {
    const gate = deferred(), calls = []; let concurrent = 0, maximum = 0
    const q = new Queue(async value => {
      concurrent++; maximum = Math.max(maximum, concurrent); calls.push(clone(value))
      if (calls.length === 1) await gate.promise
      concurrent--
    }, fail)
    ready(q)
    const heavy = Array.from({ length: 200 }, (_, i) => ({ ...row(`heavy-${i}`), data: { inkVersion: 4,
      points: Array.from({ length: 96 }, (_, j) => ({ x: j / 100, y: i / 250, p: .25 + j / 160, t: j * 4 })) } }))
    q.publish(1, scene(...heavy), 'eraser'); await turn(); assert.equal(calls.length, 1)
    for (let i = 1; i <= 32; i++) q.publish(1, scene(...heavy.slice(i)), 'eraser')
    heavy[32].data.points[0].p = .999 // Must not mutate the already queued frame.
    gate.resolve(); await q.flush()
    assert.equal(calls.length, 2); assert.equal(maximum, 1)
    assert.equal(calls[1].objects.length, 168); assert.equal(calls[1].objects[0].data.points[0].p, .25)
    q.publish(1, scene(...heavy.slice(32)), 'eraser'); await q.flush()
    assert.equal(calls.at(-1).objects[0].data.points[0].p, .999)
    q.dispose(); groups++
  }

  // A→B→A while B is in flight must repaint A after B's late ACK. Reordered
  // or deleted rows are complete replacements, never set/cardinality matches.
  {
    const gate = deferred(), calls = [], a = scene(row('a')), b = scene(row('b'))
    const q = new Queue(async value => { calls.push(clone(value)); if (calls.length === 2) await gate.promise }, fail)
    ready(q); q.publish(1, a, 'eraser'); await q.flush()
    q.publish(1, b, 'eraser'); await turn(); q.publish(1, a, 'eraser')
    gate.resolve(); await q.flush()
    assert.deepEqual(calls.map(x => x.objects[0].id), ['a', 'b', 'a'])
    q.dispose(); groups++
  }

  // Global serialization with latest state per page, plus fair service and
  // pruning: a newer page cannot replace another page's visual state.
  {
    const gate = deferred(), calls = []
    const q = new Queue(async value => { calls.push(clone(value)); if (calls.length === 1) await gate.promise }, fail)
    ready(q); q.publish(1, scene(row('p1-first')), 'eraser'); await turn()
    q.publish(2, scene(row('p2-old')), 'eraser'); q.publish(2, scene(row('p2-latest')), 'eraser')
    q.publish(1, scene(row('p1-latest')), 'eraser')
    q.publish(3, scene(row('removed-page')), 'eraser'); q.prunePages(new Set([1, 2]))
    gate.resolve(); await q.flush()
    assert.deepEqual(calls.map(x => [x.page, x.objects[0].id]), [[1, 'p1-first'], [2, 'p2-latest'], [1, 'p1-latest']])
    q.prunePages(new Set([2])); q.publish(1, scene(row('p1-latest')), 'eraser'); await q.flush()
    assert.equal(calls.length, 4, 'A remounted page must not inherit its old dedupe ACK')
    q.dispose(); groups++
  }

  // Actual snapshot publisher + actual queue: emulate NativePDFHost's rule
  // that a pen-mode objectScene is ignored but replies successfully. No scene
  // can race ahead of the non-ink tool's snapshot ACK.
  {
    let nativeTool = 'pen'; const snapshotGate = deferred(), calls = [], applied = []
    const q = new Queue(async value => { calls.push(clone(value)); if (!['pen', 'highlighter'].includes(nativeTool)) applied.push(clone(value)); return {} }, fail)
    const snapshots = new Snapshots(payload => q.sendSnapshot(payload, async wire => { await snapshotGate.promise; nativeTool = wire.tool.name; return {} }))
    q.resume('eraser')
    const epoch = q.observeTool('eraser')
    q.publish(1, scene(row('before-tool-ack')), 'eraser')
    const ack = snapshots.publish({ tool: { name: 'eraser' }, objectSceneEpoch: epoch }, [])
    await turn(); assert.equal(calls.length, 0)
    q.publish(1, scene(row('latest-before-tool-ack')), 'eraser')
    snapshotGate.resolve(); await ack; await q.flush()
    assert.equal(calls.length, 1); assert.deepEqual(applied[0], wire(1, scene(row('latest-before-tool-ack'))))
    q.acknowledgeTool(epoch); await q.flush(); assert.equal(calls.length, 1, 'Repeated same-epoch snapshot ACKs must not force duplicate scenes')
    q.dispose(); snapshots.dispose(); groups++
  }

  // Tool/visibility lifetime uses epochs. Late old ACKs/errors cannot unlock
  // new work, and the exact same scene must be resent after native pen clears it.
  for (const lateReject of [false, true]) {
    const gate = deferred(), calls = [], errors = []
    const q = new Queue(async value => { calls.push(clone(value)); if (calls.length === 1) await gate.promise }, error => errors.push(error))
    ready(q); const oldEpoch = q.observeTool('eraser'), value = scene(row('same'))
    q.publish(1, value, 'eraser'); await turn()
    q.observeTool('pen'); q.publish(1, scene(row('must-not-send')), 'pen')
    const newEpoch = q.observeTool('eraser'); q.publish(1, value, 'eraser')
    q.acknowledgeTool(oldEpoch); await turn(); assert.equal(calls.length, 1)
    q.acknowledgeTool(newEpoch)
    if (lateReject) gate.reject(new Error('retired tool request')); else gate.resolve()
    await q.flush(); assert.equal(calls.length, 2); assert.equal(errors.length, 0)
    q.observeTool('highlighter'); await turn(); assert.equal(calls.length, 2)
    q.pause(); q.resume('eraser'); q.publish(1, value, 'eraser')
    q.acknowledgeTool(newEpoch); await q.flush(); assert.equal(calls.length, 2)
    q.acknowledgeTool(q.observeTool('eraser')); await q.flush(); assert.equal(calls.length, 3)
    q.dispose(); groups++
  }

  // Failed RPCs may already have applied. Retry only the newest replacement
  // once, then retain a visible error/retry action without per-render storms.
  for (const thrown of [new Error('unknown scene result'), undefined]) {
    let failures = 2, retry; const calls = [], errors = []
    const q = new Queue(async value => { calls.push(clone(value)); if (failures-- > 0) throw thrown }, (error, action) => { errors.push(error); retry = action })
    ready(q); q.publish(1, scene(row('a')), 'eraser')
    let rejected = false; try { await q.flush() } catch (error) { rejected = true; assert.equal(error, thrown) }
    assert.equal(rejected, true); assert.equal(calls.length, 2); assert.equal(errors.length, 1)
    for (let i = 0; i < 25; i++) q.publish(1, scene(row(`latest-${i}`)), 'eraser')
    await turn(); assert.equal(calls.length, 2)
    await retry(); assert.equal(calls.length, 3); assert.equal(calls[2].objects[0].id, 'latest-24')
    q.publish(1, scene(row('latest-24')), 'eraser'); await q.flush(); assert.equal(calls.length, 3)
    q.dispose(); groups++
  }

  // Close/reopen is a new owned queue. A late request from the retired entry
  // cannot send its queued tail or ACK the new session's identical scene.
  {
    const gate = deferred(), old = [], fresh = [], errors = []
    const retired = new Queue(async value => { old.push(clone(value)); await gate.promise }, error => errors.push(error))
    ready(retired); retired.publish(1, scene(row('first')), 'eraser'); await turn()
    retired.publish(1, scene(row('must-not-survive-close')), 'eraser'); retired.dispose()
    const reopened = new Queue(async value => fresh.push(clone(value)), fail)
    ready(reopened); reopened.publish(1, scene(row('first')), 'eraser'); await reopened.flush()
    gate.reject(new Error('old session closed')); await retired.flush(); await retired.retry()
    retired.publish(1, scene(row('after-close')), 'eraser')
    assert.equal(old.length, 1); assert.equal(fresh.length, 1); assert.equal(errors.length, 0)
    reopened.dispose(); groups++
  }

  // Exercise the actual transformed InkLayer layout effect, including its
  // request-on-parent-listener-ready replay and cleanup. No app/browser is run.
  {
    const { transformNativePDFPointerCapture } = await import(pathToFileURL(resolve(runtime, 'renderer/nativePDF/index.mjs')))
    const original = await readFile(resolve(runtime, 'upstream/src/renderer/src/features/ink/InkLayer.tsx'), 'utf8')
    const transformed = transformNativePDFPointerCapture(original)
    const syntax = ts.createSourceFile('InkLayer.tsx', transformed, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
    let hook
    const visit = node => { if (ts.isCallExpression(node) && node.expression.getText(syntax) === 'useLayoutEffect' && node.getText(syntax).includes('bandal-native-pdf-request-object-scene')) hook = node.arguments[0]; ts.forEachChild(node, visit) }
    visit(syntax); assert.ok(hook)
    const output = ts.transpileModule(`const effect = ${hook.getText(syntax)};`, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None } }).outputText
    const listeners = new Map(), published = [], svg = { addEventListener: (name, fn) => listeners.set(name, fn), removeEventListener: (name, fn) => { if (listeners.get(name) === fn) listeners.delete(name) } }
    const value = row('source')
    const effect = new Function('svgRef', 'activeTool', 'shapes', 'erasedIds', 'boxForShape', 'gesture', 'resolveShapeId', 'publishNativePDFScene', 'aspect', 'selectedId', 'editingId', 'normalizedBox', 'style',
      output + '\nreturn effect;')({ current: svg }, 'eraser', [value], new Set(), () => null, null, x => x,
      (_, input) => published.push(input), 1.4, null, null, () => null, {})
    const cleanup = effect(); assert.equal(published.length, 1)
    listeners.get('bandal-native-pdf-request-object-scene')(); assert.equal(published.length, 2)
    assert.equal(published[1].shapes[0], value); cleanup(); assert.equal(listeners.size, 0)
    groups++
  }

  // Exercise the actual hook's subscription, publishCurrent, layout and passive
  // effect bodies together. Layout never prepares a full-row snapshot: the one
  // existing passive effect ACKs initial ready/resume/batched tool roundtrips.
  // This is a deterministic scheduling fixture, not a mounted React/WK test.
  {
    const source = await readFile(resolve(runtime, 'renderer/nativePDF/useNativePDF.ts'), 'utf8')
    const syntax = ts.createSourceFile('useNativePDF.ts', source, ts.ScriptTarget.Latest, true)
    let publishNode, subscribeNode, layoutNode, layoutDeps, passiveNode, passiveDeps
    const visit = node => {
      if (ts.isVariableDeclaration(node) && node.name.getText(syntax) === 'publishCurrent') publishNode = node.initializer
      if (ts.isVariableDeclaration(node) && node.name.getText(syntax) === 'stopSceneTool') subscribeNode = node.initializer.arguments[0]
      if (ts.isCallExpression(node) && node.expression.getText(syntax) === 'useLayoutEffect' && node.arguments[0].getText(syntax).includes('queue.resume')) {
        layoutNode = node.arguments[0]; layoutDeps = node.arguments[1].getText(syntax)
      }
      if (ts.isCallExpression(node) && node.expression.getText(syntax) === 'useEffect' && node.arguments[0].getText(syntax).includes('void publishCurrent(entry, publisher, palette)')) {
        passiveNode = node.arguments[0]; passiveDeps = node.arguments[1].getText(syntax)
      }
      ts.forEachChild(node, visit)
    }
    visit(syntax); assert.ok(publishNode && subscribeNode && layoutNode && passiveNode)
    assert.doesNotMatch(publishNode.getText(syntax), /acknowledgeTool|\.then\s*\(/, 'A shared publish promise must never acknowledge the scene epoch')
    assert.match(source, /payload => sceneOwner\.queue\.sendSnapshot\(payload, wire => entry\.invoke\('snapshot', wire\)\)/)
    assert.match(source, /configurePatch\(capabilities\.objectScenePatch === 1\)/)
    assert.match(layoutDeps, /\bsceneToolRevision\b/, 'The store revision must invalidate the actual layout effect')
    assert.doesNotMatch(layoutNode.getText(syntax), /publishCurrent\s*\(/, 'Full-row snapshot preparation must not run in the scene layout effect')
    for (const dependency of ['ready', 'active', 'props.scroller', 'sceneToolRevision', 'props.drawings.drawings', 'props.drawings.loading',
      'props.interactive', 'props.annotations', 'props.activeAnnotation', 'props.hoveredAnnotation', 'palette', 'tool', 'color', 'width', 'opacity']) {
      assert.ok(passiveDeps.slice(1, -1).split(',').map(value => value.trim()).includes(dependency), `Missing snapshot trigger: ${dependency}`)
    }
    const evaluate = (node, bindings) => {
      const compiled = ts.transpileModule(`const result = ${node.getText(syntax)};`, {
        compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None } }).outputText
      return new Function(...Object.keys(bindings), compiled + '\nreturn result;')(...Object.values(bindings))
    }
    const gate = deferred(), sceneCalls = [], snapshotCalls = [], errors = []
    let state = { activeTool: 'eraser', color: 'blue', width: .003, opacity: 1 }, revision = 0, preparations = 0, failSnapshots = 0
    const inputStore = { getState: () => state }
    const entry = { mutationIdForDrawing: () => null }
    const owner = { entry, queue: new Queue(async value => sceneCalls.push(clone(value)), error => errors.push(error)) }
    const publisher = new Snapshots(payload => owner.queue.sendSnapshot(payload, async value => {
      snapshotCalls.push(clone(value))
      if (snapshotCalls.length === 1) await gate.promise
      if (failSnapshots > 0) { failSnapshots--; throw new Error('snapshot rejected') }
    }))
    const objectScenes = { current: owner }, snapshots = { current: publisher }
    const latest = { current: { interactive: true, drawings: { loading: false, drawings: [row('canonical')] },
      annotations: [{ id: 'highlight', color: 'yellow' }], activeAnnotation: null, hoveredAnnotation: null } }
    const palette = { yellow: [1, 1, 0] }
    const publishCurrent = evaluate(publishNode, {
      latest, inputStore, objectScenes, nativePDFDrawingPayload: x => { preparations++; return x }, aspects: { current: new Map() }
    })
    const onStore = evaluate(subscribeNode, { sceneOwner: owner, setSceneToolRevision: update => { revision = update(revision) } })
    const listeners = new Map(), currentScene = scene(row('from-current-child'))
    class SVG {
      closest() { return { dataset: { pdfPage: '1' } } }
      dispatchEvent(event) {
        if (event.type === 'bandal-native-pdf-request-object-scene') listeners.get('bandal-native-pdf-object-scene')?.({ target: this, detail: currentScene })
      }
    }
    const svg = new SVG(), element = {
      addEventListener: (name, fn) => listeners.set(name, fn),
      removeEventListener: (name, fn) => { if (listeners.get(name) === fn) listeners.delete(name) },
      querySelectorAll: selector => selector === 'svg.ink-layer' ? [svg] : [{ dataset: { pdfPage: '1' } }]
    }
    const layout = active => evaluate(layoutNode, { props: { scroller: { current: element } }, session: { current: entry }, objectScenes,
      active, inputStore, report: error => errors.push(error), SVGSVGElement: SVG })()
    const passive = evaluate(passiveNode, { session: { current: entry }, snapshots, ready: true, publishCurrent, palette, report: error => errors.push(error) })
    const settle = async () => { await publisher.flush(); await turn(); await owner.queue.flush() }
    // Preserve the initial open barrier: its ACK precedes native visibility,
    // but does not incorrectly ACK the later layout's new queue epoch.
    const bootstrap = publishCurrent(entry, publisher, palette)
    await turn(); assert.equal(sceneCalls.length, 0); assert.equal(preparations, 1)
    gate.resolve(); await bootstrap
    let cleanup = layout(true); await turn()
    assert.equal(preparations, 1); assert.equal(snapshotCalls.length, 1); assert.equal(sceneCalls.length, 0)
    passive(); await settle()
    assert.equal(preparations, 2); assert.equal(snapshotCalls.length, 2)
    assert.equal(sceneCalls.length, 1)
    const change = tool => { const previous = state; state = { ...state, activeTool: tool }; onStore(state, previous) }
    change('pen'); change('eraser')
    assert.equal(revision, 2, 'Both ownership changes must survive React selector coalescing')
    cleanup(); cleanup = layout(true) // Re-run because the actual dependency changed.
    assert.equal(preparations, 2, 'Tool layout must not prepare the same rows before the passive effect')
    await turn(); assert.equal(sceneCalls.length, 1, 'New epoch remains gated until its snapshot ACK')
    passive(); await settle()
    assert.equal(preparations, 3); assert.equal(snapshotCalls.length, 3)
    assert.equal(sceneCalls.length, 2, 'The identical scene is required again in the newly acknowledged epoch')
    assert.deepEqual(snapshotCalls.map(value => value.tool.name), ['eraser', 'eraser', 'eraser'])
    assert.deepEqual(sceneCalls[1], wire(1, currentScene)); assert.equal(errors.length, 0)

    // Visibility and a changed scroller effect lifetime both resume through
    // this same passive path, not a separate synchronous snapshot publisher.
    cleanup(); assert.equal(layout(false), undefined)
    passive(); await settle(); assert.equal(sceneCalls.length, 2)
    cleanup = layout(true); assert.equal(preparations, 4)
    passive(); await settle(); assert.equal(preparations, 5); assert.equal(sceneCalls.length, 3)
    cleanup(); cleanup = layout(true); assert.equal(preparations, 5)
    passive(); await settle(); assert.equal(preparations, 6); assert.equal(sceneCalls.length, 4)

    // Existing independent updates remain snapshots even without a tool or
    // layout change. An already-ready gate does not duplicate objectScene.
    state = { ...state, color: 'red', width: .006, opacity: .7 }
    latest.current.drawings.drawings[0].data.points[0].p = .9
    latest.current.activeAnnotation = 'highlight'
    palette.yellow = [.9, .8, .1]
    passive(); await settle(); assert.equal(preparations, 7); assert.equal(sceneCalls.length, 4)
    assert.deepEqual(snapshotCalls.at(-1).tool.style, { color: 'red', width: .006, opacity: .7 })
    assert.equal(snapshotCalls.at(-1).drawingPatch.upserts[0].data.points[0].p, .9)
    assert.deepEqual(snapshotCalls.at(-1).annotations[0].nativeColor, [.9, .8, .1])
    assert.equal(snapshotCalls.at(-1).annotations[0].nativeOpacity, .72)

    // A rejected new tool snapshot must not release queued scenes; a later
    // legitimate snapshot update recovers the latest epoch using a reset.
    change('pen'); change('eraser'); cleanup(); cleanup = layout(true)
    failSnapshots = 2; passive()
    await assert.rejects(publisher.flush(), /snapshot rejected/); await turn(); await owner.queue.flush()
    assert.equal(sceneCalls.length, 4); assert.equal(errors.length, 1)
    assert.equal(preparations, 8, 'Internal transport retries must not rerun full-row preparation')
    state = { ...state, color: 'green' }; passive(); await settle()
    assert.equal(preparations, 9); assert.equal(sceneCalls.length, 5)
    assert.equal(snapshotCalls.at(-1).drawingPatch.reset, true)
    cleanup(); svg.dispatchEvent(new Event('bandal-native-pdf-request-object-scene')); await turn()
    assert.equal(sceneCalls.length, 5); assert.equal(listeners.size, 0)
    owner.queue.dispose(); publisher.dispose(); groups++
  }
  // Versioned receiver model is a wire oracle, not a native integration test.
  // Reconstruct the complete visible scene independently and compare it with
  // the caller's full JSON. The real Swift receiver is tested separately.
  const sceneAck = value => ({ page: value.page, objectSceneEpoch: value.objectSceneEpoch, objectSceneRevision: value.objectSceneRevision })
  const receiver = () => {
    const pages = new Map(), calls = []
    return { calls, pages, apply(value) {
      const input = clone(value); calls.push(input)
      for (const key of ['page', 'objectSceneEpoch', 'objectSceneRevision']) assert.ok(Number.isSafeInteger(input[key]) && input[key] > 0)
      const { objectSceneEpoch, objectSceneRevision, objectPatch, ...metadata } = input
      const previous = pages.get(input.page)
      assert.ok(!previous || objectSceneRevision > previous.revision, 'Accepted scene revisions cannot go backwards')
      let visible, base
      if (objectPatch) {
        assert.equal(objectPatch.revision, objectSceneRevision)
        assert.equal(typeof objectPatch.reset, 'boolean')
        if (objectPatch.reset) assert.equal(objectPatch.baseRevision, 0)
        else {
          assert.equal(previous?.epoch, objectSceneEpoch)
          assert.equal(previous?.base, true, 'Full fallback cannot be an incremental base')
          assert.equal(objectPatch.baseRevision, previous.revision)
          assert.ok(objectSceneRevision > objectPatch.baseRevision)
        }
        const rows = new Map(objectPatch.reset ? [] : previous.visible.objects.map(object => [object.id, object]))
        for (const object of objectPatch.upserts) rows.set(object.id, object)
        assert.equal(new Set(objectPatch.order).size, objectPatch.order.length)
        for (const id of objectPatch.order) assert.ok(rows.has(id))
        visible = { ...metadata, objects: objectPatch.order.map(id => rows.get(id)) }; base = true
      } else { visible = metadata; base = false }
      pages.set(input.page, { epoch: objectSceneEpoch, revision: objectSceneRevision, visible, base })
      return sceneAck(input)
    } }
  }

  // First reset sends all rows; after ACK each mutation must send only changed
  // rows while preserving exact metadata, selection, deletion, order and undo.
  {
    const native = receiver(), q = new Queue(async value => native.apply(value), fail, true)
    ready(q)
    const value = scene(row('a'), row('b'), { id: 'native-object-preview', kind: 'line', data: { points: [] }, extra: { preserve: true } })
    const publish = async () => { q.publish(1, value, 'eraser'); await q.flush(); assert.deepEqual(native.pages.get(1).visible, wire(1, value)) }
    await publish(); assert.equal(native.calls[0].objectPatch.reset, true); assert.equal(native.calls[0].objectPatch.upserts.length, 3)
    await publish(); assert.equal(native.calls.length, 1)
    value.selection = { x: .2, y: .3, width: .4, height: .5 }; value.resizable = true; value.textHandles = true
    await publish(); assert.deepEqual(native.calls.at(-1).objectPatch.upserts, []); assert.deepEqual(native.calls.at(-1).selection, value.selection)
    value.objects[0].data.points[0].p = .875; value.objects[0].future = { 'é': ['e\u0301', 1, false, null] }
    await publish(); assert.deepEqual(native.calls.at(-1).objectPatch.upserts.map(x => x.id), ['a'])
    value.objects[0].future['é'][1] = 9; await publish(); assert.equal(native.calls.at(-1).objectPatch.upserts[0].future['é'][1], 9)
    value.objects.reverse(); await publish(); assert.deepEqual(native.calls.at(-1).objectPatch.upserts, [])
    const removed = value.objects.splice(1, 1)[0]; await publish(); assert.deepEqual(native.calls.at(-1).objectPatch.upserts, [])
    value.objects.splice(1, 0, removed); await publish(); assert.deepEqual(native.calls.at(-1).objectPatch.upserts.map(x => x.id), ['b'])
    value.objects[0].data.points.push({ x: .4, y: .5 }); await publish(); assert.deepEqual(native.calls.at(-1).objectPatch.upserts.map(x => x.id), ['native-object-preview'])
    value.selection = null; value.resizable = false; value.textHandles = false; value.objects = []
    await publish(); assert.deepEqual(native.calls.at(-1).objectPatch.order, []); assert.deepEqual(native.calls.at(-1).objectPatch.upserts, [])
    q.dispose(); groups++
  }

  // Same-turn and in-flight mutation freeze with real 200×96 raw rows. Latest
  // rows are diffed against ACK, not a discarded/prepared intermediate frame.
  {
    const gate = deferred(), native = receiver(); let maximum = 0, concurrent = 0
    const q = new Queue(async value => { concurrent++; maximum = Math.max(maximum, concurrent)
      const reply = native.apply(value); if (native.calls.length === 1) await gate.promise; concurrent--; return reply }, fail, true)
    ready(q)
    const heavy = Array.from({ length: 200 }, (_, i) => ({ ...row(`heavy-${i}`), data: { inkVersion: 4,
      points: Array.from({ length: 96 }, (_, j) => ({ x: j / 100, y: i / 250, p: .25 + j / 160, t: j * 4 })) } }))
    q.publish(1, scene(...heavy), 'eraser'); await turn()
    for (let i = 1; i <= 32; i++) { heavy[199].data.points[0].p = i / 40; q.publish(1, scene(...heavy.slice(i)), 'eraser') }
    const expected = wire(1, scene(...heavy.slice(32))); heavy[199].data.points[0].p = .999
    gate.resolve(); await q.flush()
    assert.equal(maximum, 1); assert.equal(native.calls.length, 2)
    assert.equal(native.calls[1].objectPatch.reset, false); assert.equal(native.calls[1].objectPatch.upserts.length, 1)
    assert.deepEqual(native.pages.get(1).visible, expected)
    q.publish(1, scene(...heavy.slice(32)), 'eraser'); await q.flush()
    assert.equal(native.calls.at(-1).objectPatch.upserts.length, 1)
    assert.deepEqual(native.pages.get(1).visible, wire(1, scene(...heavy.slice(32))))
    const selection = { ...scene(...heavy.slice(32)), selection: { x: .1, y: .2, width: .3, height: .4 }, resizable: true }
    q.publish(1, selection, 'eraser'); await q.flush()
    assert.deepEqual(native.calls.at(-1).objectPatch.upserts, [])
    assert.deepEqual(native.pages.get(1).visible, wire(1, selection))
    const bytes = value => Buffer.byteLength(JSON.stringify(value), 'utf8')
    deltaMetrics.heavy200x96 = { initialRows: 200, pointsPerRow: 96, coalescedPublishes: 32,
      actualRequests: native.calls.length, initialResetBytes: bytes(native.calls[0]),
      latestChangedRowDeltaBytes: bytes(native.calls[1]), equivalentFullSceneBytes: bytes(expected),
      selectionOnlyUpserts: native.calls.at(-1).objectPatch.upserts.length,
      selectionOnlyRequestBytes: bytes(native.calls.at(-1)) }
    q.dispose(); groups++
  }

  // Schema-light rows, pageless previews and Unicode IDs preserve full-scene
  // semantics. Duplicate/missing/empty IDs take versioned full fallback; its
  // ACK invalidates the patch base, so the next eligible frame must reset.
  {
    const native = receiver(), q = new Queue(async value => native.apply(value), fail, true)
    ready(q)
    const cases = [
      { value: scene({ id: 'é' }, { id: 'e\u0301', unknown: [1] }, { id: 'native-object-preview' }), patch: true },
      { value: scene({ kind: 'unknown', data: null }), patch: false },
      { value: scene({ id: '' }), patch: false },
      { value: scene({ id: '\ud800' }, { id: '\ud801' }), patch: false },
      { value: scene({ id: 'a\udc00' }), patch: false },
      { value: scene({ id: 'same' }, { id: 'same', extra: 2 }), patch: false },
      { value: scene({ id: 'native-object-preview' }, { id: 'native-object-preview' }), patch: false },
      { value: scene({ id: 'é' }, { id: 'e\u0301' }, { id: '__proto__' }, { id: '😀' }), patch: true }
    ]
    for (const { value, patch } of cases) {
      q.publish(1, value, 'eraser'); await q.flush()
      const sent = native.calls.at(-1)
      assert.equal(!!sent.objectPatch, patch); assert.deepEqual(native.pages.get(1).visible, wire(1, value))
      if (patch) assert.equal(sent.objectPatch.reset, true)
      else assert.deepEqual(sent.objects, value.objects)
    }
    q.dispose(); groups++
  }

  // A acknowledged, B in flight, revert A: the final delta is based on B's ACK
  // and restores A despite matching an earlier acknowledged full signature.
  {
    const gate = deferred(), native = receiver(), a = scene(row('same', .2)), b = scene(row('same', .8))
    const q = new Queue(async value => { const reply = native.apply(value); if (native.calls.length === 2) await gate.promise; return reply }, fail, true)
    ready(q); q.publish(1, a, 'eraser'); await q.flush()
    q.publish(1, b, 'eraser'); await turn(); q.publish(1, a, 'eraser'); gate.resolve(); await q.flush()
    assert.equal(native.calls.length, 3); assert.equal(native.calls[2].objectPatch.baseRevision, native.calls[1].objectSceneRevision)
    assert.equal(native.calls[2].objectPatch.upserts[0].data.points[0].p, .2)
    assert.deepEqual(native.pages.get(1).visible, wire(1, a)); q.dispose(); groups++
  }

  // Global revisions cross page boundaries, fair service, prune/remount and
  // tool epochs. Old page ACK cannot resurrect its base after remount.
  {
    const gate = deferred(), native = receiver(), errors = []
    const q = new Queue(async value => { const reply = native.apply(value); if (native.calls.length === 1) await gate.promise; return reply }, e => errors.push(e), true)
    ready(q); q.publish(1, scene(row('p1')), 'eraser'); await turn()
    q.publish(2, scene(row('p2')), 'eraser'); q.prunePages(new Set([2])); q.publish(1, scene(row('p1-new')), 'eraser')
    gate.resolve(); await q.flush()
    assert.deepEqual(native.calls.map(x => x.page), [1, 2, 1]); assert.equal(native.calls[2].objectPatch.reset, true)
    q.publish(2, scene(row('p2', .9)), 'eraser'); await q.flush()
    assert.equal(native.calls[3].objectPatch.baseRevision, 2); assert.equal(native.calls[3].objectPatch.revision, 4)
    const oldEpoch = q.observeTool('eraser'); q.observeTool('pen'); q.observeTool('eraser'); q.publish(1, scene(row('p1-new')), 'eraser')
    q.acknowledgeTool(oldEpoch); await turn(); assert.equal(native.calls.length, 4)
    q.acknowledgeTool(q.observeTool('eraser')); await q.flush()
    assert.equal(native.calls.at(-1).objectSceneRevision, 5); assert.equal(native.calls.at(-1).objectPatch.reset, true)
    assert.equal(errors.length, 0); q.dispose(); groups++
  }

  // Unknown outcome includes lost transport replies and structurally invalid
  // ACKs. Native may have applied already: retry latest with a NEWER reset.
  for (const failure of ['lost', 'empty', 'page', 'epoch', 'revision', 'boolean', 'string', 'unsafe']) {
    const native = receiver(), errors = []
    const q = new Queue(async value => {
      const reply = native.apply(value)
      if (native.calls.length !== 2) return reply
      if (failure === 'lost') throw new Error('reply lost after apply')
      if (failure === 'empty') return {}
      if (failure === 'boolean') return { ...reply, objectSceneRevision: true }
      if (failure === 'string') return { ...reply, objectSceneRevision: String(reply.objectSceneRevision) }
      if (failure === 'unsafe') return { ...reply, objectSceneRevision: Number.MAX_SAFE_INTEGER + 1 }
      const field = { page: 'page', epoch: 'objectSceneEpoch', revision: 'objectSceneRevision' }[failure]
      return { ...reply, [field]: reply[field] + 1 }
    }, e => errors.push(e), true)
    ready(q); q.publish(1, scene(row('a')), 'eraser'); await q.flush()
    const value = scene(row('a', .8)); q.publish(1, value, 'eraser'); await q.flush()
    assert.equal(native.calls.length, 3); assert.equal(native.calls[1].objectPatch.reset, false)
    assert.equal(native.calls[2].objectPatch.reset, true); assert.equal(native.calls[2].objectPatch.baseRevision, 0)
    assert.ok(native.calls[2].objectSceneRevision > native.calls[1].objectSceneRevision)
    assert.deepEqual(native.pages.get(1).visible, wire(1, value)); assert.equal(errors.length, 0)
    q.dispose(); groups++
  }

  {
    const calls = [], errors = []; let retry, failing = true
    const q = new Queue(async value => { calls.push(clone(value)); return failing ? {} : sceneAck(value) }, (e, r) => { errors.push(e); retry = r }, true)
    ready(q); q.publish(1, scene(null, ['not-a-row']), 'eraser')
    await assert.rejects(q.flush(), /응답/)
    assert.equal(calls.length, 2); assert.equal(errors.length, 1); assert.ok(calls.every(x => !x.objectPatch))
    for (let i = 0; i < 20; i++) q.publish(1, scene(row('latest', i / 20)), 'eraser')
    await turn(); assert.equal(calls.length, 2, 'No automatic retry loop after terminal failure')
    failing = false; await retry(); assert.equal(calls.length, 3); assert.equal(calls[2].objectPatch.reset, true)
    assert.equal(calls[2].objectPatch.upserts[0].data.points[0].p, .95)
    q.dispose(); groups++
  }

  // The real canonical snapshot publisher coalesces its callers' promises.
  // Gate using its ACTUAL send/ACK, including a held old snapshot and tool ABA.
  {
    const first = deferred(), newest = deferred(), sends = [], calls = [], errors = []
    const q = new Queue(async value => { calls.push(clone(value)); return sceneAck(value) }, e => errors.push(e), true)
    q.resume('eraser')
    const publisher = new Snapshots(payload => q.sendSnapshot(payload, async wire => {
      sends.push(clone(wire)); if (sends.length === 1) await first.promise; else if (sends.length === 2) await newest.promise
      return { objectSceneEpoch: wire.objectSceneEpoch, tool: wire.tool.name }
    }))
    const publishTool = tool => publisher.publish({ tool: { name: tool }, objectSceneEpoch: q.observeTool(tool) }, [])
    const old = publishTool('eraser'); await turn()
    publishTool('pen'); const latest = publishTool('eraser')
    q.publish(1, scene(row('new-epoch')), 'eraser'); await turn(); assert.equal(calls.length, 0)
    first.resolve(); await turn()
    assert.equal(sends.length, 2); assert.equal(calls.length, 0, 'Valid old actual ACK cannot unlock the new epoch')
    assert.equal(sends[1].tool.name, 'eraser'); assert.ok(sends[1].objectSceneEpoch > sends[0].objectSceneEpoch)
    newest.resolve(); await Promise.all([old, latest]); await q.flush()
    assert.equal(calls.length, 1); assert.equal(calls[0].objectSceneEpoch, sends[1].objectSceneEpoch)
    assert.equal(errors.length, 0); q.dispose(); publisher.dispose(); groups++
  }

  // Retired versioned requests cannot ACK a resumed epoch or leak queued
  // scenes after close. The new session owns its own revision namespace.
  for (const rejectOld of [false, true]) {
    const gate = deferred(), calls = [], errors = []
    const q = new Queue(async value => { calls.push(clone(value)); if (calls.length === 1) await gate.promise; return sceneAck(value) }, e => errors.push(e), true)
    ready(q); q.publish(1, scene(row('old')), 'eraser'); await turn()
    q.pause(); q.resume('eraser'); const epoch = q.observeTool('eraser')
    q.publish(1, scene(row('resumed')), 'eraser')
    await q.sendSnapshot({ objectSceneEpoch: epoch, tool: { name: 'eraser' } }, async wire => ({ objectSceneEpoch: wire.objectSceneEpoch, tool: 'eraser' }))
    if (rejectOld) gate.reject(new Error('retired outcome')); else gate.resolve()
    await q.flush(); assert.equal(calls.length, 2); assert.equal(calls[1].objectPatch.reset, true)
    assert.ok(calls[1].objectSceneRevision > calls[0].objectSceneRevision); assert.equal(errors.length, 0)
    q.dispose(); const fresh = [], reopened = new Queue(async value => { fresh.push(clone(value)); return sceneAck(value) }, fail, true)
    ready(reopened); reopened.publish(1, scene(row('resumed')), 'eraser'); await reopened.flush()
    assert.equal(fresh[0].objectPatch.reset, true); assert.equal(fresh[0].objectSceneRevision, 1)
    q.publish(1, scene(row('after-close')), 'eraser'); await q.retry(); assert.equal(calls.length, 2)
    reopened.dispose(); groups++
  }

  // Bad snapshot ACK never opens the gate; a valid later snapshot can recover.
  for (const reply of [{}, { objectSceneEpoch: true, tool: 'eraser' }, { objectSceneEpoch: 1, tool: 'pen' }]) {
    const calls = [], q = new Queue(async value => { calls.push(value); return sceneAck(value) }, fail, true)
    q.resume('eraser'); const epoch = q.observeTool('eraser')
    q.publish(1, scene(row('held')), 'eraser')
    await assert.rejects(q.sendSnapshot({ objectSceneEpoch: epoch, tool: { name: 'eraser' } }, async () => reply), /도구 응답/)
    await q.flush(); assert.equal(calls.length, 0)
    await q.sendSnapshot({ objectSceneEpoch: epoch, tool: { name: 'eraser' } }, async wire => ({ objectSceneEpoch: wire.objectSceneEpoch, tool: wire.tool.name }))
    await q.flush(); assert.equal(calls.length, 1); q.dispose(); groups++
  }

  // Exhaustion cannot reuse an epoch or silently wrap a scene revision. These
  // synthetic boundaries would require far more operations than an app lifetime.
  {
    const calls = [], q = new Queue(async value => { calls.push(value); return sceneAck(value) }, () => {}, true)
    ready(q); q.issuedRevision = Number.MAX_SAFE_INTEGER
    q.publish(1, scene(row('limit')), 'eraser'); await assert.rejects(q.flush(), /버전 한도/)
    assert.equal(calls.length, 0); q.dispose()
    const exhausted = new Queue(async value => { calls.push(value); return sceneAck(value) }, fail, true)
    ready(exhausted); exhausted.epoch = Number.MAX_SAFE_INTEGER
    assert.throws(() => exhausted.observeTool('select'), /버전 한도/)
    exhausted.acknowledgeTool(Number.MAX_SAFE_INTEGER)
    exhausted.publish(1, scene(row('cannot-reuse')), 'select'); await exhausted.flush(); assert.equal(calls.length, 0)
    groups++
  }

  // Capability absence keeps old wire requests and old empty ACK semantics.
  // Configure-before-active is explicit; native does not receive the local epoch.
  {
    const calls = [], q = new Queue(async value => { calls.push(clone(value)); return {} }, fail)
    q.configurePatch(false); q.resume('eraser'); const epoch = q.observeTool('eraser')
    q.publish(1, scene(row('legacy')), 'eraser')
    await q.sendSnapshot({ objectSceneEpoch: epoch, tool: { name: 'eraser' } }, async wire => { assert.ok(!('objectSceneEpoch' in wire)); return {} })
    await q.flush(); assert.deepEqual(calls, [wire(1, scene(row('legacy')))])
    assert.throws(() => q.configurePatch(true), /너무 늦/)
    q.dispose(); groups++
  }
  console.log(`Object scene delta wire metrics: ${JSON.stringify(deltaMetrics)}`)
  console.log(`Object scene queue: ${groups} groups PASS; exact full-payload dedupe, 200×96 overlap/latest, mutable input freeze, selection/preview/delete/order, fair pages/pruning, real snapshot publisher ACK gate, tool epochs, bounded error/retry, close/reopen, actual transformed replay effect, actual hook single passive snapshot preparation; versioned delta/reset/fallback, exact mutable JSON, Unicode IDs, ACK-based diff, global revisions/page remount, lost/mismatched ACK recovery, actual-send coalesced snapshot epoch gates.`)
} finally { await rm(folder, { recursive: true, force: true }) }
