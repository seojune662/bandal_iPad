import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-surfaces-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, server: { host: '127.0.0.1', port: 0 } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 834, height: 900 } }), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(server.resolvedUrls.local[0] + 'renderer/ipad/native-surfaces-fixture.html')
  await page.waitForFunction(() => window.surfacesFixture)
  const last = () => page.evaluate(() => window.surfacesFixture.calls.filter(call => call.channel === 'runtime:nativeSurfaces').at(-1)?.request)
  await page.evaluate(async () => {
    const api=window.surfacesFixture
    api.setNativeHostBlocked('settings',true)
    api.setNativeHostBlocked('dialog',true)
    api.setNativeHostBlocked('settings',false)
    await api.flushNativeSurfaceLayout()
  })
  assert.equal((await last()).blocked, true, 'One owner cannot release another modal')
  await page.evaluate(async () => {
    const api=window.surfacesFixture
    api.setNativeHostBlocked('dialog',false)
    window.releaseOverlay=api.registerNativeOverlay('palette',document.getElementById('palette'))
    await api.flushNativeSurfaceLayout()
  })
  assert.equal((await last()).blocked, false)
  assert.deepEqual((await last()).overlays, [{x:98,y:118,width:264,height:54}])
  await page.evaluate(() => {
    const api=window.surfacesFixture; api.defer(true)
    api.acquireNativeInput('palette').then(release => {window.releaseInput=release;window.acquired=true})
  })
  await page.waitForFunction(() => window.surfacesFixture.waiting()===1)
  assert.equal(await page.evaluate(() => !!window.acquired),false,'Drag waits for native input ownership ACK')
  assert.equal((await last()).inputBlocked,true)
  await page.evaluate(() => {window.surfacesFixture.defer(false);window.surfacesFixture.acknowledge()})
  await page.waitForFunction(() => window.acquired)
  await page.evaluate(async () => {
    document.getElementById('palette').style.left='300px'
    await window.releaseInput()
  })
  const history=await page.evaluate(() => window.surfacesFixture.calls.filter(call=>call.channel==='runtime:nativeSurfaces').map(call=>call.request))
  const releaseIndex=history.findLastIndex(state=>!state.inputBlocked)
  assert.equal(history[releaseIndex].overlays[0].x,298)
  assert.equal(history[releaseIndex-1].inputBlocked,true)
  assert.equal(history[releaseIndex-1].overlays[0].x,298,'Final mask precedes input release')
  await page.evaluate(async () => {
    const api=window.surfacesFixture
    const ended=await api.acquireNativeInput('ended-drag')
    window.otherOwner=await api.acquireNativeInput('still-active')
    document.getElementById('palette').style.left='400px'
    api.fail(true)
    try { await ended(); throw new Error('Expected interrupted release') }
    catch(error) { if (!String(error).includes('connection interrupted')) throw error }
    api.fail(false)
    // The original notice/closure can be gone. An ordinary later publication
    // must finish only the ended owner after committing its final geometry.
    await api.flushNativeSurfaceLayout()
  })
  assert.equal((await last()).inputBlocked,true,'Connection recovery cannot release another active gesture')
  await page.evaluate(async () => { await window.otherOwner() })
  assert.equal((await last()).inputBlocked,false,'A dismissed notice cannot leak the ended drag owner')
  await page.evaluate(async () => {
    const api=window.surfacesFixture, ended=await api.acquireNativeInput('only-drag')
    document.getElementById('palette').style.left='450px'; api.fail(true)
    try { await ended() } catch { /* Expected loss of final geometry ACK. */ }
    api.fail(false); await api.flushNativeSurfaceLayout()
  })
  await page.waitForFunction(() => window.surfacesFixture.calls.filter(call=>call.channel==='runtime:nativeSurfaces').at(-1).request.inputBlocked===false)
  assert.equal((await last()).overlays[0].x,448)
  await page.evaluate(async () => {
    const api=window.surfacesFixture
    window.releaseOverlay()
    for(let index=0;index<100;index++) {
      api.setNativeHostBlocked('settings',true)
      const release=api.registerNativeOverlay('temporary',document.getElementById('palette'))
      release(); api.setNativeHostBlocked('settings',false)
    }
    await api.flushNativeSurfaceLayout()
  })
  assert.deepEqual((await last()).overlays,[])
  assert.equal((await last()).blocked,false)
  assert.equal((await last()).inputBlocked,false)
  assert.deepEqual(errors,[])
  console.log('PASS native surface owners, 100-cycle cleanup, overlay geometry, drag ACK ordering and notice-independent interrupted-release recovery')
} finally { await browser.close(); await server.close(); await rm(cacheDir,{recursive:true,force:true}) }
