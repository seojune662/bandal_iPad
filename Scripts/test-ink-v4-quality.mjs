#!/usr/bin/env node
// Run: node Scripts/test-ink-v4-quality.mjs [--source /path/to/bandal]
// Default uses the shipped DesktopRuntime/upstream snapshot. --source validates
// canonical work before the snapshot is refreshed. Optional --report saves JSON.
// Synthetic geometry checks do not measure physical Pencil latency or establish
// superiority over another app; see docs/handwriting-quality.md for device work.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { dependencies } from '../DesktopRuntime/scripts/dependencies.mjs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const args = process.argv.slice(2)
const option = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1] }
const source = resolve(option('--source') ?? resolve(root, 'DesktopRuntime/upstream'))
const reportPath = option('--report')
const fixturePath = resolve(root, 'docs/fixtures/ink-v4-quality.json')
const fixtures = JSON.parse(await readFile(fixturePath, 'utf8'))
assert.equal(fixtures.schemaVersion, 1)
assert.equal(new Set(fixtures.cases.map(item => item.id)).size, fixtures.cases.length)
const temporary = await mkdtemp(resolve(tmpdir(), 'bandal-ink-v4-quality-'))

// This runner invokes production Swift geometry. The only adaptation is adding
// the initial sample because Swift's streaming API emits new endpoints only.
const swiftRunner = String.raw`
import Foundation
import CoreGraphics
struct FixtureFile: Decodable { let cases: [Fixture] }
struct Fixture: Decodable {
    let id: String
    let width: Double
    let aspect: Double
    let highlighter: Bool
    let points: [NativePDFPoint]
    let predictions: [NativePDFPoint]?
}
func vector(_ point: CGPoint) -> [Double] { [point.x, point.y] }
func sample(_ point: NativePDFInkGeometryV4.Sample) -> [Double] { [point.x, point.y, point.p] }
func controls(_ points: [NativePDFPoint], _ index: Int, _ aspect: Double) -> [[Double]] {
    let a = points[index], b = points[index + 1]
    let p1 = CGPoint(x: a.x, y: a.y * aspect), p2 = CGPoint(x: b.x, y: b.y * aspect)
    let p0 = index > 0 ? CGPoint(x: points[index - 1].x, y: points[index - 1].y * aspect)
        : CGPoint(x: 2 * p1.x - p2.x, y: 2 * p1.y - p2.y)
    let p3 = index + 2 < points.count ? CGPoint(x: points[index + 2].x, y: points[index + 2].y * aspect)
        : CGPoint(x: 2 * p2.x - p1.x, y: 2 * p2.y - p1.y)
    let c = NativePDFInkGeometryV4.controlPoints(p0: p0, p1: p1, p2: p2, p3: p3)
    return [vector(p1), vector(c.cp1), vector(c.cp2), vector(p2)]
}
func segments(_ points: [NativePDFPoint], _ width: Double, _ aspect: Double) -> [[[Double]]] {
    let pressures = NativePDFInkGeometryV3.filteredPressures(points)
    return (0..<max(0, points.count - 1)).map { index in
        var result = [[points[index].x, points[index].y, pressures[index]]]
        NativePDFInkGeometryV4.forEachSegmentSample(points: points, pressures: pressures, index: index,
                                                   width: width, aspect: aspect) { result.append(sample($0)) }
        return result
    }
}
let file = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let result: [[String: Any]] = file.cases.map { f in
    let pressures = NativePDFInkGeometryV3.filteredPressures(f.points)
    let split = segments(f.points, f.width, f.aspect)
    var centerline: [[Double]] = []
    if let first = f.points.first { centerline.append([first.x, first.y, pressures[0]]) }
    for segment in split { centerline.append(contentsOf: segment.dropFirst()) }
    let polygons = NativePDFInkGeometryV4.polygons(points: f.points, width: f.width, aspect: f.aspect, highlighter: f.highlighter)
    var predictions: [[[Double]]] = []
    if let last = f.points.last {
        NativePDFInkGeometryV4.forEachPredictionPolygon(lastPoint: last, pressure: pressures.last!,
            predictions: f.predictions ?? [], width: f.width, aspect: f.aspect,
            highlighter: f.highlighter) { predictions.append($0.map(vector)) }
    }
    return ["id": f.id, "pressures": pressures, "segments": split, "centerline": centerline,
            "controls": (0..<max(0, f.points.count - 1)).map { controls(f.points, $0, f.aspect) },
            "polygons": polygons.map { $0.map(vector) }, "predictions": predictions,
            "prefixSegments": (0...f.points.count).map { segments(Array(f.points.prefix($0)), f.width, f.aspect) }]
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
`

const metric = (point, aspect) => [point[0], point[1] * aspect]
const minus = (a, b) => a.map((value, i) => value - b[i])
const length = a => Math.hypot(...a)
const dot = (a, b) => a.reduce((sum, value, i) => sum + value * b[i], 0)
const lerp = (a, b, t) => a.map((value, i) => value + (b[i] - value) * t)
const raw = points => points.map(point => [point.x, point.y])
const sample = point => [point.x, point.y, point.p]
const close = (a, b, label, epsilon = 1e-12) => assert.ok(Math.abs(a - b) <= epsilon, `${label}: ${a} != ${b}`)
const distanceToSegment = (p, a, b) => {
  const edge = minus(b, a), denominator = dot(edge, edge)
  const t = denominator === 0 ? 0 : Math.max(0, Math.min(1, dot(minus(p, a), edge) / denominator))
  return length(minus(p, lerp(a, b, t)))
}
const distanceToPolyline = (point, points) => points.length < 2 ? length(minus(point, points[0])) :
  Math.min(...points.slice(1).map((end, i) => distanceToSegment(point, points[i], end)))
const angle = (before, after) => Math.acos(Math.max(-1, Math.min(1, dot(before, after) / (length(before) * length(after)))))
const cubicAt = (controls, t) => {
  const a = lerp(controls[0], controls[1], t), b = lerp(controls[1], controls[2], t), c = lerp(controls[2], controls[3], t)
  return lerp(lerp(a, b, t), lerp(b, c, t), t)
}

// Independent Barry-Goldman recursion (no Bezier/Hermite control formula).
// Restricted to the nondegenerate smooth fixtures, where the safety guards
// intentionally leave the mathematically correct centripetal curve unchanged.
const barryGoldman = (points, u) => {
  const times = [0]
  for (let i = 1; i < 4; i++) times.push(times[i - 1] + Math.sqrt(length(minus(points[i], points[i - 1]))))
  const t = times[1] + u * (times[2] - times[1])
  const blend = (a, b, start, end) => lerp(a, b, (t - start) / (end - start))
  const a = points.slice(1).map((point, i) => blend(points[i], point, times[i], times[i + 1]))
  const b = [blend(a[0], a[1], times[0], times[2]), blend(a[1], a[2], times[1], times[3])]
  return blend(b[0], b[1], times[1], times[2])
}

// The pressure oracle is evaluated at the ORIGINAL sampling rate, including
// duplicate positions and zero/backwards/missing timestamp deltas.
const pressureOracle = points => {
  if (!points.length) return []
  const result = [Math.max(0, Math.min(1, points[0].p))]
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1], b = points[i]
    const dt = Number.isFinite(a.t) && Number.isFinite(b.t) ? Math.max(0, Math.min(32, b.t - a.t)) : 4
    result.push(result[i - 1] + -Math.expm1(-dt / 24) * (Math.max(0, Math.min(1, b.p)) - result[i - 1]))
  }
  return result
}

let comparisons = 0
let maximumParityError = 0
function sameNumbers(a, b, label, epsilon = 1e-12) {
  if (Array.isArray(a)) {
    assert.ok(Array.isArray(b), label)
    assert.equal(a.length, b.length, `${label} length`)
    a.forEach((value, i) => sameNumbers(value, b[i], `${label}[${i}]`, epsilon))
  } else {
    assert.ok(Number.isFinite(a) && Number.isFinite(b), `${label} finite`)
    maximumParityError = Math.max(maximumParityError, Math.abs(a - b))
    comparisons++
    close(a, b, label, epsilon)
  }
}

function validateFixture(f, out) {
  const expected = f.expectation, pressures = out.pressures
  sameNumbers(pressures, pressureOracle(f.points), `${f.id} raw pressure`)
  assert.equal(out.segments.length, Math.max(0, f.points.length - 1))
  if (!f.points.length) {
    assert.equal(out.centerline.length, 0); assert.equal(out.polygons.length, 0)
    return { id: f.id, centerlineSamples: 0, polygons: 0 }
  }
  assert.deepEqual(out.centerline[0], [f.points[0].x, f.points[0].y, pressures[0]], `${f.id} first exact`)
  const last = f.points.at(-1)
  assert.deepEqual(out.centerline.at(-1), [last.x, last.y, pressures.at(-1)], `${f.id} last exact`)
  for (let i = 0; i < out.segments.length; i++) {
    const segment = out.segments[i], a = f.points[i], b = f.points[i + 1]
    assert.ok(segment.length >= 2 && segment.length <= 33, `${f.id} bounded work per raw segment`)
    assert.deepEqual(segment[0], [a.x, a.y, pressures[i]], `${f.id} start knot ${i}`)
    assert.deepEqual(segment.at(-1), [b.x, b.y, pressures[i + 1]], `${f.id} end knot ${i}`)
    for (const point of segment) assert.ok(point[2] >= Math.min(pressures[i], pressures[i + 1]) - 1e-15 &&
      point[2] <= Math.max(pressures[i], pressures[i + 1]) + 1e-15, `${f.id} pressure interpolation ${i}`)
    const controls = out.controls[i], chord = minus(controls[3], controls[0]), size = length(chord)
    for (const [handle, sign] of [[minus(controls[1], controls[0]), 1], [minus(controls[3], controls[2]), 1]]) {
      assert.ok(length(handle) <= 0.5 * size + 1e-12, `${f.id} handle length`)
      assert.ok(dot(handle, chord) * sign >= -1e-12, `${f.id} forward handle`)
      assert.ok(Math.abs(handle[0] * chord[1] - handle[1] * chord[0]) <= 0.25 * size * size + 1e-12, `${f.id} normal handle`)
    }
  }
  // Appending a measured sample may only replace the previous trailing segment;
  // existing stable segments, their pressure and vertex order remain identical.
  for (let count = 2; count < out.prefixSegments.length; count++) {
    const before = out.prefixSegments[count - 1], after = out.prefixSegments[count]
    for (let i = 0; i < Math.max(0, before.length - 1); i++) assert.deepEqual(after[i], before[i], `${f.id} stable prefix ${count}/${i}`)
    assert.ok(after.length > 0 && after.at(-1).length >= 2, `${f.id} immediate tail ${count}`)
  }
  const disks = out.polygons.filter(polygon => polygon.length === 32)
  assert.equal(disks.length, out.centerline.length, `${f.id} pressure-only samples retained as disks`)
  for (let i = 0; i < disks.length; i++) {
    const point = out.centerline[i], radius = f.width * (f.highlighter ? 1 : 0.42 + 0.20 * point[2]) / 2
    close(disks[i][0][0] - point[0], radius, `${f.id} once-filtered disk radius ${i}`)
    close(disks[i][0][1], point[1], `${f.id} disk center y ${i}`)
  }
  for (const polygon of [...out.polygons, ...out.predictions]) {
    assert.ok(polygon.length === 4 || polygon.length === 32, `${f.id} convex piece size`)
    assert.ok(polygon.flat().every(Number.isFinite), `${f.id} finite polygons`)
    const area = polygon.reduce((sum, a, i) => { const b = polygon[(i + 1) % polygon.length]; return sum + a[0] * b[1] - a[1] * b[0] }, 0)
    assert.ok(area >= -1e-14, `${f.id} consistent nonzero-fill winding`)
  }
  if (f.predictions) {
    const predictionDisks = out.predictions.filter(polygon => polygon.length === 32)
    assert.equal(predictionDisks.length, Math.min(8, f.predictions.length), `${f.id} bounded prediction count`)
    for (let i = 0; i < predictionDisks.length; i++) close(predictionDisks[i][0][0] - f.predictions[i].x,
      f.width * (f.highlighter ? 1 : 0.42 + 0.20 * pressures.at(-1)) / 2, `${f.id} prediction pressure isolation`)
  }
  const summary = { id: f.id, centerlineSamples: out.centerline.length, polygons: out.polygons.length }
  if (expected.kind === 'polyline' || expected.kind === 'stationary') {
    const reference = raw(f.points).map(point => metric(point, f.aspect))
    summary.maximumCornerDeviation = Math.max(...out.centerline.map(point => distanceToPolyline(metric(point, f.aspect), reference)))
    assert.ok(summary.maximumCornerDeviation <= 1e-12, `${f.id} preserves straight/corner segments`)
  }
  if (expected.maxCenterlinePoints) assert.ok(out.centerline.length <= expected.maxCenterlinePoints, `${f.id} immediate line`)
  if (expected.control) {
    sameNumbers(out.controls[expected.control.index][1], expected.control.control1, `${f.id} analytical first control`)
    sameNumbers(out.controls[expected.control.index][2], expected.control.control2, `${f.id} analytical second control`)
  }
  if (expected.kind === 'inflection') {
    const controls = out.controls[expected.segment], middle = cubicAt(controls, 0.5)
    close(distanceToSegment(middle, controls[0], controls[3]), 0, `${f.id} midpoint trap`)
    assert.ok(distanceToSegment(controls[1], controls[0], controls[3]) > 1e-4, `${f.id} off-chord first handle`)
    assert.ok(distanceToSegment(controls[2], controls[0], controls[3]) > 1e-4, `${f.id} off-chord second handle`)
    assert.ok(out.segments[expected.segment].length > 3, `${f.id} both handles drive subdivision`)
    assert.ok(out.segments[expected.segment].some(point => distanceToSegment(metric(point, f.aspect), controls[0], controls[3]) > 1e-4), `${f.id} inflection survives`)
  }
  if (expected.kind === 'circle') {
    const reference = raw(f.points).map(point => metric(point, f.aspect)), rendered = out.centerline.map(point => metric(point, f.aspect))
    const truth = Array.from({ length: 2048 }, (_, i) => [expected.center[0] + expected.radius * Math.cos(2 * Math.PI * i / 2048),
      expected.center[1] + expected.radius * Math.sin(2 * Math.PI * i / 2048)])
    const errors = line => truth.map(point => distanceToPolyline(point, line))
    const before = errors(reference), after = errors(rendered)
    summary.rawChordMaximumError = Math.max(...before)
    summary.v4MaximumError = Math.max(...after)
    summary.v4RMSError = Math.sqrt(after.reduce((sum, value) => sum + value * value, 0) / after.length)
    summary.errorRatio = summary.v4MaximumError / summary.rawChordMaximumError
    // Reflected first/last tangents deliberately work without future input.
    // Report their error as part of the whole curve, and separately measure
    // interior intervals with four measured neighbors. Never hide endpoint cost.
    const interior = after.filter((_, i) => i >= 2048 / (f.points.length - 1) && i <= 2048 * (f.points.length - 2) / (f.points.length - 1))
    summary.interiorMaximumError = Math.max(...interior)
    summary.interiorErrorRatio = summary.interiorMaximumError / summary.rawChordMaximumError
    assert.ok(summary.errorRatio < expected.maxErrorRatio, `${f.id} improves sparse circle error: ${summary.errorRatio}`)
    assert.ok(summary.v4MaximumError < expected.maximumError, `${f.id} absolute circle error: ${summary.v4MaximumError}`)
    assert.ok(summary.interiorErrorRatio < expected.maxInteriorErrorRatio, `${f.id} interior circle error: ${summary.interiorErrorRatio}`)
    const jumps = out.segments.slice(1).map((segment, i) => {
      const previous = out.segments[i], before = previous.slice(-2).map(point => metric(point, f.aspect)), after = segment.slice(0, 2).map(point => metric(point, f.aspect))
      return angle(minus(before[1], before[0]), minus(after[1], after[0]))
    })
    summary.maximumKnotTangentJumpDegrees = Math.max(...jumps) * 180 / Math.PI
    assert.ok(summary.maximumKnotTangentJumpDegrees < 0.5 * 360 / (f.points.length - 1), `${f.id} smoother tangent joins`)
    let maximumOracleError = 0
    for (let i = 1; i + 2 < reference.length; i++) for (const t of [0.125, 0.25, 0.5, 0.75, 0.875]) {
      maximumOracleError = Math.max(maximumOracleError, length(minus(cubicAt(out.controls[i], t), barryGoldman(reference.slice(i - 1, i + 3), t))))
    }
    summary.maximumBarryGoldmanError = maximumOracleError
    assert.ok(maximumOracleError < 1e-12, `${f.id} independent centripetal oracle`)
  }
  return summary
}

try {
  const { require } = dependencies()
  const { build } = createRequire(require.resolve('vite'))('esbuild')
  const bundle = resolve(temporary, 'ink-v4.cjs')
  await build({ entryPoints: [resolve(source, 'src/shared/inkV4.ts')], outfile: bundle, bundle: true, platform: 'node', format: 'cjs', logLevel: 'silent' })
  const v4 = createRequire(import.meta.url)(bundle)
  const js = fixtures.cases.map(f => {
    const segments = points => [...v4.strokeSegmentsV4(points, f.width, f.aspect)].map(segment => segment.samples.map(sample))
    return { id: f.id, pressures: pressureOracle(f.points), segments: segments(f.points),
      controls: f.points.slice(1).map((_, index) => { const c = v4.cubicControlsV4(f.points, index, f.aspect); return [c.start, c.control1, c.control2, c.end] }),
      centerline: v4.strokeCenterlineV4(f.points, f.width, f.aspect).map(sample),
      polygons: v4.strokePolygonsV4(f.points, f.width, f.aspect, f.highlighter),
      predictions: v4.predictionPolygonsV4(f.points, f.predictions ?? [], f.width, f.aspect, f.highlighter),
      prefixSegments: Array.from({ length: f.points.length + 1 }, (_, count) => segments(f.points.slice(0, count))) }
  })
  const runner = resolve(temporary, 'main.swift'), binary = resolve(temporary, 'ink-v4-native')
  await writeFile(runner, swiftRunner)
  execFileSync('xcrun', ['swiftc', '-O', resolve(root, 'App/Desktop/PDF/NativePDFTypes.swift'),
    resolve(root, 'App/Desktop/PDF/NativePDFInkGeometryV3.swift'), resolve(root, 'App/Desktop/PDF/NativePDFInkGeometryV4.swift'), runner, '-o', binary],
  { stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000 })
  const native = JSON.parse(execFileSync(binary, [fixturePath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 60000 }))
  assert.equal(native.length, js.length)
  const results = []
  for (let i = 0; i < fixtures.cases.length; i++) {
    const f = fixtures.cases[i]
    assert.equal(native[i].id, f.id)
    for (const key of ['pressures', 'segments', 'controls', 'centerline', 'polygons', 'predictions', 'prefixSegments'])
      sameNumbers(native[i][key], js[i][key], `${f.id} Swift/TypeScript ${key}`)
    results.push(validateFixture(f, js[i]))
    // Native output is independently checked too, including exact input knots.
    validateFixture(f, native[i])
  }
  for (const f of fixtures.cases.filter(item => item.expectation.metricEquivalent)) {
    const other = fixtures.cases.find(item => item.id === f.expectation.metricEquivalent)
    const a = js.find(item => item.id === f.id).centerline, b = js.find(item => item.id === other.id).centerline
    sameNumbers(a.map(point => [point[0] - f.expectation.center[0], point[1] * f.aspect - f.expectation.center[1], point[2]]),
      b.map(point => [point[0] - other.expectation.center[0], point[1] * other.aspect - other.expectation.center[1], point[2]]), `${f.id} metric invariance`)
  }
  const report = { schemaVersion: 1, source, fixture: fixturePath, fixtureCount: fixtures.cases.length,
    numericComparisons: comparisons, maximumParityError, results,
    limitation: 'Synthetic geometry only. Physical latency, real handwriting preference and competing apps require the hardware protocol in docs/handwriting-quality.md.' }
  if (reportPath) await writeFile(resolve(reportPath), `${JSON.stringify(report, null, 2)}\n`)
  console.log(JSON.stringify(report, null, 2))
} finally {
  await rm(temporary, { recursive: true, force: true })
}
