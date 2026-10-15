import assert from 'node:assert/strict'
import vm from 'node:vm'
import { performance } from 'node:perf_hooks'
import { createRequire } from 'node:module'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'

const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild')
const built = await build({ stdin: { resolveDir: runtime, loader: 'ts', contents: `
  export { IncrementalInkPathV4, IncrementalInkPathV5 } from './renderer/pencil/livePreview';
  export { strokePathV4, predictionPolygonsV4 } from './upstream/src/shared/inkV4';
  export { strokePathV5, predictionPolygonsV5 } from './upstream/src/shared/inkV5';
  export { pencilPredictions } from './renderer/pencil/samples';
` }, bundle: true, write: false, format: 'cjs', platform: 'node' })
const context = { module: { exports: {} } }
vm.runInNewContext(built.outputFiles[0].text, context)
const { IncrementalInkPathV4, IncrementalInkPathV5, strokePathV4, strokePathV5, predictionPolygonsV4, predictionPolygonsV5, pencilPredictions } = context.module.exports

// Every prefix must exactly match the renderer/export geometry, across pressure
// ramps, repeated positions, zero/missing/backwards time and very sparse input.
const polygonPath = polygons => polygons.map(polygon => polygon.map(([x, y], i) => `${i === 0 ? 'M' : 'L'} ${x} ${y}`).join(' ') + ' Z').join(' ')
const points = Array.from({ length: 160 }, (_, i) => ({
  x: 0.1 + Math.floor(i / 2) * 0.004, y: 0.3 + Math.sin(i / 7) * 0.15,
  p: i % 13 === 0 ? 0 : (i % 17) / 16,
  ...(i % 11 === 0 ? {} : { t: i * 4 + [0, 0, 2, -12, 80][i % 5] })
}))
for (const [Builder, fullPath, predictionsPath] of [[IncrementalInkPathV4, strokePathV4, predictionPolygonsV4], [IncrementalInkPathV5, strokePathV5, predictionPolygonsV5]]) for (const highlighter of [false, true]) for (const aspect of [0.5, Math.SQRT2, 2.1]) {
  const builder = new Builder(0.003, aspect, highlighter)
  let settled = ''
  for (let i = 0; i < points.length; i++) {
    const measured = points.slice(0, i + 1)
    const path = builder.update(measured)
    assert.equal(path, fullPath(measured, 0.003, aspect, highlighter),
      `canonical geometry prefix ${i}, aspect ${aspect}, highlighter ${highlighter}`)
    assert.ok(builder.settledPath.startsWith(settled), 'Settled measured prefix remains unchanged')
    settled = builder.settledPath
    const predictions = [{ x: 0.95, y: 0.95, p: 1, t: 10000 }, { x: .96, y: .93, p: 0, t: 10004 }]
    assert.equal(builder.predictionPath(predictions), polygonPath(predictionsPath(measured, predictions, .003, aspect, highlighter)))
    assert.equal(builder.measuredPath, path, 'Predictions never reshape measured curves')
    assert.equal(builder.predictionPath(predictions.map(p => ({ ...p, p: NaN }))), builder.predictionPath(predictions), 'Predicted pressure never introduces width jitter')
    assert.equal(builder.predictionPath([]), '')
  }
}

const fake = (timeStamp, pointerId = 8) => ({ timeStamp, pointerId, clientX: timeStamp, clientY: 4, pressure: 0.6 })
const event = { ...fake(100), pointerType: 'pen', getPredictedEvents: () => [
  fake(99), fake(104), fake(104), fake(108, 9), fake(112), fake(500)
] }
assert.deepEqual(Array.from(pencilPredictions(event), p => p.timestamp), [104, 112])
assert.equal(pencilPredictions({ ...event, pointerType: 'mouse' }).length, 0)
assert.equal(pencilPredictions({ ...event, getPredictedEvents: () => { throw new Error('Unavailable WebKit API') } }).length, 0)
assert.equal(pencilPredictions({ ...event, getPredictedEvents: undefined }).length, 0)
assert.equal(pencilPredictions({ ...event, getPredictedEvents: () => Array.from({ length: 24 }, (_, i) => fake(101 + i)) }).length, 8)

const long = Array.from({ length: 960 }, (_, i) => ({ x: i / 1000, y: 0.3 + Math.sin(i / 20) * 0.1, p: 0.3 + i % 7 / 10, t: i * 4 }))
for (const [version, Builder, fullPath] of [[4,IncrementalInkPathV4,strokePathV4],[5,IncrementalInkPathV5,strokePathV5]]) {
  let oldPath
  let start = performance.now()
  for (let i = 8; i <= long.length; i += 8) oldPath = fullPath(long.slice(0, i), 0.003, 1.5, false)
  const fullMs = performance.now() - start
  const builder = new Builder(0.003, 1.5, false)
  start = performance.now()
  for (let i = 8; i <= long.length; i += 8) builder.update(long.slice(0, i))
  const incrementalMs = performance.now() - start
  assert.equal(builder.measuredPath, oldPath)
  if(version===5) assert.ok(builder.generatedSegments <= long.length+120*16, 'bounded 16-segment tail plus newly settled segments')
  console.log(`v${version} live geometry: 960 samples / 120 updates, full-prefix ${fullMs.toFixed(1)}ms → incremental ${incrementalMs.toFixed(1)}ms; settled prefixes and prediction isolation exact (host CPU benchmark)`)
}
