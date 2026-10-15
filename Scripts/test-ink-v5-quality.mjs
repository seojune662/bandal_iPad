#!/usr/bin/env node
// Pure production TS geometry/compatibility checks. --report writes synthetic
// numeric evidence only; native parity is a separate explicit qualification.
import assert from 'node:assert/strict'
import {execFileSync} from 'node:child_process'
import { readFile, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createRequire } from 'node:module'
import { dependencies, runtime } from '../DesktopRuntime/scripts/dependencies.mjs'
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const args = process.argv.slice(2), report = args.includes('--report') ? args[args.indexOf('--report') + 1] : undefined
const folder = await mkdtemp(resolve(tmpdir(), 'bandal-ink-v5-quality-'))
const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild')
const fixtures = JSON.parse(await readFile(resolve(root, 'docs/fixtures/ink-v5-quality.json'), 'utf8'))
const close = (actual, expected, label, epsilon = 1e-12) => assert.ok(Math.abs(actual - expected) <= epsilon, `${label}: ${actual} != ${expected}`)


const swiftRunner=String.raw`
import Foundation
import CoreGraphics
struct FixtureFile:Decodable {let cases:[Fixture]}
struct Fixture:Decodable {let id:String;let points:[NativePDFPoint];let width:Double;let aspect:Double;let highlighter:Bool;let predictions:[NativePDFPoint]?}
func segmentValues(_ points:[NativePDFPoint],_ width:Double,_ aspect:Double,_ highlighter:Bool)->[[[Double]]] {
    guard let profile=NativePDFInkGeometryV5.renderProfile(points:points,width:width,aspect:aspect,highlighter:highlighter) else{return []}
    return (0..<max(0,profile.points.count-1)).map { i in
        var values=[[profile.points[i].x,profile.points[i].y,profile.factors[i]]]
        NativePDFInkGeometryV5.forEachSegmentSample(profile:profile,index:i,width:width,aspect:aspect,highlighter:highlighter){values.append([$0.x,$0.y,$0.factor])}
        return values
    }
}
let fixtures=try JSONDecoder().decode(FixtureFile.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
let results:[[String:Any]]=fixtures.cases.map {f in
    let profile=NativePDFInkGeometryV5.renderProfile(points:f.points,width:f.width,aspect:f.aspect,highlighter:f.highlighter)!
    var predictions=[[[Double]]]()
    if let last=profile.points.last {
        NativePDFInkGeometryV5.forEachPredictionPolygon(lastPoint:last,factor:profile.factors.last!,predictions:f.predictions ?? [],width:f.width,aspect:f.aspect){predictions.append($0.map{[$0.x,$0.y]})}
    }
    return ["id":f.id,"pressures":NativePDFInkGeometryV5.filteredPressures(f.points),"factors":NativePDFInkGeometryV5.widthFactors(points:f.points,width:f.width,aspect:f.aspect,highlighter:f.highlighter),
      "anchors":profile.points.map{[$0.x,$0.y]},"ranges":profile.points.indices.map{[profile.rawFirst[$0],profile.rawLast[$0]]},"bases":profile.bases,"travel":profile.travel,"anchorFactors":profile.factors,
      "segments":segmentValues(f.points,f.width,f.aspect,f.highlighter),"polygons":NativePDFInkGeometryV5.polygons(points:f.points,width:f.width,aspect:f.aspect,highlighter:f.highlighter).map{$0.map{[$0.x,$0.y]}},"predictions":predictions,
      "prefixSegments":(0...f.points.count).map{segmentValues(Array(f.points.prefix($0)),f.width,f.aspect,f.highlighter)}]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]))
`

try {
  await build({ stdin: { loader: 'ts', resolveDir: runtime, contents: `
    export * from './upstream/src/shared/inkV5';
    export {strokeSegmentsV4,strokePolygonsV4,strokePathV4} from './upstream/src/shared/inkV4';
    export {strokePathV3} from './upstream/src/shared/inkV3';
    export {strokePathV2} from './upstream/src/shared/inkV2';
    export {strokePath} from './upstream/src/renderer/src/features/ink/inkGeometry';
    export {assertDrawingData} from './upstream/src/main/features/drawingValidation';
    export {nativePDFDrawingPayload} from './renderer/nativePDF/drawingPayload';
    export {isJournaledDrawing} from './renderer/nativePDF/types';
    export {IncrementalInkPathV5} from './renderer/pencil/livePreview';
  ` }, bundle: true, outfile: resolve(folder, 'module.mjs'), platform: 'node', format: 'esm', target: 'es2022', nodePaths: [resolve(runtime, 'node_modules')] })
  const api = await import(pathToFileURL(resolve(folder, 'module.mjs')))
  let groups = 0, prefixes = 0, samples = 0
  const rows = []
  // Independent age oracle: prefix sums of effective intervals, then a four-
  // element weighted dot product. It does not call the implementation filter.
  const expectedPressure = points => {
    const clock = [0]
    for (let i = 1; i < points.length; i++) {
      const dt = points[i].t - points[i - 1].t
      clock.push(clock[i - 1] + (Number.isFinite(dt) && dt > 0 ? Math.min(dt, 32) : 4))
    }
    return points.map((_, i) => {
      const terms = points.slice(Math.max(0, i - 3), i + 1).map((point, j) => ({p:Math.min(1,Math.max(0,point.p)), age:clock[i]-clock[Math.max(0,i-3)+j]})).filter(term=>term.age<=24)
      const total = terms.reduce((sum,term)=>sum+Math.exp(-term.age/8),0)
      return terms.reduce((sum,term)=>sum+term.p*Math.exp(-term.age/8)/total,0)
    })
  }
  for (const fixture of fixtures.cases) {
    const { points, width, aspect, highlighter } = fixture, before = JSON.stringify(points)
    const factors = api.diameterFactorsV5(points,width,aspect,highlighter)
    const expected = expectedPressure(points)
    expected.forEach((p,i)=>close(api.filteredPressureV5(points,i),p,`${fixture.id} pressure ${i}`))
    assert.equal(factors.length,points.length)
    factors.forEach(factor=>assert.ok(factor>0 && factor<=1))
    if(highlighter) assert.ok(factors.every(factor=>factor===1))
    const builder = new api.IncrementalInkPathV5(width,aspect,highlighter)
    let settled = ''
    for(let n=0;n<=points.length;n++) {
      const prefix=points.slice(0,n), actual=builder.update(prefix)
      assert.equal(actual,api.strokePathV5(prefix,width,aspect,highlighter),`${fixture.id} live/saved ${n}`)
      if (api.renderProfileV5(prefix,width,aspect,highlighter).points.length > 1) assert.ok(builder.settledPath.startsWith(settled)); settled=builder.settledPath;prefixes++
    }
    const polygons=api.strokePolygonsV5(points,width,aspect,highlighter)
    for(const polygon of polygons) {
      assert.ok([4,32].includes(polygon.length));assert.ok(polygon.flat().every(Number.isFinite))
      const area=polygon.reduce((sum,a,i)=>{const b=polygon[(i+1)%polygon.length];return sum+a[0]*b[1]-a[1]*b[0]},0)
      assert.ok(area>=-1e-14,`${fixture.id} consistent fill winding`)
    }
    const predictions=Array.from({length:12},(_,i)=>({x:.5+i*.001,y:.4,p:i%2,t:1000+i}))
    const predicted=api.predictionPolygonsV5(points,predictions,width,aspect,highlighter)
    assert.equal(predicted.filter(poly=>poly.length===32).length,points.length?8:0)
    assert.deepEqual(predicted,api.predictionPolygonsV5(points,predictions.map(p=>({...p,p:NaN,t:-1})),width,aspect,highlighter))
    if(points.length) for(const [i,disk] of predicted.filter(poly=>poly.length===32).entries()) close(disk[0][0]-predictions[i].x,width*factors.at(-1)/2,`${fixture.id} prediction factor`)
    if(highlighter) assert.deepEqual(polygons,api.strokePolygonsV4(points,width,aspect,true),'highlighter preserves V4 geometry and width')
    assert.equal(JSON.stringify(points),before,'raw measured input unchanged')
    const segmentSamples=[...api.strokeSegmentsV5(points,width,aspect,highlighter)].reduce((n,s)=>n+s.samples.length,0)
    samples+=segmentSamples;rows.push({id:fixture.id,rawSamples:points.length,renderSamples:segmentSamples,polygons:polygons.length,generatedLiveSegments:builder.generatedSegments})
  }
  groups++
  // Analytic endpoint controls: no speed on a dot; no end taper without travel.
  close(api.diameterFactorsV5([{x:.5,y:.5,p:0}],.01,1,false)[0],.18,'zero-pressure dot stays visible')
  close(api.diameterFactorsV5([{x:.5,y:.5,p:1}],.01,1,false)[0],.69,'maximum-pressure dot startgain')
  const quiet=Array.from({length:8},(_,i)=>({x:.5,y:.5,p:1,t:i*4}))
  api.diameterFactorsV5(quiet,.01,1,false).forEach(value=>close(value,.69,'stationary pressure no end taper'));groups++
  // Sparse-line taper is confined to endpoint windows. Middle body remains at
  // its causal base; adding same-pressure dwell cannot consume the moving tail.
  const sparse=fixtures.cases.find(f=>f.id==='long-two-point-local-tips')
  const profile=api.renderProfileV5(sparse.points,sparse.width,sparse.aspect,false)
  const sparseSamples=api.segmentSamplesV5(profile,0,sparse.width,sparse.aspect)
  assert.ok(sparseSamples.length<=18,'two-point line: bounded endpoint-only subdivision')
  const body=sparseSamples.filter(sample=>sample.x>=.1+1.2*sparse.width-1e-14 && sample.x<=.9-2.2*sparse.width+1e-14)
  assert.ok(body.length>=2,'both body boundaries are represented')
  for(const sample of body) close(sample.factor,profile.baseFactors[0],'full-width sparse body')
  for(const f of fixtures.cases.filter(f=>f.id.startsWith('constant-pressure-terminal-dwell-'))) {
    const before=f.points.slice(0,20)
    const a=api.renderProfileV5(before,f.width,f.aspect,false), b=api.renderProfileV5(f.points,f.width,f.aspect,false)
    assert.equal(b.points.length,20,'stationary time does not consume moving tail')
    a.factors.forEach((factor,i)=>close(factor,b.factors[i],f.id+' stable dwell factor'))
    assert.equal(api.strokePathV5(before,f.width,f.aspect,false),api.strokePathV5(f.points,f.width,f.aspect,false),f.id+' identical visible geometry')
  }
  // A v5 display vertex lies on the original V4 polyline for its grouped pen
  // anchors. Additional local knots never alter the accepted centerline.
  for(const f of fixtures.cases) {
    const p=api.renderProfileV5(f.points,f.width,f.aspect,f.highlighter)
    const baseline=[...api.strokeSegmentsV4(p.points,f.width,f.aspect)]
    for(const segment of api.strokeSegmentsV5(f.points,f.width,f.aspect,f.highlighter)) {
      const line=baseline[segment.index].samples
      for(const point of segment.samples) {
        let distance=Infinity
        for(let i=1;i<line.length;i++) {
          const a=line[i-1],b=line[i],dx=b.x-a.x,dy=(b.y-a.y)*f.aspect,px=point.x-a.x,py=(point.y-a.y)*f.aspect
          const t=dx*dx+dy*dy===0?0:Math.max(0,Math.min(1,(px*dx+py*dy)/(dx*dx+dy*dy)))
          distance=Math.min(distance,Math.hypot(px-dx*t,py-dy*t))
        }
        assert.ok(distance<=1e-12,f.id+' V4 accepted polyline unchanged')
      }
    }
  }
  groups++
  // Every existing version selects its historical renderer; v5 is explicit.
  const raw=[{x:-0,y:.2,p:0,t:0,tiltX:-30,tiltY:10},{x:.7,y:.4,p:.8,t:16,tiltX:45,tiltY:-10}]
  const style={width:.004,color:'ink',opacity:.75}, identity={courseId:'course',relPath:'fixture.pdf'}
  for(const version of [2,3,4,5]) {
    const data={inkVersion:version,points:raw}, validated=api.assertDrawingData(data,'ink')
    assert.deepEqual(validated,data); assert.ok(Object.is(validated.points[0].x,-0))
    const row={id:'saved',kind:'ink',data,style,createdAt:'',updatedAt:''}
    assert.equal(api.nativePDFDrawingPayload(row,1.5),row,'native payload bypass preserves measured data')
    assert.equal(api.strokePath(raw,style,1.5,false,version),api[`strokePathV${version}`](raw,.004,1.5,false))
    const input={...identity,page:1,kind:'ink',clientMutationId:'00000000-0000-4000-8000-000000000001',documentRevision:'a'.repeat(64),data,style}
    assert.ok(api.isJournaledDrawing(input,identity),'recovery accepts version '+version)
  }
  assert.throws(()=>api.assertDrawingData({inkVersion:6,points:raw},'ink'))
  assert.throws(()=>api.assertDrawingData({inkVersion:5,box:{x:0,y:0,width:.1,height:.1}},'rect'))
  groups++
  let nativeParity
  if(args.includes('--native')) {
    const runner=resolve(folder,'main.swift'),binary=resolve(folder,'native-v5')
    await writeFile(runner,swiftRunner)
    execFileSync('xcrun',['swiftc','-O',...['NativePDFTypes','NativePDFInkGeometryV3','NativePDFInkGeometryV4','NativePDFInkGeometryV5'].map(name=>resolve(root,'App/Desktop/PDF/'+name+'.swift')),runner,'-o',binary],{stdio:['ignore','pipe','pipe'],timeout:120000})
    const native=JSON.parse(execFileSync(binary,[resolve(root,'docs/fixtures/ink-v5-quality.json')],{encoding:'utf8',maxBuffer:64*1024*1024,timeout:60000}))
    let numericComparisons=0,maximumError=0
    function compare(a,b,label) {
      if(Array.isArray(a)) {assert.ok(Array.isArray(b),label);assert.equal(a.length,b.length,label+' length');a.forEach((x,i)=>compare(x,b[i],label+'['+i+']'))}
      else {numericComparisons++;maximumError=Math.max(maximumError,Math.abs(a-b));close(a,b,label)}
    }
    for(const [index,f] of fixtures.cases.entries()) {
      const profile=api.renderProfileV5(f.points,f.width,f.aspect,f.highlighter)
      const segments=[...api.strokeSegmentsV5(f.points,f.width,f.aspect,f.highlighter)].map(s=>s.samples.map(p=>[p.x,p.y,p.factor]))
      const value={pressures:f.points.map((_,i)=>api.filteredPressureV5(f.points,i)),factors:api.diameterFactorsV5(f.points,f.width,f.aspect,f.highlighter),
        anchors:profile.points.map(p=>[p.x,p.y]),ranges:profile.sourceRanges,bases:profile.baseFactors,travel:profile.travel,anchorFactors:profile.factors,segments,
        polygons:api.strokePolygonsV5(f.points,f.width,f.aspect,f.highlighter),predictions:api.predictionPolygonsV5(f.points,f.predictions??[],f.width,f.aspect,f.highlighter),
        prefixSegments:Array.from({length:f.points.length+1},(_,n)=>[...api.strokeSegmentsV5(f.points.slice(0,n),f.width,f.aspect,f.highlighter)].map(s=>s.samples.map(p=>[p.x,p.y,p.factor])))}
      assert.equal(native[index].id,f.id)
      for(const key of Object.keys(value)) compare(native[index][key],value[key],f.id+' Swift/TS '+key)
    }
    nativeParity={numericComparisons,maximumError};groups++
  }
  const result={status:'PASS',scope:'synthetic production geometry; no physical Pencil/device claim',fixtureCount:rows.length,groups,prefixes,renderSamples:samples,nativeParity,cases:rows}
  if(report) await writeFile(report,JSON.stringify(result,null,2)+'\n')
  console.log(JSON.stringify({...result,cases:undefined}))
} finally { await rm(folder,{recursive:true,force:true}) }
