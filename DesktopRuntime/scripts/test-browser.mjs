import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createRequire } from 'node:module'
import { dependencies, runtime } from './dependencies.mjs'
import { adaptBrowserSource } from '../renderer/browser/index.mjs'
const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild'), { webkit } = require('@playwright/test')
const temporary = await mkdtemp(resolve(tmpdir(), 'bandal-browser-ui-'))
// Every transformed source anchor must still match the original snapshot.
for (const name of ['BrowserPanel.tsx', 'BrowserToolbarOverflow.tsx', 'BrowserProfilePicker.tsx', 'BrowserContextMenu.tsx', 'downloadsStore.ts', 'BrowserDownloadsPanel.tsx', 'BrowserDownloadPage.tsx']) {
  const path = resolve(runtime, 'upstream/src/renderer/src/features/browser', name)
  assert.ok(adaptBrowserSource(await readFile(path, 'utf8'), path))
}
await build({ absWorkingDir: runtime, bundle: true, format: 'esm', platform: 'browser', target: 'safari18', jsx: 'automatic', outfile: resolve(temporary, 'fixture.js'),
  plugins: [{ name: 'original-browser-adapter', setup(build) { build.onLoad({ filter: /\.(tsx?|css)$/ }, async args => {
    const source = await readFile(args.path, 'utf8'), adapted = adaptBrowserSource(source, args.path)
    return adapted ? { contents: adapted.code, loader: args.path.endsWith('tsx') ? 'tsx' : 'ts' } : undefined
  }) } }], stdin: { resolveDir: runtime, loader: 'tsx', contents: `
import { createRoot } from 'react-dom/client'
import { useState } from 'react'
import { BrowserAddressInput } from './upstream/src/renderer/src/features/browser/BrowserAddressInput'
import { BrowserToolbarOverflow } from './upstream/src/renderer/src/features/browser/BrowserToolbarOverflow'
import { BrowserProfilePicker } from './upstream/src/renderer/src/features/browser/BrowserProfilePicker'
import { BrowserDownloadsPanel } from './upstream/src/renderer/src/features/browser/BrowserDownloadsPanel'
import { useDownloads } from './upstream/src/renderer/src/features/browser/downloadsStore'
import { BrowserSiteControls } from './renderer/browser/BrowserSiteControls'
import { BrowserPageControls } from './renderer/browser/BrowserPageControls'
import { BrowserFindBar } from './upstream/src/renderer/src/features/browser/BrowserFindBar'
import { useBrowserGuests } from './upstream/src/renderer/src/features/browser/browserGuestsStore'
import './upstream/src/renderer/src/styles/tokens.css'
import './upstream/src/renderer/src/styles/base.css'
import './upstream/src/renderer/src/features/browser/browser.css'
useDownloads.getState().init()
window.downloadsState = () => useDownloads.getState().downloads
function Fixture() {
 const [url, setURL] = useState('https://example.test/reading'), [downloads, setDownloads] = useState(false), [profile, setProfile] = useState('default')
 window.selectFixtureProfile = setProfile
 const find = useBrowserGuests(state=>state.find.fixture)
 return <div className="browser-panel"><div className="browser-chrome"><div className="browser-toolbar">
 <button className="browser-nav-button" aria-label="뒤로">←</button>
 <BrowserAddressInput value={url} onNavigate={setURL} focusSeq={0} favicon={undefined} isPrivate={false} profileId="default" courseId={null}/>
 <BrowserProfilePicker profileId="default" onChange={async()=>true}/>
 <BrowserToolbarOverflow isPrivate={false} active={true}><div className="ipad-browser-menu-session" data-keep-browser-menu><BrowserProfilePicker profileId="default" onChange={async()=>true}/></div><BrowserSiteControls tabId="fixture" profileId={profile} url={url}/><BrowserPageControls tabId="fixture" title="Fixture"/><button aria-label="다운로드" onClick={()=>setDownloads(true)}>↓</button></BrowserToolbarOverflow>
 </div>{find&&<BrowserFindBar tabId="fixture" state={find}/>}</div>{downloads&&<BrowserDownloadsPanel anchor={new DOMRect(200,50,44,44)} onClose={()=>setDownloads(false)}/>}<div id="url">{url}</div></div>
}
createRoot(document.getElementById('root')).render(<Fixture/>);
` } })
const calls = []
const server = createServer(async (request, response) => {
  try {
    if (request.url === '/fixture.js' || request.url === '/fixture.css') { response.setHeader('Content-Type', request.url.endsWith('.js') ? 'text/javascript' : 'text/css'); response.end(await readFile(resolve(temporary, '.' + request.url))); return }
    response.setHeader('Content-Type', 'text/html')
    response.end(`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta charset="utf-8"><link rel="stylesheet" href="/fixture.css"><div id="root"></div><script>
window.calls=[];window.mode='automatic';window.bandal={platform:'ipad',on(){return ()=>{}},invoke:async(channel,request)=>{window.calls.push({channel,request});
if(channel==='browser:profiles')return[{id:'default',name:'기본',icon:'globe',color:'#456'}];
if(channel==='browser:sitePresentation')return{mode:window.mode,available:true};
if(channel==='browser:setSitePresentation'){if(window.deferPresentation)return await new Promise(resolve=>{window.resolvePresentation=()=>resolve({mode:request.mode,available:true})});window.mode=request.mode;return{mode:window.mode,available:true}};
if(channel==='browser:searchHistory')return{entries:[]};
if(channel==='browser:downloadsSnapshot')return[{id:'fixture-download',webContentsId:null,fileName:'lecture.pdf',receivedBytes:12,totalBytes:50,state:'interrupted',paused:false,relPath:null,courseId:null,recoverable:false,failureReason:'Restarted'}];
if(channel==='favorites:list')return[];return{ok:true}}};
</script><script type="module" src="/fixture.js"></script>`)
  } catch { response.statusCode = 404; response.end() }
})
await new Promise(done => server.listen(0, '127.0.0.1', done))
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1024, height: 768 }, hasTouch: true }), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(`http://127.0.0.1:${server.address().port}/`)
  await page.getByRole('button', { name: '브라우저 도구 더 보기' }).waitFor()
  for (const width of [1024, 600, 360]) {
    await page.setViewportSize({ width, height: 768 })
    const bounds = await page.getByRole('textbox', { name: '주소 또는 검색어' }).count() ? await page.getByRole('textbox', { name: '주소 또는 검색어' }).boundingBox() : await page.getByRole('combobox', { name: '주소 또는 검색어' }).boundingBox()
    assert.ok(bounds.width >= 120 && bounds.height >= 44, `usable address at ${width}: ${JSON.stringify(bounds)}`)
    const more = await page.getByRole('button', { name: '브라우저 도구 더 보기' }).boundingBox()
    assert.ok(more.width >= 44 && more.height >= 44)
    await page.getByRole('button', { name: '브라우저 도구 더 보기' }).click()
    const menu = page.getByRole('dialog', { name: '브라우저 도구', exact: true })
    await menu.waitFor()
    const rect = await menu.boundingBox(); assert.ok(rect.x >= 0 && rect.x + rect.width <= width)
    await menu.getByRole('button', { name: '브라우저 프로필', exact: true }).click()
    await page.getByRole('dialog', { name: '브라우저 프로필 선택' }).waitFor()
    await page.getByRole('button', { name: '닫기', exact: true }).click()
    await menu.getByRole('button', { name: '모바일 웹사이트 요청' }).click()
    assert.equal(await menu.getByRole('button', { name: '모바일 웹사이트 요청' }).getAttribute('aria-pressed'), 'true')
    await page.keyboard.press('Escape')
  }
  await page.setViewportSize({ width: 1024, height: 768 })
  await page.getByRole('button', { name: '브라우저 도구 더 보기' }).click()
  const profileMenu = page.getByRole('dialog', { name: '브라우저 도구', exact: true })
  await page.evaluate(() => { window.deferPresentation = true })
  await profileMenu.getByRole('button', { name: '데스크톱 웹사이트 요청' }).click()
  await page.evaluate(() => { window.mode = 'automatic'; window.selectFixtureProfile('school') })
  await profileMenu.locator('button[aria-label="자동 웹사이트 요청"][aria-pressed="true"]').waitFor()
  await page.evaluate(() => { window.resolvePresentation(); window.deferPresentation = false })
  await page.waitForTimeout(30)
  assert.equal(await profileMenu.getByRole('button', { name: '자동 웹사이트 요청' }).getAttribute('aria-pressed'), 'true', 'A stale presentation response must not override the newly selected profile')
  await page.keyboard.press('Escape')
  const input = page.getByRole('combobox', { name: '주소 또는 검색어' })
  assert.equal(await input.evaluate(element => getComputedStyle(element).fontSize), '16px')
  await input.fill('https://fixture.test/path'); await input.press('Enter')
  assert.equal(await page.locator('#url').textContent(), 'https://fixture.test/path')
  await page.locator('.browser-toolbar > .browser-profile-trigger').click()
  await page.getByRole('dialog', { name: '브라우저 프로필 선택' }).waitFor()
  assert.equal(await page.locator('.browser-profile-manager__avatar').textContent(), '')
  await page.getByRole('button', { name: '닫기', exact: true }).click()
  assert.equal((await page.evaluate(() => window.downloadsState()))[0].fileName, 'lecture.pdf')
  await page.getByRole('button', { name: '브라우저 도구 더 보기' }).click()
  const controls = page.getByRole('dialog', { name: '브라우저 도구', exact: true })
  await controls.getByRole('button', { name: '페이지 확대', exact: true }).click()
  await controls.getByRole('button', { name: '기본 페이지 크기로 (110%)' }).waitFor()
  await controls.getByRole('button', { name: '기본 페이지 크기로 (110%)' }).click()
  await controls.getByRole('button', { name: '기본 페이지 크기로 (100%)' }).waitFor()
  await controls.getByRole('button', { name: '페이지에서 찾기', exact: true }).click()
  await page.getByRole('textbox', { name: '페이지에서 찾기', exact: true }).waitFor()
  const findInput = await page.getByRole('textbox', { name: '페이지에서 찾기', exact: true }).boundingBox()
  assert.ok(findInput.height >= 44)
  await page.getByRole('button', { name: '찾기 닫기' }).click()
  await page.getByRole('button', { name: '브라우저 도구 더 보기' }).click()
  await controls.getByRole('button', { name: '페이지 공유' }).click()
  await page.getByRole('button', { name: '브라우저 도구 더 보기' }).click()
  await page.getByRole('dialog', { name: '브라우저 도구', exact: true }).getByRole('button', { name: '다운로드', exact: true }).click()
  await page.getByRole('dialog', { name: '다운로드', exact: true }).getByRole('button', { name: '다시 받기' }).click()
  await page.getByRole('button', { name: 'lecture.pdf 목록에서 지우기' }).click()
  calls.push(...await page.evaluate(() => window.calls))
  assert.ok(calls.some(call => call.channel === 'browser:downloadFile' && call.request.action === 'retry'))
  assert.ok(calls.some(call => call.channel === 'browser:dismissDownload'))
  assert.ok(calls.some(call => call.channel === 'browser:sharePage' && call.request.tabId === 'fixture'))
  assert.ok(calls.some(call => call.channel === 'browser:pageAction' && call.request.action === 'setZoomLevel' && call.request.args[0] === .53))
  const nativeSource = await readFile(resolve(runtime, '../App/Desktop/BrowserPage.swift'), 'utf8')
  const findScript = nativeSource.match(/static let find = #"""([\s\S]*?)"""#/)?.[1]
  assert.ok(findScript)
  await page.setContent('<p>Alpha <b>beta</b> tail</p><p>ALPHA <i>beta</i> last</p><div hidden>alpha beta</div><p>İstanbul is Unicode text</p>')
  const find = (query, next=false, forward=true, matchCase=false) => page.evaluate(({source,query,next,forward,matchCase}) => new Function('query','next','forward','matchCase',source)(query,next,forward,matchCase), {source:findScript,query,next,forward,matchCase})
  assert.deepEqual(await find('alpha beta'), {matches:2,ordinal:1})
  assert.deepEqual(await find('alpha beta',true), {matches:2,ordinal:2})
  assert.deepEqual(await find('Alpha beta',false,true,true), {matches:1,ordinal:1})
  assert.deepEqual(await find('beta tail ALPHA beta'), {matches:1,ordinal:1})
  assert.deepEqual(await find('Unicode'), {matches:1,ordinal:1})
  assert.equal(await page.evaluate(()=>getSelection().toString()), 'Unicode')
  assert.deepEqual(errors, [])
  console.log('Original WebKit browser controls: 360/600/1024 layouts, URL submission, profile, presentation and restored download retry/dismiss passed')
} finally { await browser.close(); await new Promise(done => server.close(done)); await rm(temporary, { recursive: true, force: true }) }
