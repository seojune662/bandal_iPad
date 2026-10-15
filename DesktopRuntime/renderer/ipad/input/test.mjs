import assert from 'node:assert/strict'
import { readFile, mkdtemp, rm } from 'node:fs/promises'
import { resolve, join } from 'node:path'
import { tmpdir } from 'node:os'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import inputPlugin, { adaptInputSource } from './index.mjs'
import pencilPlugin from '../../pencil/index.mjs'
import nativePDFPlugin from '../../nativePDF/index.mjs'
import { adaptStabilitySource } from '../stability/index.mjs'
await import('./workspace-test.mjs')

const { require } = dependencies(), { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
for (const name of ['PdfTab.tsx','PdfToolbar.tsx','PdfPageView.tsx','tools/DrawingLayer.tsx','tools/PdfToolRail.tsx']) {
  const file = resolve(runtime, 'upstream/src/renderer/src/features/pdf', name), original = await readFile(file,'utf8')
  assert.ok(adaptInputSource(original,file)?.code)
}
const history = resolve(runtime,'upstream/src/renderer/src/features/pdf/tools/useDrawings.ts')
assert.equal(adaptInputSource(await readFile(history,'utf8'),history), null, 'Storage and history never enter this transform')
const tab = resolve(runtime,'upstream/src/renderer/src/features/pdf/PdfTab.tsx')
const originalTab = await readFile(tab,'utf8')
assert.throws(() => adaptInputSource(originalTab.replace('<PdfViewer\n','<DifferentViewer\n'), tab), /anchor changed/)
const native = nativePDFPlugin()
const composedPDF = adaptInputSource(native.transform(originalTab,tab).code,tab).code
assert.match(composedPDF, /<PdfInputProvider[^>]*>[\s\S]*<PdfViewer[\s\S]*onNativeActivate=/)
assert.match(composedPDF, /drawingsApi=\{\{ \.\.\.drawingsApi,[\s\S]*flush: nativePDF.flush/)
const noteFile=resolve(runtime,'upstream/src/renderer/src/features/notes/NoteTab.tsx')
const composedNote=adaptStabilitySource(adaptInputSource(await readFile(noteFile,'utf8'),noteFile).code,noteFile).code
assert.match(composedNote,/deactivateMarkdownInput\(containerRef.current\)\n      flushPendingEditorMarkdown\(\)/)
assert.match(composedNote,/trackDocumentClose\(\(\) => preserveNoteOnClose\(/)
const cacheDir = await mkdtemp(join(tmpdir(),'bandal-ipad-input-'))
const server = await createServer({ configFile:false, root:runtime, cacheDir, plugins:[inputPlugin(),pencilPlugin(),react()],
  server:{host:'127.0.0.1',port:0}, resolve:{dedupe:['react','react-dom']} })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({viewport:{width:1366,height:1024},hasTouch:true}), errors=[]
  page.on('pageerror',error=>errors.push(error.message))
  await page.goto(server.resolvedUrls.local[0]+'renderer/ipad/input/test-fixture.html')
  await page.waitForFunction(()=>window.inputFixture?.stores.size===2)
  await page.getByRole('toolbar',{name:'PDF 필기 도구',exact:true}).waitFor()
  const snapshot = () => page.evaluate(() => Object.fromEntries([...window.inputFixture.stores].map(([id,store])=> {
    const {activeTool,color,width,opacity,favorites,position,collapsed}=store.getState();return[id,{activeTool,color,width,opacity,favorites,position,collapsed}]
  })))
  assert.equal((await snapshot()).a.activeTool,'pen')
  assert.equal((await snapshot()).b.activeTool,'pen')
  const initialFavorites=(await snapshot()).a.favorites
  assert.deepEqual(initialFavorites.map(item=>item.color),['ink','blue','red'])
  const migrated=await page.evaluate(async()=>{
    const preferences=await import('/renderer/ipad/input/preferences.ts')
    return preferences.normalizePreferences({version:1,presets:[{color:'green',width:.012,opacity:.7},{color:'violet',width:.004,opacity:.95}],position:{x:.2,y:.3}})
  })
  assert.equal(migrated.version,2);assert.equal(migrated.favorites.length,3)
  assert.deepEqual(migrated.favorites[0],{color:'green',width:.012,opacity:.7})
  assert.equal(migrated.favorites[1].color,'violet');assert.equal(migrated.favorites[2].color,'red')
  assert.deepEqual(migrated.recentPen,migrated.favorites[0]);assert.deepEqual(migrated.position,{x:.2,y:.3});assert.equal(migrated.collapsed,false)
  assert.equal(await page.getByRole('toolbar',{name:'PDF 필기 도구',exact:true}).count(),1)
  const unchanged = await page.evaluate(()=>({tool:window.inputFixture.legacy().activeTool,color:window.inputFixture.legacy().color,history:window.inputFixture.legacy().histories['existing-whiteboard'].undo.length}))
  assert.deepEqual(unchanged,{tool:'eraser',color:'violet',history:1})
  await page.setViewportSize({width:1470,height:1024})
  await page.waitForFunction(()=>document.querySelector('[data-panel="a"]').getBoundingClientRect().width===720)
  const quick=page.locator('.ipad-pdf-palette .ipad-pdf-quick-favorite')
  await quick.first().waitFor()
  assert.equal(await quick.count(),3)
  assert.equal(await page.locator('.ipad-pdf-palette button').count(),14)
  const quickSizes=await quick.evaluateAll(buttons=>buttons.map(button=>{const rect=button.getBoundingClientRect();return{width:rect.width,height:rect.height}}))
  assert.ok(quickSizes.every(size=>size.width>=44&&size.height>=44))
  await page.getByRole('button',{name:'즐겨찾는 펜 2 바로 선택',exact:true}).tap()
  assert.equal((await snapshot()).a.color,'blue');assert.equal((await snapshot()).a.activeTool,'pen')
  await page.getByRole('button',{name:'즐겨찾는 펜 1 바로 선택',exact:true}).tap()
  const at720=await page.locator('.ipad-pdf-palette').boundingBox()
  assert.ok(at720.width<=696&&at720.height<=60,'The wide palette fits its three direct favorite slots in one row')
  await page.setViewportSize({width:1366,height:1024})
  await page.waitForFunction(()=>!document.querySelector('.ipad-pdf-quick-favorite'))
  assert.equal(await page.locator('.ipad-pdf-palette button').count(),11,'Below720px favorites remain in their editable styles popup')

  // The real original DrawingLayer gets the provider's pen on its first event.
  const stroke = async (panel,id=101,targetPage=page) => targetPage.evaluate(({panel,id})=> {
    const svg=document.querySelector(`[data-panel="${panel}"] .ink-layer`), box=svg.getBoundingClientRect()
    const capture=svg.setPointerCapture.bind(svg);svg.setPointerCapture=value=>{if(value<100)capture(value)}
    for(const [type,x,y] of [['pointerdown',70,230],['pointermove',170,270],['pointerup',190,275]])
      svg.dispatchEvent(new PointerEvent(type,{pointerType:'pen',pointerId:id,clientX:box.x+x,clientY:box.y+y,pressure:.5,button:0,buttons:type==='pointerup'?0:1,bubbles:true,cancelable:true}))
  },{panel,id})
  await stroke('a')
  await page.waitForFunction(()=>window.inputFixture.saved.filter(item=>item.relPath==='a.pdf').length===1)
  await stroke('b',102)
  await page.waitForFunction(()=>window.inputFixture.saved.filter(item=>item.relPath==='b.pdf').length===1)
  assert.equal(await page.locator('[data-fixture-panel="b"] [data-ipad-pdf-active]').getAttribute('data-ipad-pdf-active'),'true','First inactive split contact activates before the same stroke handler')
  await page.getByRole('button',{name:'되돌리기',exact:true}).click()
  await page.waitForFunction(()=>window.inputFixture.saved.filter(item=>item.relPath==='b.pdf').length===0)
  assert.equal(await page.evaluate(()=>window.inputFixture.saved.filter(item=>item.relPath==='a.pdf').length),1)
  await page.getByRole('button',{name:'다시 실행',exact:true}).click()
  await page.waitForFunction(()=>window.inputFixture.saved.filter(item=>item.relPath==='b.pdf').length===1)
  await page.getByRole('button',{name:'형광펜',exact:true}).click()
  await page.getByRole('button',{name:'Focus A',exact:true}).click()
  assert.equal((await snapshot()).a.activeTool,'pen')
  assert.equal((await snapshot()).b.activeTool,'highlighter')
  await page.getByRole('button',{name:'Focus B',exact:true}).click()
  assert.equal(await page.getByRole('button',{name:'형광펜',exact:true}).getAttribute('aria-pressed'),'true')
  await page.getByRole('button',{name:'Focus A',exact:true}).click()

  await page.getByRole('button',{name:'필기 스타일',exact:true}).click()
  await page.getByRole('button',{name:'파랑',exact:true}).click()
  const thicknessSlider=page.getByRole('slider',{name:'선 굵기'}),opacitySlider=page.getByRole('slider',{name:'불투명도'})
  assert.equal(await thicknessSlider.inputValue(),'4');assert.equal(await thicknessSlider.getAttribute('aria-valuetext'),'4 / 25')
  assert.equal(await opacitySlider.inputValue(),'95');assert.equal(await opacitySlider.getAttribute('aria-valuetext'),'95%')
  const sliderBounds=await opacitySlider.boundingBox()
  assert.ok(sliderBounds.height>=44)
  await opacitySlider.tap({position:{x:sliderBounds.width*.3,y:sliderBounds.height/2}})
  assert.ok((await snapshot()).a.opacity<.5,'A trusted WebKit finger tap on the track changes the original panel store')
  const thicknessBounds=await thicknessSlider.boundingBox(),beforeRangeDrag=(await snapshot()).a.width
  await page.mouse.move(thicknessBounds.x+thicknessBounds.width*.13,thicknessBounds.y+thicknessBounds.height/2)
  await page.mouse.down()
  await page.mouse.move(thicknessBounds.x+thicknessBounds.width*.6,thicknessBounds.y+thicknessBounds.height/2,{steps:8})
  await page.mouse.up()
  assert.notEqual((await snapshot()).a.width,beforeRangeDrag,'Trusted WebKit range dragging must update width, without assigning input.value')
  await opacitySlider.focus();await page.keyboard.press('Home');await page.keyboard.press('ArrowRight')
  assert.equal((await snapshot()).a.opacity,.15,'Hardware range adjustment remains available')
  await page.keyboard.press('End');await page.keyboard.press('ArrowLeft')
  assert.equal((await snapshot()).a.opacity,.95)
  await thicknessSlider.focus();await page.keyboard.press('Home')
  assert.equal((await snapshot()).a.width,.001,'The accessible integer minimum maps exactly to the existing normalized width')
  await page.keyboard.press('End')
  assert.equal((await snapshot()).a.width,.025,'The accessible integer maximum maps exactly to the existing normalized width')
  const exclusionCoversRanges=await page.evaluate(async()=>{
    const surfaces=await import('/renderer/ipad/nativeSurfaces.ts');await surfaces.flushNativeSurfaceLayout()
    const regions=window.inputFixture.calls.filter(call=>call.channel==='runtime:nativeSurfaces').at(-1).payload.overlays
    return [...document.querySelectorAll('.ipad-pdf-popover input[type="range"]')].every(input=>{
      const rect=input.getBoundingClientRect()
      return regions.some(region=>region.x<=rect.left&&region.y<=rect.top&&region.x+region.width>=rect.right&&region.y+region.height>=rect.bottom)
    })
  })
  assert.equal(exclusionCoversRanges,true,'Both full 44pt range targets are inside the acknowledged native exclusion')
  assert.equal(await page.evaluate(()=>window.inputFixture.saved.length),2,'Style interactions never create paper ink')
  await page.getByRole('slider',{name:'선 굵기'}).evaluate(element=> {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(element,'12')
    element.dispatchEvent(new Event('input',{bubbles:true}));element.dispatchEvent(new PointerEvent('pointerup',{pointerType:'touch',bubbles:true}))
  })
  await page.waitForFunction(()=>window.inputFixture.stores.get('a').getState().width===.012)
  await page.getByRole('button',{name:'초록',exact:true}).click()
  await page.getByRole('button',{name:'빨강',exact:true}).click()
  assert.deepEqual((await snapshot()).a.favorites,initialFavorites,'Style edits must never evict or overwrite a favorite')
  await page.getByRole('button',{name:'즐겨찾는 펜 1에 현재 펜 저장',exact:true}).click()
  const savedFavorite=(await snapshot()).a.favorites[0]
  assert.deepEqual(savedFavorite,{color:'red',width:.012,opacity:.95})
  assert.deepEqual(await page.evaluate(()=>JSON.parse(localStorage.getItem('bandal.ipad.pdf-input.v2')).recentPen),savedFavorite,'UI units never enter canonical recent-pen preferences')
  assert.deepEqual(await page.evaluate(()=>JSON.parse(localStorage.getItem('bandal.ipad.pdf-input.v2')).favorites[0]),savedFavorite,'Favorite persistence retains the original normalized style exactly')
  assert.deepEqual((await snapshot()).a.favorites.slice(1),initialFavorites.slice(1),'Saving changes only the chosen slot')
  assert.deepEqual((await snapshot()).b.favorites[0],savedFavorite,'Favorites update across already open PDFs without changing their tools')
  assert.equal((await snapshot()).b.activeTool,'highlighter')
  await page.getByRole('button',{name:'즐겨찾는 펜 2: 파랑',exact:true}).click()
  assert.equal((await snapshot()).a.color,'blue');assert.equal((await snapshot()).a.width,.004)
  assert.equal(await page.evaluate(()=>JSON.parse(localStorage.getItem('bandal.ipad.pdf-input.v2')).recentPen.color),'blue','Choosing a favorite updates the separate recent pen')
  await page.getByRole('button',{name:'초록',exact:true}).click()
  await page.getByRole('button',{name:'즐겨찾는 펜 1: 빨강',exact:true}).click()
  assert.equal((await snapshot()).a.color,'red');assert.equal((await snapshot()).a.width,.012)
  assert.deepEqual((await snapshot()).a.favorites[0],savedFavorite)
  await page.getByRole('button',{name:'도구 메뉴 닫기',exact:true}).click()
  await page.getByRole('button',{name:'선택',exact:true}).click()
  await page.getByRole('button',{name:'Focus B',exact:true}).click();await page.getByRole('button',{name:'Focus A',exact:true}).click()
  assert.equal((await snapshot()).a.activeTool,'select','Focus does not reset an explicit tool')
  await page.getByRole('button',{name:'Reopen A',exact:true}).click()
  await page.waitForFunction(()=>window.inputFixture.stores.get('a')?.getState().activeTool==='pen')
  assert.equal((await snapshot()).a.color,'red');assert.equal((await snapshot()).a.width,.012)
  assert.deepEqual((await snapshot()).a.favorites[0],savedFavorite,'Fixed slots survive reopening')

  // Collapsing preserves the active tool and style; resizing is protected until
  // the new native exclusion rectangle has been acknowledged.
  await page.getByRole('button',{name:'지우개',exact:true}).click()
  const beforeCollapse=(await snapshot()).a, countBeforeCollapse=await page.evaluate(()=>window.inputFixture.saved.length)
  await page.evaluate(async()=>{const api=await import('/renderer/ipad/nativeSurfaces.ts');await api.flushNativeSurfaceLayout();window.inputFixture.defer(true)})
  await page.getByRole('button',{name:'필기 도구 접기',exact:true}).evaluate(button=>{
    const rect=button.getBoundingClientRect()
    for(const type of ['pointerdown','pointerup'])button.dispatchEvent(new PointerEvent(type,{pointerType:'pen',pointerId:950,clientX:rect.x+22,clientY:rect.y+22,bubbles:true,cancelable:true}))
  })
  await page.waitForFunction(()=>window.inputFixture.waiting()>0)
  assert.equal(await page.locator('.ipad-pdf-palette button').count(),11,'Palette size cannot change before native input ownership ACK')
  await page.evaluate(()=>{window.inputFixture.defer(false);window.inputFixture.ack()})
  await page.waitForFunction(()=>document.querySelector('.ipad-pdf-palette').dataset.collapsed==='true')
  await page.waitForFunction(()=>window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').at(-1).payload.inputBlocked===false)
  assert.equal(await page.locator('.ipad-pdf-palette button').count(),2)
  assert.deepEqual((await snapshot()).a,{...beforeCollapse,collapsed:true},'Collapse never selects another tool or changes its style')
  assert.equal(await page.evaluate(()=>window.inputFixture.saved.length),countBeforeCollapse,'Pencil collapse must not make a paper dot')
  await page.getByRole('button',{name:'필기 도구 이동',exact:true}).focus();await page.keyboard.press('ArrowRight')
  await page.waitForFunction(()=>window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').at(-1).payload.inputBlocked===false)
  const collapsedPosition=(await snapshot()).a.position
  assert.ok(collapsedPosition.x>beforeCollapse.position.x,'Collapsed palette remains movable')
  await page.getByRole('button',{name:'Focus B',exact:true}).click()
  assert.equal((await snapshot()).b.collapsed,false,'An existing panel retains its own expanded/collapsed choice')
  await page.getByRole('button',{name:'Focus A',exact:true}).click()
  assert.equal((await snapshot()).a.collapsed,true)
  await page.getByRole('button',{name:'Reopen A',exact:true}).click()
  await page.waitForFunction(()=>window.inputFixture.stores.get('a')?.getState().activeTool==='pen')
  assert.equal((await snapshot()).a.collapsed,true);assert.deepEqual((await snapshot()).a.position,collapsedPosition)
  assert.equal((await snapshot()).a.color,'red');assert.equal((await snapshot()).a.width,.012,'A reopened collapsed PDF still starts ready with its recent pen')
  await page.getByRole('button',{name:'필기 도구 펴기',exact:true}).click()
  await page.waitForFunction(()=>document.querySelector('.ipad-pdf-palette').dataset.collapsed==='false')
  await page.waitForFunction(()=>window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').at(-1).payload.inputBlocked===false)
  assert.equal((await snapshot()).a.activeTool,'pen');assert.equal((await snapshot()).a.color,'red')
  const nativeExcludesPalette=()=>page.evaluate(()=>{
    const rect=document.querySelector('.ipad-pdf-palette').getBoundingClientRect(),state=window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').at(-1).payload
    return !state.inputBlocked&&state.overlays.some(box=>box.x<=rect.x&&box.y<=rect.y&&box.x+box.width>=rect.right&&box.y+box.height>=rect.bottom)
  })
  assert.equal(await nativeExcludesPalette(),true,'Expanded palette has its final native exclusion before input resumes')
  assert.equal(await page.evaluate(()=>window.inputFixture.saved.length),countBeforeCollapse)
  await page.setViewportSize({width:1150,height:1024})
  await page.waitForFunction(()=>document.querySelector('[data-panel="a"]').getBoundingClientRect().width===560)
  const at560=await page.locator('.ipad-pdf-palette').boundingBox()
  assert.ok(at560.width<=536&&at560.height<=60,'All eleven expanded controls fit one row inside a560px panel')

  // Page navigation, zoom, notes and export remain original/canonical actions.
  await page.getByRole('button',{name:'PDF 문서 도구',exact:true}).click()
  const popup=page.getByRole('dialog',{name:'PDF 문서 도구',exact:true})
  const jump=popup.getByRole('textbox',{name:'페이지 이동',exact:true})
  await jump.fill('2');await jump.press('Enter')
  await popup.getByRole('button',{name:'확대',exact:true}).click()
  await popup.getByRole('button',{name:'페이지 필기',exact:true}).click()
  await popup.getByRole('button',{name:'주석 포함 PDF 내보내기',exact:true}).click()
  await page.waitForFunction(()=>window.inputFixture.actions.includes('export'))
  assert.ok((await page.evaluate(()=>window.inputFixture.actions)).includes('page:2'))
  assert.ok((await page.evaluate(()=>window.inputFixture.actions)).includes('zoom-in'))
  assert.ok((await page.evaluate(()=>window.inputFixture.actions)).includes('notes'))
  assert.equal(await page.getByRole('button',{name:'주석 도구',exact:true}).count(),0,'No second annotation toolbar')
  await page.getByRole('button',{name:'도구 메뉴 닫기',exact:true}).click()

  // A native mask ACK must precede movement; final position ACK precedes release.
  await page.evaluate(async()=>{const api=await import('/renderer/ipad/nativeSurfaces.ts');await api.flushNativeSurfaceLayout();window.inputFixture.defer(true)})
  const palette=page.locator('.ipad-pdf-palette'), before=await palette.boundingBox(), handle=page.getByRole('button',{name:'필기 도구 이동'})
  const grip=await handle.boundingBox()
  await page.mouse.move(grip.x+22,grip.y+22);await page.mouse.down()
  await page.waitForFunction(()=>window.inputFixture.waiting()>0)
  await page.mouse.move(grip.x+122,grip.y+142)
  assert.deepEqual(await palette.boundingBox(),before,'Pending native ownership cannot move HTML over active ink')
  await page.evaluate(()=>{window.inputFixture.defer(false);window.inputFixture.ack()})
  await page.waitForFunction(()=>document.querySelector('.ipad-pdf-palette').getBoundingClientRect().top>100)
  await page.mouse.up()
  await page.waitForFunction(()=>window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').at(-1).payload.inputBlocked===false)
  const nativeCalls=await page.evaluate(()=>window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').map(item=>item.payload))
  const release=nativeCalls.findLastIndex(item=>!item.inputBlocked)
  assert.equal(nativeCalls[release-1].inputBlocked,true)
  assert.deepEqual(nativeCalls[release-1].overlays,nativeCalls[release].overlays)
  const dragged=await palette.boundingBox(), viewport=await page.locator('[data-panel="a"]').boundingBox()
  assert.ok(dragged.x>=viewport.x+11&&dragged.x+dragged.width<=viewport.x+viewport.width-11)
  await page.setViewportSize({width:780,height:1024})
  await page.waitForFunction(()=>document.querySelector('.ipad-pdf-palette').classList.contains('ipad-pdf-palette--compact'))
  const compact=await palette.boundingBox(), narrow=await page.locator('[data-panel="a"]').boundingBox()
  assert.ok(compact.x>=narrow.x+11&&compact.x+compact.width<=narrow.x+narrow.width-11)
  assert.ok(compact.height<=110,'A375px panel needs only two rows for eleven controls')
  const sizes=await palette.locator('button').evaluateAll(buttons=>buttons.map(button=>({width:button.getBoundingClientRect().width,height:button.getBoundingClientRect().height})))
  assert.ok(sizes.every(size=>size.width>=44&&size.height>=44))

  // The manager retains release intent when the final geometry ACK fails.
  // Losing the original notice must not strand native input ownership.
  await page.evaluate(async()=>{const api=await import('/renderer/ipad/nativeSurfaces.ts');await api.flushNativeSurfaceLayout();window.inputFixture.failSurfaceAfter(1)})
  await handle.focus();await page.keyboard.press('ArrowDown')
  await page.waitForFunction(()=>window.inputFixture.operationErrors.some(item=>item.operation==='필기 도구 이동'))
  await page.evaluate(async()=>{window.inputFixture.operationErrors.length=0;const api=await import('/renderer/ipad/nativeSurfaces.ts');await api.flushNativeSurfaceLayout()})
  await page.waitForFunction(()=>window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').at(-1).payload.inputBlocked===false)
  await page.evaluate(async()=>{const api=await import('/renderer/ipad/nativeSurfaces.ts');await api.flushNativeSurfaceLayout();window.inputFixture.defer(true)})
  const noticesBeforeSwitch=await page.evaluate(()=>window.inputFixture.operationErrors.length)
  await handle.focus();await page.keyboard.press('ArrowDown')
  await page.waitForFunction(()=>window.inputFixture.waiting()>0)
  await page.getByRole('button',{name:'Focus B',exact:true}).click()
  await page.evaluate(()=>{window.inputFixture.defer(false);window.inputFixture.ack()})
  await page.waitForFunction(()=>window.inputFixture.calls.filter(item=>item.channel==='runtime:nativeSurfaces').at(-1).payload.inputBlocked===false)
  assert.equal(await page.evaluate(()=>window.inputFixture.operationErrors.length),noticesBeforeSwitch,'Closing a palette during acquisition releases ownership without an error')
  await page.getByRole('button',{name:'Focus A',exact:true}).click()

  const beforeModal=await snapshot(), countBeforeModal=await page.evaluate(()=>window.inputFixture.saved.length)
  await page.evaluate(()=>{const dialog=document.createElement('div');dialog.id='modal-fixture';dialog.role='dialog';dialog.setAttribute('aria-modal','true');dialog.style.cssText='position:fixed;inset:20px;background:white';document.body.append(dialog)})
  await palette.waitFor({state:'detached'})
  await page.keyboard.press('e');await page.keyboard.press('Meta+z')
  assert.equal((await snapshot()).a.activeTool,beforeModal.a.activeTool)
  assert.equal(await page.evaluate(()=>window.inputFixture.saved.length),countBeforeModal)
  await page.evaluate(()=>document.getElementById('modal-fixture').remove())
  await palette.waitFor({state:'visible'})

  // Pencil controls use their real click owner once, without a paper dot.
  const drawingCount=await page.evaluate(()=>window.inputFixture.saved.length)
  await page.getByRole('button',{name:'형광펜',exact:true}).evaluate(button=> {
    const rect=button.getBoundingClientRect()
    for(const type of ['pointerdown','pointerup']) button.dispatchEvent(new PointerEvent(type,{pointerType:'pen',pointerId:900,clientX:rect.x+22,clientY:rect.y+22,bubbles:true,cancelable:true}))
  })
  assert.equal((await snapshot()).a.activeTool,'highlighter')
  assert.equal(await page.evaluate(()=>window.inputFixture.saved.length),drawingCount)

  // Strict Pencil ignore includes compatibility click and selection attempts.
  await page.locator('[data-panel="a"]').focus()
  const blocked=await page.getByRole('textbox',{name:'Markdown fixture'}).evaluate(element=> {
    const box=element.getBoundingClientRect(), previous=document.activeElement, results=[]
    for(const type of ['pointerdown','pointermove','pointerup']) {
      const event=new PointerEvent(type,{pointerType:'pen',pointerId:800,clientX:box.x+10,clientY:box.y+10,bubbles:true,cancelable:true});element.dispatchEvent(event);results.push(event.defaultPrevented)
    }
    for(const type of ['mousedown','mouseup','click','dblclick','selectstart']) {
      const event=new MouseEvent(type,{bubbles:true,cancelable:true});element.dispatchEvent(event);results.push(event.defaultPrevented)
    }
    return{results,sameFocus:document.activeElement===previous,text:element.textContent}
  })
  assert.ok(blocked.results.every(Boolean));assert.equal(blocked.sameFocus,true);assert.equal(blocked.text,'Markdown text')
  const note=page.getByRole('textbox',{name:'Markdown fixture'});await note.tap()
  await page.keyboard.type(' keyboard')
  assert.ok((await note.textContent()).includes('keyboard'))
  const ime=await note.evaluate(element=> {
    const results=[]
    for(const type of ['compositionstart','compositionupdate','beforeinput','input','compositionend']) {
      const event=type.includes('input')?new InputEvent(type,{bubbles:true,cancelable:true,data:'한',inputType:'insertCompositionText',isComposing:true}):new CompositionEvent(type,{bubbles:true,cancelable:true,data:'한'})
      element.dispatchEvent(event);results.push(event.defaultPrevented)
    }
    return results
  })
  assert.ok(ime.every(value=>!value),'IME/text events remain untouched')
  assert.equal(await note.evaluate(element=>window.inputFixture.mayAutoFocusMarkdown(element)),true)
  const textBeforeBlur=await note.textContent()
  await note.evaluate(async element=>{const api=await import('/renderer/ipad/input/markdown.ts');api.deactivateMarkdownInput(element.closest('.note-tab'))})
  assert.equal(await note.evaluate(element=>document.activeElement===element),false,'Panel deactivation releases the Markdown keyboard')
  assert.equal(await note.evaluate(element=>window.inputFixture.mayAutoFocusMarkdown(element)),false,'A stale finger intent cannot autofocus after tab switch')
  assert.equal(await note.textContent(),textBeforeBlur,'Keyboard ownership never rewrites the note')
  await page.waitForFunction(()=> {
    const box=document.querySelector('.note-editor').getBoundingClientRect(), last=window.inputFixture.regions.at(-1)
    return last?.protected.some(rect=>rect.x<=box.x&&rect.y<=box.y&&rect.x+rect.width>=box.right-1&&rect.y+rect.height>=box.bottom-1)
  })
  assert.equal(await page.evaluate(()=>window.inputFixture.legacy().activeTool),'eraser')
  assert.equal(await page.evaluate(()=>window.inputFixture.legacy().histories['existing-whiteboard'].undo.length),1)
  assert.deepEqual(errors,[])
  const verifyStatusEdges = async targetPage => {
    await targetPage.evaluate(() => {
      // Match a document that reaches the real window edge. Keep the actual
      // fixture tab action at that edge to catch status hit-test interception.
      document.querySelector('main').style.padding='0'
      const tab=[...document.querySelectorAll('nav button')].find(button=>button.textContent==='Focus B')
      tab.style.cssText='position:fixed;right:0;top:0;width:60px;height:44px'
    })
    const tab=targetPage.getByRole('button',{name:'Focus B',exact:true})
    await tab.click()
    const collapse=targetPage.getByRole('button',{name:'필기 도구 접기',exact:true})
    if(await collapse.count())await collapse.click()
    await targetPage.getByRole('button',{name:'필기 도구 펴기',exact:true}).waitFor()
    for(const size of [{width:375,height:400},{width:834,height:600},{width:1366,height:1024}]) {
      await targetPage.setViewportSize(size)
      for(const position of [{x:0,y:0},{x:1,y:0},{x:1,y:1}]) {
        await targetPage.evaluate(async position=>{
          window.inputFixture.stores.get('b').getState().setPosition(position)
          await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>requestAnimationFrame(resolve))))
        },position)
        const bounds=await targetPage.evaluate(()=>{
          const status=document.querySelector('.ipad-pdf-input-status').getBoundingClientRect(),palette=document.querySelector('.ipad-pdf-palette').getBoundingClientRect(),panel=document.querySelector('[data-panel="b"]').getBoundingClientRect()
          const visual=window.visualViewport,left=Math.max(panel.left,visual?.offsetLeft??0),top=Math.max(panel.top,visual?.offsetTop??0)
          const right=Math.min(panel.right,(visual?.offsetLeft??0)+(visual?.width??innerWidth)),bottom=Math.min(panel.bottom,(visual?.offsetTop??0)+(visual?.height??innerHeight))
          return{inside:status.left>=left&&status.top>=top&&status.right<=right&&status.bottom<=bottom,
            separate:status.bottom<=palette.top-7||status.top>=palette.bottom+7,status:status.toJSON(),palette:palette.toJSON(),viewport:{left,top,right,bottom}}
        })
        assert.equal(bounds.inside,true,`Status stays inside the document at ${JSON.stringify({size,position,bounds})}`)
        assert.equal(bounds.separate,true,`Status cannot cover palette controls at ${JSON.stringify({size,position,bounds})}`)
        await tab.click()
        assert.equal(await targetPage.locator('[data-fixture-panel="b"] [data-ipad-pdf-active]').getAttribute('data-ipad-pdf-active'),'true','The top-right tab action remains reachable above the status')
      }
    }
  }
  const sharedPage = await browser.newPage({viewport:{width:1366,height:1024},hasTouch:true})
  await sharedPage.goto(server.resolvedUrls.local[0]+'renderer/ipad/input/test-fixture.html?sharedPDF=1&deferDrawings=1')
  await sharedPage.waitForFunction(()=>window.inputFixture.waitingDrawings()===2)
  const loadingStatus=sharedPage.getByRole('status').filter({hasText:'필기를 불러오는 중…'})
  await loadingStatus.waitFor({state:'visible'})
  await sharedPage.getByRole('button',{name:'필기 도구 접기',exact:true}).click()
  await sharedPage.getByRole('button',{name:'필기 도구 펴기',exact:true}).waitFor()
  assert.equal(await loadingStatus.isVisible(),true,'Initial drawing progress remains identifiable with a collapsed palette')
  const statusBounds=await loadingStatus.boundingBox()
  assert.ok(statusBounds.y>=0&&statusBounds.x>=0&&statusBounds.x+statusBounds.width<=1366,'The loading status stays within the visible workspace')
  await verifyStatusEdges(sharedPage)
  await sharedPage.getByRole('button',{name:'필기 도구 펴기',exact:true}).click()
  await sharedPage.evaluate(()=>window.inputFixture.acknowledgeDrawings())
  await loadingStatus.waitFor({state:'detached'})
  await sharedPage.getByRole('button',{name:'Focus B',exact:true}).click()
  await sharedPage.getByRole('button',{name:'형광펜',exact:true}).click()
  await sharedPage.getByRole('button',{name:'Focus A',exact:true}).click()
  await stroke('a',501,sharedPage)
  await sharedPage.waitForFunction(()=>window.inputFixture.saved.length===1)
  await stroke('b',502,sharedPage)
  await sharedPage.waitForFunction(()=>window.inputFixture.saved.length===2)
  assert.equal(await sharedPage.locator('[data-fixture-panel="b"] [data-ipad-pdf-active]').getAttribute('data-ipad-pdf-active'),'true')
  const sharedState=await sharedPage.evaluate(()=>({tools:[...window.inputFixture.stores].map(([id,store])=>[id,store.getState().activeTool]),
    saved:window.inputFixture.saved.map(({relPath,kind,style})=>({relPath,kind,style}))}))
  assert.deepEqual(sharedState.tools,[['a','pen'],['b','highlighter']],'Two panels of the same PDF retain separate explicit tool selections')
  assert.deepEqual(sharedState.saved.map(drawing=>drawing.relPath),['shared.pdf','shared.pdf'])
  assert.deepEqual(sharedState.saved.map(drawing=>drawing.kind),['ink','highlighter'],'First contact in the inactive duplicate PDF uses that panel’s retained tool')
  assert.deepEqual(sharedState.saved.map(drawing=>drawing.style.color),['ink','yellow'])
  await sharedPage.close()

  const readErrorPage=await browser.newPage({viewport:{width:1366,height:1024}})
  await readErrorPage.goto(server.resolvedUrls.local[0]+'renderer/ipad/input/test-fixture.html?deferDrawings=1&failDrawings=1&longDrawingsError=1')
  await readErrorPage.waitForFunction(()=>window.inputFixture.waitingDrawings()===2)
  await readErrorPage.getByRole('status').filter({hasText:'필기를 불러오는 중…'}).waitFor()
  await readErrorPage.getByRole('button',{name:'필기 도구 접기',exact:true}).click()
  await readErrorPage.getByRole('button',{name:'필기 도구 펴기',exact:true}).waitFor()
  await readErrorPage.evaluate(()=>window.inputFixture.acknowledgeDrawings())
  await readErrorPage.getByRole('status').filter({hasText:'Fixture drawings load failed'}).waitFor({state:'visible'})
  assert.equal(await readErrorPage.getByText('필기를 불러오는 중…',{exact:true}).count(),0,'A failed read replaces progress with the original error instead of waiting forever')
  assert.equal(await readErrorPage.evaluate(()=>window.inputFixture.drawingLoadAttempts),2,'Each panel performs only its original read, with no automatic retry')
  assert.equal(await readErrorPage.evaluate(()=>window.inputFixture.saved.length),0,'Read failure does not synthesize a write')
  await verifyStatusEdges(readErrorPage)
  const longError=readErrorPage.locator('.ipad-pdf-input-status')
  assert.equal(await longError.evaluate(element=>element.scrollHeight>element.clientHeight),true,'Long errors remain inside a bounded scrolling status')
  assert.equal(await longError.evaluate(element=>{element.scrollTop=element.scrollHeight;return element.scrollTop>0}),true,'The complete long error remains reachable by scrolling')
  await readErrorPage.close()
  console.log('PASS PDF scoped defaults/v1 migration/stable favorites/recent pen, collapse persistence and native masks, first inactive-split stroke, canonical undo/redo, palette ACK/resize/retry/modal isolation, document actions, Markdown Pencil ignore and keyboard/IME/tab blur, composed native/stability adapters')
} finally { await browser.close();await server.close();await rm(cacheDir,{recursive:true,force:true}) }
