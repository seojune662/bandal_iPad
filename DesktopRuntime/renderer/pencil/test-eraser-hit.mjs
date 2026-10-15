import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { createRequire } from 'node:module'
import { resolve, dirname } from 'node:path'
import { pathToFileURL } from 'node:url'
import { createHash } from 'node:crypto'
import { performance } from 'node:perf_hooks'
import { transformInkLayer } from './index.mjs'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'

const { require } = dependencies(), ts = require('typescript')
const { build } = createRequire(require.resolve('vite/package.json'))('esbuild')
const hash = data => createHash('sha256').update(data).digest('hex')
const benchmark = process.argv.includes('--benchmark')
if (process.argv.slice(2).some(arg => arg !== '--benchmark')) throw new Error('Usage: node renderer/pencil/test-eraser-hit.mjs [--benchmark]')
const folder = await mkdtemp(resolve(tmpdir(), 'bandal-eraser-hit-'))
try {
const helper = resolve(runtime, 'renderer/pencil/eraserHitCache.ts')
const upstream = resolve(runtime, 'upstream')
const inputFiles = [helper, resolve(runtime, 'renderer/pencil/index.mjs'),
  ...['src/renderer/src/features/ink/InkLayer.tsx','src/renderer/src/features/ink/inkGeometry.ts',
    'src/renderer/src/features/pdf/tools/DrawingLayer.tsx','src/shared/inkV5.ts','src/shared/inkV4.ts','src/shared/inkV3.ts','src/shared/inkV2.ts'].map(name=>resolve(upstream,name))]
const manifest = await Promise.all(inputFiles.map(async source=>({source,sha256:hash(await readFile(source))})))
const options = { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler,
  strict: true, noEmit: true, skipLibCheck: true, noUncheckedIndexedAccess: true, lib: ['lib.es2022.d.ts', 'lib.dom.d.ts'] }
const host = ts.createCompilerHost(options)
host.resolveModuleNames = (names, containing) => names.map(name =>
  ts.resolveModuleName(name, containing, options, host).resolvedModule ??
  ts.resolveModuleName(name, resolve(runtime, 'module-resolution.ts'), options, host).resolvedModule)
const diagnostics = ts.getPreEmitDiagnostics(ts.createProgram([helper], options, host))
assert.deepEqual(diagnostics.map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')), [], 'helper strict typecheck')

await build({ stdin: { contents: `export {EraserGestureHitCache} from ${JSON.stringify(helper)}; export {drawingHit} from ${JSON.stringify(resolve(upstream, 'src/renderer/src/features/ink/inkGeometry.ts'))};`,
  resolveDir: folder, loader: 'ts' }, outfile: resolve(folder, 'probe-module.mjs'), bundle: true,
  format: 'esm', platform: 'node', target: 'es2022', nodePaths: [resolve(runtime, 'node_modules')] })
await build({ stdin: { contents: `export {EraserGestureHitCache} from ${JSON.stringify(helper)}; export {drawingHit} from ${JSON.stringify(resolve(upstream, 'src/renderer/src/features/ink/inkGeometry.ts'))};`,
  resolveDir: folder, loader: 'ts' }, outfile: resolve(folder, 'probe-counted.mjs'), bundle: true,
  format: 'esm', platform: 'node', target: 'es2022', nodePaths: [resolve(runtime, 'node_modules')],
  plugins: [{ name:'count-actual-centerline-entry',setup(b) {
    b.onLoad({filter:/\/inkV4\.ts$/},async args=>{
      const source=await readFile(args.path,'utf8')
      const anchor='export function strokeCenterlineV4(points: readonly DrawingPoint[], width: number, aspect: number): InkRenderSampleV4[] {'
      assert.equal(source.split(anchor).length-1,1)
      return {contents:source.replace(anchor,anchor+'\n globalThis.__actualCenterlineCalls++;'),loader:'ts',resolveDir:dirname(args.path)}
    })
  } }] })
const { EraserGestureHitCache: Cache, drawingHit } = await import(pathToFileURL(resolve(folder, 'probe-module.mjs')))
const counted = await import(pathToFileURL(resolve(folder,'probe-counted.mjs')))
const quality = JSON.parse(await readFile(resolve(runtime, '../docs/fixtures/ink-v4-quality.json'), 'utf8'))
const checks = []
let comparisons = 0
const check = (name, fn) => { fn(); checks.push(name); console.log('PASS', name) }
const shape = (id, points, extra = {}) => ({ id, kind: 'ink', createdAt: '', updatedAt: '',
  data: { inkVersion: 4, points }, style: { color: 'ink', width: .003, opacity: .8 }, ...extra })
const point = (x, y, p = .5) => ({ x, y, p })
function equalHit(cache, row, target, aspect = 1) {
  comparisons++
  assert.equal(cache.hit(row, target, aspect), drawingHit(row, target, aspect), `canonical hit ${row.id} at ${target.x},${target.y}; aspect ${aspect}`)
}
const source = await readFile(resolve(upstream, 'src/renderer/src/features/ink/InkLayer.tsx'), 'utf8')
const drawingLayerSource = await readFile(resolve(upstream,'src/renderer/src/features/pdf/tools/DrawingLayer.tsx'),'utf8')
const transformed = transformInkLayer(source)
check('all exact adapter anchors + changed/duplicated eraser anchor fail closed', () => {
  const anchor = 'if (!ids.has(shape.id) && drawingHit(shape, point, aspect)) ids.add(shape.id)'
  assert.throws(() => transformInkLayer(source.replace(anchor, anchor + '\n' + anchor)), /expected 1 source anchor/)
  assert.throws(() => transformInkLayer(source.replace(anchor, 'changed_anchor')), /expected 1 source anchor/)
  assert.equal((transformed.match(/eraserHits.current.begin\(\)/g)??[]).length,1)
  const originalErase = source.slice(source.indexOf('  const eraseAt ='),source.indexOf('  const processSample ='))
  const preparedErase = transformed.slice(transformed.indexOf('  const eraseAt ='),transformed.indexOf('  const processSample ='))
  assert.equal(preparedErase.replace('eraserHits.current.hit(shape, point, aspect)','drawingHit(shape, point, aspect)'),originalErase,
    'only the geometry provider changes in the actual erase loop; IDs/order/skip behavior stay canonical')

})
const syntax = ts.createSourceFile('InkLayer.tsx', transformed, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
function callback(name) {
  let result
  function visit(node) {
    if (ts.isVariableDeclaration(node) && node.name.getText(syntax) === name && node.initializer && ts.isCallExpression(node.initializer)) result = node.initializer.arguments[0].getText(syntax)
    ts.forEachChild(node, visit)
  }
  visit(syntax); assert.ok(result, `actual transformed callback ${name}`)
  return ts.transpile(`return (${result})`, { target: ts.ScriptTarget.ES2022 })
}
check('actual transformed eraseAt + setGesture retains and releases contact cache', () => {
  const eraserHits = { current: new Cache() }, rows = [shape('a', [point(.2,.2),point(.8,.2)])]
  const eraseAt = new Function('shapes', 'aspect', 'eraserHits', callback('eraseAt'))(rows, 1, eraserHits)
  eraserHits.current.begin()
  let gesture = eraseAt({ kind: 'erase', pointerId: 7, ids: new Set() }, point(.2,.8))
  gesture = eraseAt(gesture, point(.2,.8))
  assert.equal(eraserHits.current.statistics.computations, 1)
  const gestureRef = { current: gesture }, liveInk = { current: { clear() {}, render() {} } }, liveInkHost = { current: null }
  const setGesture = new Function('eraserHits','gestureRef','liveInk','liveInkHost','aspect','drawingColorVariable','setGestureState',callback('setGesture'))(
    eraserHits, gestureRef, liveInk, liveInkHost, 1, value => value, () => {})
  setGesture(gesture); assert.equal(eraserHits.current.statistics.entries, 1)
  setGesture(null); assert.equal(eraserHits.current.statistics.entries, 0); assert.equal(eraserHits.current.statistics.active, false)
  eraserHits.current.begin(); equalHit(eraserHits.current, rows[0], point(.2,.8))
  setGesture({ kind:'shape' }); assert.equal(eraserHits.current.statistics.accountedBytes, 0)
  assert.match(transformed, /else if \(activeTool === 'eraser'\) \{\n      eraserHits.current.begin\(\)\n      setGesture\(eraseAt/)
  // Existing up/cancel/tool-change paths all end through this exact setGesture.
  assert.match(transformed, /const handlePointerUp[\s\S]*?setGesture\(null\)/)
  assert.match(transformed, /const handlePointerCancel[\s\S]*?setGesture\(null\)/)
  assert.match(transformed, /finishTextSession\(\)\n    setGesture\(null\)/)
  assert.match(transformed, /liveInk.current.clear\(\)\n    eraserHits.current.clear\(\)/)
  let unmountEffect
  function findCleanup(node) {
    if(ts.isCallExpression(node)&&node.expression.getText(syntax)==='useEffect'&&node.arguments[0]?.getText(syntax).includes('eraserHits.current.clear()')) unmountEffect=node.arguments[0].getText(syntax)
    ts.forEachChild(node,findCleanup)
  }
  findCleanup(syntax);assert.ok(unmountEffect)
  const cleanup=new Function('pointerFrame','cancelAnimationFrame','liveInk','eraserHits',ts.transpile(`return (${unmountEffect})`,{target:ts.ScriptTarget.ES2022}))({current:null},()=>{},liveInk,eraserHits)()
  eraserHits.current.begin();equalHit(eraserHits.current,rows[0],point(.2,.8))
  cleanup();assert.equal(eraserHits.current.statistics.entries,0);assert.equal(eraserHits.current.statistics.active,false)
  assert.ok(drawingLayerSource.includes('key={JSON.stringify([courseId, relPath, page])}'),'actual PDF document/page transfer remounts InkLayer and invokes cleanup')
})
check('shared 21 v4 geometry fixtures + repeated target/thresholds exact', () => {
  const cache = new Cache(); cache.begin()
  for (const fixture of quality.cases) {
    const row = shape(fixture.id, structuredClone(fixture.points), { kind: fixture.highlighter ? 'highlighter' : 'ink',
      style: { color: 'ink', width: fixture.width, opacity: .4 } })
    const aspect = fixture.aspect, threshold = Math.max(.007, row.style.width / 2 + .005)
    const targets = [point(.01,.99),point(.5,.5)]
    for (const p of row.data.points) for (const delta of [0,threshold-1e-12,threshold,threshold+1e-12]) {
      targets.push(point(p.x + delta,p.y),point(p.x,p.y + delta/aspect))
    }
    for (let i=0;i<=10;i++) for(let j=0;j<=10;j++) targets.push(point(i/10,j/10))
    for (const target of targets) equalHit(cache,row,target,aspect)
  }
})

check('same-ID/data/points/style primitive mutations, undo, pressure/time, signed zero', () => {
  const cache = new Cache(); cache.begin()
  const row = shape('mutable', [point(.1,.2,0),{...point(.5,.4,.8),t:8},point(.8,.2,.4)])
  const target = point(.5,.4)
  const mutations = [
    () => { row.data.points[1].x = .51 }, () => { row.data.points[1].y = .41 },
    () => { row.data.points[1].p = .2 }, () => { row.data.points[1].t = 17 },
    () => { row.data.points[1].t = undefined }, () => { row.data.points[1].t = NaN },
    () => { row.data.points[1].t = Infinity }, () => { row.data.points[1].t = -0 },
    () => { row.data.points[1].t = 0 }, () => { row.style.width = .009 },
    () => { row.data.points.push(point(.9,.1)) }, () => { row.data.points.pop() },
    () => { row.data.points.reverse() }, () => { row.kind = 'highlighter' },
    () => { row.data.points[0].x = -0 }, () => { row.data.points[0].x = 0 }
  ]
  equalHit(cache,row,target)
  for(const mutate of mutations) {
    const before = cache.statistics.computations; mutate(); equalHit(cache,row,target)
    assert.equal(cache.statistics.computations,before+1, 'each relevant primitive mutation recomputes')
    equalHit(cache,row,point(.99,.99)); assert.equal(cache.statistics.computations,before+1)
  }
  for(const aspect of [1.5,2,.5,1]) {
    const before=cache.statistics.computations; equalHit(cache,row,target,aspect)
    assert.equal(cache.statistics.computations,before+1)
  }
  // A same-reference version change takes the untouched canonical path, then
  // returning to v4 rebuilds rather than resurrecting stale cached geometry.
  row.data.inkVersion=3; equalHit(cache,row,target); assert.equal(cache.statistics.entries,0)
  row.data.inkVersion=4; equalHit(cache,row,target); assert.equal(cache.statistics.entries,1)
  const before=cache.statistics.computations
  row.style.color='blue';row.style.opacity=.2;row.data.points[0].tiltX=17
  equalHit(cache,row,target);assert.equal(cache.statistics.computations,before,'canonical hit ignores color/opacity/tilt')
  const snapshot=structuredClone(row);row.data.points[1].x=.85;equalHit(cache,row,target)
  Object.assign(row,snapshot);equalHit(cache,row,target)
  const after=cache.statistics.computations
  equalHit(cache,structuredClone(row),target);assert.equal(cache.statistics.computations,after,'same values/new identities may reuse')
})

check('v5 prepared geometry, version switch and mutable raw inputs match pure hit', () => {
  const cache = new Cache(); cache.begin()
  const row = shape('v5', [{x:.1,y:.2,p:0,t:0},{x:.5,y:.4,p:1,t:4},{x:.8,y:.2,p:.3,t:8}])
  for (const version of [5,4,5]) {
    row.data.inkVersion = version
    const before = cache.statistics.computations
    for (const aspect of [1]) for (const target of [point(.1,.2),point(.4,.35),point(.8,.2),point(.99,.99)]) equalHit(cache,row,target,aspect)
    assert.equal(cache.statistics.computations,before+1,'version participates in geometry identity')
  }
  for (const mutate of [()=>{row.data.points[1].p=.1},()=>{row.data.points[1].t=32},()=>{row.data.points[1].x=.51},()=>{row.style.width=.01}]) {
    const before=cache.statistics.computations; mutate(); equalHit(cache,row,point(.5,.4))
    assert.equal(cache.statistics.computations,before+1)
  }
  cache.clear(); assert.equal(cache.statistics.accountedBytes,0)
})

check('empty, box fallback, invalid aspect/point/width/time, mixed non-v4 kinds exact', () => {
  const cache=new Cache();cache.begin()
  const empty=shape('emptybox',[],{data:{inkVersion:4,points:[],box:{x:.1,y:.2,width:.3,height:.4}}})
  equalHit(cache,empty,point(.2,.2));empty.data.box.y=.8;equalHit(cache,empty,point(.2,.2))
  const cases=[
    shape('none',[]),shape('badpoint',[point(NaN,.2)]),shape('badpressure',[point(.2,.2,NaN)]),
    shape('overflow',[point(.2,1e308)]),shape('nulltime',[{...point(.2,.2),t:null}]),
    shape('legacy',[point(.2,.2)],{data:{points:[point(.2,.2)]}}),
    shape('v2',[point(.2,.2)],{data:{inkVersion:2,points:[point(.2,.2)]}}),
    shape('rect',[],{kind:'rect',data:{box:{x:.2,y:.2,width:.3,height:.3}}}),
    shape('text',[],{kind:'textbox',data:{text:'synthetic',box:{x:.2,y:.2,width:.3,height:.3}}}),
    shape('line',[],{kind:'line',data:{points:[point(.1,.1),point(.8,.8)]}})
  ]
  for(const row of cases) for(const aspect of [1,1.5,0,-1,NaN,Infinity,1e308])
    for(const target of [point(.2,.2),point(.9,.8),point(NaN,.2),point(.2,Infinity)]) equalHit(cache,row,target,aspect)
  for(const width of [0,-1,NaN,Infinity]) {const row=shape('width',[point(.2,.2)]);row.style.width=width;equalHit(cache,row,point(.5,.5))}
})

check('entry/raw/rendered/byte bounds + long stroke safe fallback + repeated release', () => {
  for(const limits of [{entries:1},{rawPoints:2},{renderedPoints:1},{accountedBytes:1}]) {
    const cache=new Cache(limits);cache.begin()
    for(let i=0;i<4;i++) equalHit(cache,shape(`row${i}`,[point(.1,.1),point(.8,.8)]),point(.3,.3))
    for(const [key,limit] of Object.entries(limits)) assert.ok(cache.statistics[key]<=limit,`bound ${key}`)
    cache.clear();assert.equal(cache.statistics.rawPoints,0);assert.equal(cache.statistics.renderedPoints,0);assert.equal(cache.statistics.accountedBytes,0)
  }
  const cache=new Cache({rawPoints:200})
  const long=shape('long',Array.from({length:2048},(_,i)=>point(i/2047,.4+.01*Math.sin(i/30))))
  cache.begin();equalHit(cache,long,point(.5,.4));assert.equal(cache.statistics.entries,0)
  assert.equal(cache.statistics.computations,0,'oversize skips cache preparation entirely')
  const short=shape('short',[point(.1,.1),point(.8,.8)])
  for(let cycle=0;cycle<100;cycle++) {cache.begin();equalHit(cache,short,point(.3,.3));assert.equal(cache.statistics.entries,1);cache.clear();assert.equal(cache.statistics.entries,0)}
  for(const limits of [{entries:-1},{rawPoints:NaN},{accountedBytes:Infinity},{renderedPoints:1.5}]) assert.throws(()=>new Cache(limits))
})

check('reorder/delete/append and same-ID replacement within active gesture exact', () => {
  const cache=new Cache();cache.begin()
  let rows=[shape('a',[point(.1,.1),point(.3,.1)]),shape('b',[point(.5,.5),point(.8,.5)])]
  for(const target of [point(.1,.1),point(.5,.5),point(.9,.9)]) for(const row of rows)equalHit(cache,row,target)
  rows.reverse();rows.pop();rows.push(shape('a',[point(.8,.2),point(.9,.2)]));rows.push(shape('c',[point(.2,.6)]))
  for(const target of [point(.1,.1),point(.5,.5),point(.9,.9),point(.8,.2)])for(const row of rows)equalHit(cache,row,target)
})

const fixture = { aspect: 1.5,
  shapes: Array.from({length:200},(_,index)=>shape(`synthetic-${index}`,
    Array.from({length:96},(_,sample)=>({x:.025+(index%20)*.048+.035*sample/95,
      y:.055+Math.floor(index/20)*.075+.012*Math.sin(4*Math.PI*sample/95),
      p:.2+.7*(.5+.5*Math.sin(Math.PI*sample/95)),t:sample*4})),
    {kind:index%5?'ink':'highlighter',style:{width:.003,opacity:index%5?.95:.34,color:index%5?'ink':'yellow'}})),
  paths: {
    noHit:Array.from({length:32},(_,index)=>point(.02+.96*index/31,.94)),
    diagonalHit:Array.from({length:32},(_,index)=>point(.02+.96*index/31,.055+.675*index/31))
  }
}
const fixtureBefore=JSON.stringify(fixture)
const gesture=(rows,points,hit)=>{
  let ids=new Set();const sequence=[]
  for(const target of points) {
    const next=new Set(ids)
    for(const row of rows)if(!next.has(row.id)&&hit(row,target,fixture.aspect))next.add(row.id)
    ids=next;sequence.push([...ids])
  }
  return sequence
}
const bench=[]
for(const [name,points]of Object.entries(fixture.paths)) {
  const cache=new Cache();cache.begin()
  const expected=gesture(fixture.shapes,points,drawingHit),actual=gesture(fixture.shapes,points,(...args)=>cache.hit(...args))
  assert.deepEqual(actual,expected)
  assert.equal(cache.statistics.computations,200)
  globalThis.__actualCenterlineCalls=0
  assert.deepEqual(gesture(fixture.shapes,points,counted.drawingHit),expected)
  const canonicalCenterlineCalls=globalThis.__actualCenterlineCalls
  globalThis.__actualCenterlineCalls=0
  const countedCache=new counted.EraserGestureHitCache();countedCache.begin()
  assert.deepEqual(gesture(fixture.shapes,points,(...args)=>countedCache.hit(...args)),expected)
  const candidateCenterlineCalls=globalThis.__actualCenterlineCalls
  assert.equal(candidateCenterlineCalls,200)
  const wall={canonical:[],candidate:[]},cpu={canonical:[],candidate:[]}
  for(let iteration=0;iteration<(benchmark?5:0);iteration++) for(const kind of ['canonical','candidate']) {
    const current=new Cache();current.begin()
    const startedCPU=process.cpuUsage(),started=performance.now()
    const result=gesture(fixture.shapes,points,kind==='canonical'?drawingHit:(...args)=>current.hit(...args))
    wall[kind].push(performance.now()-started);const used=process.cpuUsage(startedCPU);cpu[kind].push((used.user+used.system)/1000)
    assert.deepEqual(result,expected)
    current.clear();assert.equal(current.statistics.accountedBytes,0)
  }
  const stats=values=>{const s=[...values].sort((a,b)=>a-b);return{min:s[0],median:s[2],max:s[4],values}}
  bench.push({name,rawPoints:19200,samples:32,computations:cache.statistics.computations,reuses:cache.statistics.reuses,
    actualFunctionEntryCounters:{canonicalCenterlineCalls,candidateCenterlineCalls},
    retained:cache.statistics,exactPerSampleIDs:true,wallMS:{canonical:stats(wall.canonical),candidate:stats(wall.candidate)},
    cpuMS:{canonical:stats(cpu.canonical),candidate:stats(cpu.candidate)}})
  cache.clear(); countedCache.clear()
  assert.equal(cache.statistics.accountedBytes,0); assert.equal(countedCache.statistics.accountedBytes,0)
  if(benchmark) console.log('BENCH',JSON.stringify(bench.at(-1)))
  else console.log(`PASS ${name}: exact erased IDs, actual centerline calls ${canonicalCenterlineCalls} → ${candidateCenterlineCalls}, retention released`)
}
assert.equal(JSON.stringify(fixture),fixtureBefore)
for(const file of manifest) assert.equal(hash(await readFile(file.source)),file.sha256)
const results={checks,checkCount:checks.length,canonicalHitComparisons:comparisons,qualityFixtures:quality.cases.length,
  bench,sourceManifestVerified:true,fixtureUnchanged:true,scope:'Scratch Node correctness/CPU only; no app, browser, Simulator or device execution',node:process.version}
console.log(JSON.stringify({checkGroups:results.checkCount,canonicalHitComparisons:comparisons,qualityFixtures:quality.cases.length,benchmark,sourceManifestVerified:true,fixtureUnchanged:true}))
console.log('PASS all checks, raw fixture and original sources unchanged')

} finally {
  delete globalThis.__actualCenterlineCalls
  await rm(folder, { recursive: true, force: true })
}
