import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
import nativePDFPlugin, { transformNativePDF, transformNativePDFPage, transformNativePDFPointerCapture } from './index.mjs'
import { transformInkLayer } from '../pencil/index.mjs'
const { require } = dependencies()
const ts = require('typescript')
const folder = await mkdtemp(join(tmpdir(), 'bandal-nativepdf-session-'))
try {
  const types = await readFile(resolve(runtime, 'renderer/nativePDF/types.ts'), 'utf8')
  const sessionSource = await readFile(resolve(runtime, 'renderer/nativePDF/session.ts'), 'utf8')
  await writeFile(join(folder, 'session.mjs'), ts.transpileModule(types.replace(/^import .*$/gm, '') + '\n' + sessionSource.replace(/^import .*$/gm, ''), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText)
  const { NativePDFSession } = await import(pathToFileURL(join(folder, 'session.mjs')))
  const identity = { surfaceId: 'pdf-panel', generation: 'one-open', courseId: 'course', relPath: 'file.pdf' }
  const input = { courseId: 'course', relPath: 'file.pdf', page: 1, kind: 'ink',
    clientMutationId: 'fdc2af33-57eb-42ae-8356-44847901099c', documentRevision: 'a'.repeat(64),
    data: { inkVersion: 2, points: [{ x: .1, y: .2, p: 0, t: 3, tiltX: 15, tiltY: -12 }] },
    style: { color: 'ink', width: .004, opacity: .9 } }
  let writes = 0, failedAck = true, pending = [input], flushed = false
  const trace = []
  const bridge = { async invoke(channel, request) {
    trace.push(channel)
    assert.equal(request.surfaceId, identity.surfaceId)
    assert.equal(request.generation, identity.generation)
    if (channel === 'pdfNative:mutationStatus') return {status:'missing'}
    if (channel === 'pdfNative:ack') {
      assert.equal(request.clientMutationId, input.clientMutationId)
      assert.equal(request.drawingId, 'durable-id')
      if (failedAck) { failedAck = false; throw new Error('lost ACK') }
      pending = []
    }
    return channel === 'pdfNative:flush' ? { pending } : {}
  }, on() { return () => {} } }
  const writer = { async create(value) { writes++; assert.deepEqual(value, input); return { ...value, id: 'durable-id' } }, async flush() { flushed = true } }
  const session = new NativePDFSession(identity, bridge, writer)
  await assert.rejects(session.accept(input), /lost ACK/)
  assert.equal(writes, 1)
  assert.equal(session.mutationIdForDrawing('durable-id'), input.clientMutationId, 'ACK retry retains canonical-to-pending preview identity')
  assert.equal(session.mutationIdForDrawing('another-id'), undefined)
  await session.accept(input)
  assert.equal(writes, 1, 'retrying ACK must not duplicate renderer undo history')
  await Promise.all([session.accept(input), session.accept(input)])
  assert.equal(writes, 1)
  await assert.rejects(session.accept({ ...input, relPath: 'another.pdf' }), /다른 자료/)
  await assert.rejects(session.accept({ ...input, data: { ...input.data, points: [{ x: NaN, y: 0, p: .5 }] } }), /잘못된/)
  await session.close(); assert.equal(flushed, true)
  assert.equal(trace.at(-1), 'pdfNative:close')
  await assert.rejects(session.accept(input), /닫힌 PDF/)

  // A different session has no in-memory create cache: replay must consult
  // durable receipts before touching the original writer/undo stack.
  for (const status of ['live','deleted']) {
    let creates = 0, acknowledgements = 0
    const recovered = new NativePDFSession(identity, { async invoke(channel, request) {
      if (channel === 'pdfNative:mutationStatus') { assert.deepEqual(request.input,input); return {status,drawingId:'committed-id'} }
      if (channel === 'pdfNative:ack') { assert.equal(request.drawingId,'committed-id'); acknowledgements++; return {} }
      return {pending:[input]}
    }, on(){return()=>{}} }, {async create(){creates++;throw new Error('Recovery cannot add history')}})
    await recovered.replay([input,input]); await recovered.flush()
    assert.equal(creates,0);assert.equal(acknowledgements,1)
    assert.equal(recovered.mutationIdForDrawing('committed-id'), input.clientMutationId)
  }
  const unknown = new NativePDFSession(identity,{async invoke(){return{}},on(){return()=>{}}},{async create(){throw new Error('Should not create without known receipt state')}})
  await assert.rejects(unknown.accept(input),/완료 상태/)

  let releaseCreate, startedCreate
  const createStarted = new Promise(resolve => { startedCreate = resolve })
  const createGate = new Promise(resolve => { releaseCreate = resolve })
  const sharedTransport = { async invoke(channel) { return channel === 'pdfNative:mutationStatus' ? {status:'missing'} : {} }, on(){return()=>{}} }
  const firstOwner = new NativePDFSession(identity,sharedTransport,{async create(value){startedCreate();await createGate;return{...value,id:'shared-operation'}}})
  const nextOwner = new NativePDFSession({...identity,surfaceId:'another-split'},sharedTransport,{async create(){throw new Error('A mismatched operation must never reach this writer')}})
  const firstOperation=firstOwner.accept(input);await createStarted
  await assert.rejects(nextOwner.accept({...input,style:{...input.style,color:'red'}}),/서로 다른 내용/)
  releaseCreate();await firstOperation
  assert.equal(firstOwner.mutationIdForDrawing('shared-operation'),input.clientMutationId)

  let closes = 0, releaseFlush
  const waitForFlush = new Promise(resolve=>{releaseFlush=resolve})
  const closingSession = new NativePDFSession(identity,{async invoke(channel){
    if(channel==='pdfNative:flush'){await waitForFlush;return{pending:[]}}
    if(channel==='pdfNative:close')closes++
    return{}
  },on(){return()=>{}}},{async create(){throw new Error('No new ink')}})
  const firstClose=closingSession.close(), secondClose=closingSession.close()
  releaseFlush();await Promise.all([firstClose,secondClose]);await closingSession.close()
  assert.equal(closes,1,'Retired registry flush and cleanup must share one in-flight native close')
  let failClose=true,retries=0
  const retrySession = new NativePDFSession(identity,{async invoke(channel){
    if(channel==='pdfNative:flush')return{pending:[]}
    if(channel==='pdfNative:close'){retries++;if(failClose){failClose=false;throw new Error('Close unavailable')}}
    return{}
  },on(){return()=>{}}},{async create(){throw new Error('No new ink')}})
  await assert.rejects(retrySession.close(),/Close unavailable/)
  await retrySession.close();assert.equal(retries,2,'A failed close remains retryable')

  const original = await readFile(resolve(runtime, 'upstream/src/renderer/src/features/pdf/PdfTab.tsx'), 'utf8')
  const transformed = transformNativePDF(original)
  assert.ok(transformed.indexOf('const nativePDF = useNativePDF') < transformed.indexOf('if (loadError !== null)'), 'hook must precede conditional returns')
  assert.ok(transformed.includes('nativeBody={nativePDF.active}'))
  for (const feature of ['<PdfToolbar', '<AnnotationRail', '<PdfPageNoteDialog', 'pageImageCopy.overlay', 'drawingsApi.create', 'setPendingSelection']) assert.ok(transformed.includes(feature), feature)
  assert.throws(() => transformNativePDF(original.replace('if (loadError !== null)', 'if (loadError)')), /anchor changed/)
  const pageView = await readFile(resolve(runtime, 'upstream/src/renderer/src/features/pdf/PdfPageView.tsx'), 'utf8')
  assert.ok(transformNativePDFPage(pageView).includes('renderTextLayer={!props.nativeBody}'))
  const ink = await readFile(resolve(runtime, 'upstream/src/renderer/src/features/ink/InkLayer.tsx'), 'utf8')
  const composed = transformNativePDFPointerCapture(transformInkLayer(ink))
  assert.ok(composed.includes('captureNativePDFPointer(svg, event.pointerId, event.nativeEvent)'))
  assert.ok(composed.includes('captureNativePDFPointer(event.currentTarget, event.pointerId, event.nativeEvent)'))
  const settingsPath = resolve(runtime, 'upstream/src/renderer/src/features/settings/SettingsApp.tsx')
  const settings = await readFile(settingsPath, 'utf8')
  assert.ok(nativePDFPlugin().transform(settings, settingsPath).code.includes('experimental: <><ExperimentalPanel settings={settings} /><NativePDFDevelopmentSetting /></>'))
  assert.throws(() => nativePDFPlugin().transform(settings.replace('experimental: <ExperimentalPanel', 'experimentalChanged: <ExperimentalPanel'), settingsPath), /anchor changed/)
  console.log('Native PDF journal replay/ACK/history ownership and original-viewer transform PASS')
} finally { await rm(folder, { recursive: true, force: true }) }
