import assert from 'node:assert/strict'
import {readFile,mkdtemp,rm} from 'node:fs/promises'
import {join} from 'node:path'
import {tmpdir} from 'node:os'
import {pathToFileURL} from 'node:url'
import {dependencies,runtime} from '../../../scripts/dependencies.mjs'
import plugin,{adaptTouchSource} from './index.mjs'
await import('./workspace-test.mjs')
const {require}=dependencies(),{webkit}=require('@playwright/test'),ts=require('typescript')
for(const name of ['features/materials/WhiteboardsGroup.tsx','features/board/BoardPanel.tsx','features/canvas/CanvasToolRail.tsx']){
  const file=join(runtime,'upstream/src/renderer/src',name),source=await readFile(file,'utf8'),result=adaptTouchSource(source,file)
  assert.ok(result)
  assert.deepEqual(ts.transpileModule(result.code,{fileName:file,compilerOptions:{target:ts.ScriptTarget.ES2022,jsx:ts.JsxEmit.ReactJSX},reportDiagnostics:true}).diagnostics,[])
}
assert.match(adaptTouchSource('',join(runtime,'renderer/bootstrap.ts')).code,/touch.css/)
const{createServer}=await import(pathToFileURL(require.resolve('vite')).href),{default:react}=await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir=await mkdtemp(join(tmpdir(),'bandal-ipad-touch-'))
const server=await createServer({configFile:false,root:runtime,cacheDir,plugins:[plugin(),react()],server:{host:'127.0.0.1',port:0},resolve:{dedupe:['react','react-dom']}})
await server.listen();const browser=await webkit.launch()
try{
  for(const [width,height] of [[1194,900],[507,900],[375,900],[375,400]]){
    const page=await browser.newPage({viewport:{width,height},hasTouch:true}),errors=[]
    page.on('pageerror',error=>errors.push(error.message))
    await page.goto(server.resolvedUrls.local[0]+'renderer/ipad/touch/fixture.html')
    const atLeast44=async locator=>{for(const element of await locator.all()){
      await page.waitForFunction(node=>{const box=node.getBoundingClientRect();return box.width>=43.9&&box.height>=43.9},await element.elementHandle(),{timeout:3000}).catch(()=>{})
      const box=await element.boundingBox();assert.ok(box&&box.width>=43.9&&box.height>=43.9,`44px target at${width}: ${await element.evaluate(node=>node.outerHTML.slice(0,180))} ${JSON.stringify(box)}`)
    }}
    await page.getByRole('button',{name:'생각 정리 더 보기',exact:true}).waitFor()
    await atLeast44(page.locator('.ipad-touch-more,.materials-section-toggle,.whiteboards-group__create'))
    await page.getByRole('button',{name:'생각 정리 더 보기',exact:true}).tap()
    await page.getByRole('menuitem',{name:'이름 변경',exact:true}).tap()
    assert.equal(await page.evaluate(()=>window.touchFixture.opened.length),0,'More must not open the whiteboard')
    await page.getByRole('textbox',{name:'화이트보드 이름',exact:true}).fill('바꾼 이름')
    await page.getByRole('button',{name:'저장',exact:true}).tap()
    await page.getByRole('button',{name:'바꾼 이름 더 보기',exact:true}).waitFor()
    assert.equal(await page.evaluate(()=>window.touchFixture.calls.filter(item=>item.channel==='canvas:rename').length),1,'Original rename handler runs once')
    await page.locator('.whiteboards-group__row').tap()
    assert.equal(await page.evaluate(()=>window.touchFixture.opened.length),1,'Original opening handler still runs')

    await page.getByRole('button',{name:'보드 테스트',exact:true}).tap()
    const more=page.getByRole('button',{name:'연습 과제 더 보기',exact:true})
    await more.waitFor();await atLeast44(more);await atLeast44(page.locator('.board-toggle'))
    await more.tap();await page.getByRole('menuitem',{name:'진행 중',exact:true}).waitFor()
    assert.equal(await page.locator('.board-editor').count(),0,'More must not open the card editor')
    await page.getByRole('menuitem',{name:'진행 중',exact:true}).tap()
    await page.waitForFunction(()=>window.touchFixture.tasks[0].status==='in-progress')
    assert.equal(await page.evaluate(()=>window.touchFixture.calls.filter(item=>item.channel==='board:updateTask'&&item.request.id==='task-0').length),1,'Original move handler updates the selected task once; sibling sort-order updates remain intact')
    await page.getByRole('button',{name:'연습 과제 상세 편집',exact:true}).tap()
    await page.locator('.board-editor').waitFor()
    await atLeast44(page.locator('.board-editor .board-color-picker label,.board-editor .task-schedule__options label'))
    await page.locator('.board-editor .board-color-picker label[title="파랑"]').tap()
    await page.getByRole('button',{name:'저장',exact:true}).tap()
    await page.waitForFunction(()=>window.touchFixture.tasks[0].color==='blue')
    await page.getByRole('button',{name:'달력',exact:true}).tap()
    const day=page.locator(`.calendar-day[data-date-key="${await page.evaluate(()=>window.touchFixture.today)}"]`)
    await day.locator('.calendar-day__more').waitFor();await day.scrollIntoViewIfNeeded()
    await atLeast44(day.locator('.calendar-entry,.calendar-day__more,.calendar-day__number'))
    const contained=await day.evaluate(element=>{const box=element.getBoundingClientRect();return[...element.querySelectorAll('button')].every(button=>{const rect=button.getBoundingClientRect();return rect.left>=box.left&&rect.right<=box.right+1&&rect.bottom<=box.bottom+1})})
    assert.ok(contained,'Larger calendar targets must not be clipped by day cells')
    await day.locator('.calendar-day__more').tap()

    await page.getByRole('button',{name:'화이트보드 도구 테스트',exact:true}).tap()
    const rail=page.getByRole('toolbar',{name:'개인 화이트보드 도구',exact:true})
    await rail.waitFor();await atLeast44(rail.locator('button,input[type="range"],select'));await atLeast44(page.locator('.canvas-tab__title'))
    const unclipped=await rail.evaluate((element,narrow)=>{const box=element.getBoundingClientRect();return element.scrollHeight<=element.clientHeight+1&&[...element.querySelectorAll('button,input[type="range"],select')].every(button=>{const rect=button.getBoundingClientRect();return rect.top>=box.top&&rect.bottom<=box.bottom+1&&(narrow||(rect.left>=box.left&&rect.right<=box.right+1))})},width<700)
    assert.ok(unclipped,'Whiteboard controls must retain their full vertical touch targets')
    if(width<700){
      assert.ok(await rail.evaluate(element=>element.scrollWidth>element.clientWidth),'Narrow toolbar provides horizontal access to every original action')
      assert.ok((await rail.boundingBox()).height<=70,'Narrow toolbar stays in one control row')
      await page.getByText('← 도구를 좌우로 밀어 더 보기 →',{exact:true}).waitFor()
      if(height===400)assert.ok((await page.locator('.canvas-tab__viewport').boundingBox()).height>=200,'At375×400 the whiteboard retains at least200px of paper')
    }
    await rail.getByRole('button',{name:'파랑',exact:true}).tap()
    assert.equal(await page.evaluate(()=>window.touchFixture.ink().color),'blue','Original global whiteboard color owner is unchanged')
    const slider=rail.getByRole('slider',{name:'선 굵기',exact:true}),previous=await slider.inputValue()
    await slider.tap({position:{x:90,y:22}});assert.notEqual(await slider.inputValue(),previous)
    await rail.getByRole('button',{name:'페이지 추가',exact:true}).tap()
    await rail.getByRole('button',{name:'PDF로 내보내기',exact:true}).tap()
    assert.deepEqual(await page.evaluate(()=>window.touchFixture.actions),['page','export'])

    await page.getByRole('button',{name:'탭 테스트',exact:true}).tap()
    await page.locator('.workspace-open-tabs-button').tap()
    await atLeast44(page.locator('.workspace-open-tabs-menu__search'))
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'No document horizontal overflow')
    assert.deepEqual(errors,[]);await page.close()
  }
  console.log('PASS iPad touch: actual WhiteboardsGroup rename/menu, BoardPanel move/editor/calendar, CanvasToolRail44px actions/scrolling with200px paper at375×400, open-tabs search at1194/507/375px')
}finally{await browser.close();await server.close();await rm(cacheDir,{recursive:true,force:true})}
