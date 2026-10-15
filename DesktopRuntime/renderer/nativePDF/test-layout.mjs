import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-native-layout-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, plugins: [react()],
  server: { host: '127.0.0.1', port: 0 }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1024, height: 900 } }), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(server.resolvedUrls.local[0] + 'renderer/nativePDF/layout-fixture.html')
  const latest = () => page.evaluate(() => window.nativeLayoutTrace.calls.findLast(call => call.channel === 'pdfNative:layout')?.payload)
  const visible = async value => page.waitForFunction(value => window.nativeLayoutTrace.active &&
    (() => { const state = window.nativeLayoutTrace.calls.findLast(call => call.channel === 'pdfNative:layout')?.payload;
      return !!state && state.visible === true && !state.occluded === value })(), value)
  await page.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'runtime:nativeSurfaces'))
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.active), false, 'Paper waits for the shared native-surface geometry ACK')
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:layout' && call.payload.visible)), false)
  await page.evaluate(() => window.nativeLayoutTrace.acknowledgeInitialSurface())
  await page.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:snapshot'))
  const beforeReady = await page.evaluate(() => ({ active: window.nativeLayoutTrace.active, calls: window.nativeLayoutTrace.calls }))
  assert.equal(beforeReady.active, false, 'Paper stays unavailable until its initial input snapshot is acknowledged')
  assert.equal(beforeReady.calls.some(call => call.channel === 'pdfNative:layout' && call.payload.visible), false)
  assert.equal(beforeReady.calls.find(call => call.channel === 'pdfNative:snapshot').payload.tool.name, 'pen')
  await page.evaluate(() => window.nativeLayoutTrace.changeInitialTool())
  await page.evaluate(() => window.nativeLayoutTrace.acknowledgeInitialSnapshot())
  await visible(true)
  const initialCalls = await page.evaluate(() => window.nativeLayoutTrace.calls)
  const shownAt = initialCalls.findIndex(call => call.channel === 'pdfNative:layout' && call.payload.visible)
  assert.equal(initialCalls.slice(0, shownAt).findLast(call => call.channel === 'pdfNative:snapshot').payload.tool.name, 'highlighter',
    'A tool changed while readiness waits must be acknowledged before exposing paper')
  const layoutCount = () => page.evaluate(() => window.nativeLayoutTrace.calls.filter(call => call.channel === 'pdfNative:layout').length)
  const settleLayout = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  const mutateUnrelatedText = count => page.evaluate(async count => {
    const label = document.createElement('span'), text = document.createTextNode('Status')
    label.append(text); document.body.append(label)
    for (let index = 0; index < count; index++) {
      text.data = `Unrelated status ${index}`
      await new Promise(requestAnimationFrame)
    }
    label.remove()
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
  }, count)
  await settleLayout()
  const initialLayoutCount = await layoutCount()
  await mutateUnrelatedText(100)
  assert.equal(await layoutCount(), initialLayoutCount, '100 body text mutations across frames must not republish unchanged native geometry')

  await page.evaluate(() => {
    window.nativeLayoutTrace.deferLayouts(true)
    document.querySelector('.pdf-scroller').style.width = '701px'
  })
  await page.waitForFunction(() => window.nativeLayoutTrace.waitingLayouts() === 1)
  await mutateUnrelatedText(12)
  assert.equal(await layoutCount(), initialLayoutCount + 1, 'Identical updates share the outstanding layout ACK')
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.waitingLayouts()), 1)
  await page.locator('.pdf-scroller').evaluate(node => node.style.width = '702px')
  await page.waitForFunction(() => window.nativeLayoutTrace.waitingLayouts() === 2)
  await page.evaluate(async () => (await import('/renderer/ipad/nativeSurfaces.ts')).setNativeHostBlocked('fixture-layout-block', true))
  await page.waitForFunction(() => window.nativeLayoutTrace.waitingLayouts() === 3)
  const pendingLayouts = await page.evaluate(() => window.nativeLayoutTrace.calls.filter(call => call.channel === 'pdfNative:layout').slice(-3).map(call => call.payload))
  assert.deepEqual(pendingLayouts.map(layout => [layout.rect.width, layout.occluded]), [[701, false], [702, false], [702, true]],
    'Distinct geometry and input occlusion publish even while an earlier ACK is delayed')
  assert.ok(pendingLayouts.every((layout, index) => index === 0 || layout.revision > pendingLayouts[index - 1].revision))
  await page.evaluate(() => window.nativeLayoutTrace.acknowledgeLayout(2))
  await page.waitForFunction(() => window.nativeLayoutTrace.appliedLayout.occluded === true)
  await page.evaluate(() => window.nativeLayoutTrace.acknowledgeLayouts())
  await settleLayout()
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.appliedLayout.revision), pendingLayouts[2].revision,
    'Late old geometry ACKs cannot replace the newest revision')
  await page.evaluate(async () => {
    window.nativeLayoutTrace.deferLayouts(false)
    ;(await import('/renderer/ipad/nativeSurfaces.ts')).setNativeHostBlocked('fixture-layout-block', false)
    document.querySelector('.pdf-scroller').style.width = '700px'
  })
  await page.waitForFunction(() => window.nativeLayoutTrace.appliedLayout.rect.width === 700 && !window.nativeLayoutTrace.appliedLayout.occluded)

  await page.evaluate(() => {
    window.nativeLayoutTrace.deferLayouts(true)
    document.querySelector('.pdf-scroller').style.left = '61px'
  })
  await page.waitForFunction(() => window.nativeLayoutTrace.waitingLayouts() === 1)
  const failedLayoutCount = await layoutCount()
  await page.evaluate(() => window.nativeLayoutTrace.rejectLayout(0))
  await page.waitForFunction(() => window.nativeLayoutTrace.reportedErrors.length === 1)
  await page.evaluate(() => {
    window.nativeLayoutTrace.deferLayouts(false)
    window.dispatchEvent(new Event('bandal-native-pdf-editor-layout'))
  })
  await page.waitForFunction(() => window.nativeLayoutTrace.appliedLayout.rect.x === 61)
  assert.equal(await layoutCount(), failedLayoutCount + 1, 'The latest failed layout retries unchanged geometry on an explicit refresh')
  await mutateUnrelatedText(3)
  assert.equal(await layoutCount(), failedLayoutCount + 1, 'The successfully retried layout is cached again')

  await page.evaluate(() => {
    window.nativeLayoutTrace.deferLayouts(true)
    document.querySelector('.pdf-scroller').style.left = '62px'
  })
  await page.waitForFunction(() => window.nativeLayoutTrace.waitingLayouts() === 1)
  await page.locator('.pdf-scroller').evaluate(node => node.style.left = '63px')
  await page.waitForFunction(() => window.nativeLayoutTrace.waitingLayouts() === 2)
  const newestLayoutCount = await layoutCount()
  await page.evaluate(() => window.nativeLayoutTrace.acknowledgeLayout(1))
  await page.waitForFunction(() => window.nativeLayoutTrace.appliedLayout.rect.x === 63)
  await page.evaluate(() => window.nativeLayoutTrace.rejectLayout(0))
  await page.waitForFunction(() => window.nativeLayoutTrace.reportedErrors.length === 2)
  await mutateUnrelatedText(3)
  assert.equal(await layoutCount(), newestLayoutCount, 'A stale failure cannot clear the newer acknowledged layout cache')
  await page.evaluate(() => {
    window.nativeLayoutTrace.deferLayouts(false)
    document.querySelector('.pdf-scroller').style.left = '60px'
  })
  await page.waitForFunction(() => window.nativeLayoutTrace.appliedLayout.rect.x === 60)
  assert.deepEqual(await page.evaluate(() => window.nativeLayoutTrace.reportedErrors), ['Fixture layout ACK failed', 'Fixture layout ACK failed'])

  await page.getByRole('button', { name: 'Toggle paper visibility', exact: true }).click()
  await page.waitForFunction(() => window.nativeLayoutTrace.appliedLayout.visible === false)
  await page.getByRole('button', { name: 'Toggle paper visibility', exact: true }).click()
  await visible(true)
  const assertSharedHole = async locator => {
    const box = await locator.boundingBox()
    assert.ok(box)
    await page.waitForFunction(box => {
      const state = window.nativeLayoutTrace.appliedSurface
      return state?.overlays.some(hole => Math.abs(hole.x-(box.x-2))<1 &&
        Math.abs(hole.y-(box.y-2))<1 && Math.abs(hole.width-(box.width+4))<1 && Math.abs(hole.height-(box.height+4))<1)
    }, box)
    assert.deepEqual((await latest()).holes, [], 'Shared HTML overlays must never leave a second local PDF aperture')
  }
  await page.getByRole('button', { name: '필기 스타일', exact: true }).click()
  const palette = page.getByRole('dialog', { name: '필기 스타일', exact: true })
  await palette.waitFor(); await assertSharedHole(palette)
  assert.equal((await latest()).visible, true, 'The original portal palette keeps the native body on screen')
  await palette.locator('button[data-color="red"]').click()
  assert.equal(await palette.locator('button[data-color="red"]').getAttribute('aria-pressed'), 'true')
  assert.equal(await palette.count(), 1, 'A palette action stays open instead of being reported as paper contact')
  // Moving a shared overlay does not change local PDF geometry. Its release
  // ACK must clear the old aperture without a redundant corrective PDF layout.
  const beforeDragLayoutCount = await layoutCount()
  const dragResult = await page.evaluate(async () => {
    const trace = window.nativeLayoutTrace
    const api = await import('/renderer/ipad/nativeSurfaces.ts')
    const palette = document.querySelector('.pdf-tool-popover'), before = palette.getBoundingClientRect()
    const oldPoint = { x: before.left + before.width/2, y: before.top + before.height/2 }
    const originalStyle = palette.getAttribute('style')
    trace.deferLayouts(true)
    const release = await api.acquireNativeInput('native-layout-fixture-drag')
    palette.style.left = '650px'; palette.style.top = '550px'
    await release()
    const surface = trace.appliedSurface, layout = trace.appliedLayout
    const inRect = (point, rect) => point.x >= rect.x && point.x <= rect.x+rect.width && point.y >= rect.y && point.y <= rect.y+rect.height
    const localPoint = { x: oldPoint.x-layout.rect.x, y: oldPoint.y-layout.rect.y }
    const result = {
      inputBlocked: surface.inputBlocked,
      oldPointBlocked: surface.overlays.some(rect => inRect(oldPoint, rect)) || layout.holes.some(rect => inRect(localPoint, rect)),
      localHoles: layout.holes,
      finalSharedHole: surface.overlays.some(rect => Math.abs(rect.x-648)<1 && Math.abs(rect.y-548)<1),
      layoutRevision: layout.revision
    }
    window.nativeDragOriginalStyle = originalStyle
    return result
  })
  await settleLayout()
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.waitingLayouts()), 0)
  assert.equal(await layoutCount(), beforeDragLayoutCount, 'Shared palette movement does not republish identical local PDF geometry')
  assert.equal(dragResult.inputBlocked, false, 'Successful final mask ACK releases native input')
  assert.equal(dragResult.finalSharedHole, true, 'The acknowledged shared mask owns the final palette position')
  assert.deepEqual(dragResult.localHoles, [], 'The old PDF layout cannot retain a palette hole while its next reply is delayed')
  assert.equal(dragResult.oldPointBlocked, false, 'Paper at the former palette position accepts input as soon as the global release is acknowledged')
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.appliedLayout.revision), dragResult.layoutRevision, 'The regression checks the old applied local layout, not a later corrective one')
  await page.evaluate(async () => {
    window.nativeLayoutTrace.deferLayouts(false); window.nativeLayoutTrace.acknowledgeLayouts()
    const palette = document.querySelector('.pdf-tool-popover')
    if (window.nativeDragOriginalStyle === null) palette.removeAttribute('style')
    else palette.setAttribute('style', window.nativeDragOriginalStyle)
    await (await import('/renderer/ipad/nativeSurfaces.ts')).flushNativeSurfaceLayout()
  })
  await palette.evaluate(node => node.setAttribute('aria-modal', 'true')); await visible(false)
  await palette.evaluate(node => node.removeAttribute('aria-modal')); await visible(true)
  const pointerCount = await page.evaluate(() => window.nativeLayoutTrace.pointerEvents)
  await page.evaluate(() => window.nativeLayoutTrace.contact())
  await palette.waitFor({ state: 'detached' })
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.pointerEvents), pointerCount, 'Native paper contact dismisses using Escape, never a fabricated pointer')
  assert.equal((await latest()).visible, true)
  await page.getByRole('button', { name: 'Open highlight', exact: true }).click()
  const highlight = page.getByRole('dialog', { name: '하이라이트 편집', exact: true })
  await highlight.waitFor(); await assertSharedHole(highlight)
  await highlight.locator('textarea').fill('A comment can be edited above the native PDF')
  assert.equal((await latest()).visible, true, 'The original annotation editor is nonmodal as well')
  await page.getByRole('button', { name: 'Open modal', exact: true }).click(); await visible(false)
  const modal = page.getByRole('dialog', { name: 'Settings fixture', exact: true, includeHidden: true })
  await modal.evaluate(node => node.hidden = true); await visible(true)
  await modal.evaluate(node => node.hidden = false); await visible(false)
  await page.getByRole('button', { name: 'Close modal', exact: true }).click(); await visible(true)
  await page.getByRole('button', { name: 'Open settings overlay', exact: true }).click(); await visible(false)
  assert.equal((await latest()).visible, true, 'Actual AppShell settings markup occludes without suspending the PDF')
  await page.getByRole('button', { name: 'Close settings overlay', exact: true }).click(); await visible(true)
  await page.evaluate(() => {
    const editor = document.createElement('div')
    editor.className = 'ink-layer__textbox-editor'; editor.textContent = 'Page-aligned editor'
    editor.style.cssText = 'position:absolute;left:120px;top:320px;width:180px;height:60px'
    document.querySelector('[data-pdf-page="1"]').append(editor)
  })
  await page.waitForFunction(() => {
    const trace = window.nativeLayoutTrace, layout = trace.appliedLayout
    return trace.calls.some(call => call.channel === 'pdfNative:pageGeometry') && layout.holes.length === 1
  })
  assert.equal(await page.evaluate(() => {
    const editor = document.querySelector('.ink-layer__textbox-editor').getBoundingClientRect()
    const layout = window.nativeLayoutTrace.appliedLayout, hole = layout.holes[0]
    return Math.abs(hole.x-(editor.x-layout.rect.x-2))<1 && Math.abs(hole.y-(editor.y-layout.rect.y-2))<1
  }), true, 'Page-aligned text editors retain their document-local aperture after native page geometry resolves')
  await settleLayout()
  const editorLayoutCount = await layoutCount()
  await mutateUnrelatedText(5)
  assert.equal(await layoutCount(), editorLayoutCount, 'Editor preflight and final layout reuse the same unchanged geometry ACK')
  const geometryCount = await page.evaluate(() => window.nativeLayoutTrace.calls.filter(call => call.channel === 'pdfNative:pageGeometry').length)
  await page.evaluate(() => {
    window.nativeLayoutTrace.deferLayouts(true)
    document.querySelector('.pdf-scroller').style.width = '701px'
  })
  await page.waitForFunction(() => window.nativeLayoutTrace.waitingLayouts() === 1)
  await mutateUnrelatedText(5)
  assert.equal(await layoutCount(), editorLayoutCount + 1, 'Repeated editor preflights share the pending layout promise')
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.calls.filter(call => call.channel === 'pdfNative:pageGeometry').length), geometryCount,
    'Editor page geometry is not queried before the required native layout ACK')
  await page.evaluate(() => window.nativeLayoutTrace.acknowledgeLayout(0))
  await page.waitForFunction(count => window.nativeLayoutTrace.calls.filter(call => call.channel === 'pdfNative:pageGeometry').length > count, geometryCount)
  await settleLayout()
  assert.equal(await page.evaluate(() => window.nativeLayoutTrace.waitingLayouts()), 0, 'The final editor layout reuses its acknowledged preflight when holes are unchanged')
  const previousHoleX = await page.evaluate(() => window.nativeLayoutTrace.appliedLayout.holes[0].x)
  await page.evaluate(() => {
    window.nativeLayoutTrace.deferLayouts(false)
    document.querySelector('.ink-layer__textbox-editor').style.left = '140px'
  })
  await page.waitForFunction(previous => window.nativeLayoutTrace.appliedLayout.holes[0].x !== previous, previousHoleX)
  assert.equal(await layoutCount(), editorLayoutCount + 2, 'A changed page-local editor aperture is always published')
  await page.locator('.ink-layer__textbox-editor').evaluate(node => node.remove())
  await page.waitForFunction(() => window.nativeLayoutTrace.appliedLayout.holes.length === 0)
  const revisions = await page.evaluate(() => window.nativeLayoutTrace.calls.filter(call => call.channel === 'pdfNative:layout').map(call => call.payload.revision))
  assert.ok(revisions.every((revision, index) => index === 0 || revision > revisions[index - 1]), 'Every transmitted layout retains monotonic revisions across visibility changes and retries')
  assert.deepEqual(errors, [])
  const failedPage = await browser.newPage()
  await failedPage.goto(server.resolvedUrls.local[0] + 'renderer/nativePDF/layout-fixture.html?failSurface=1')
  await failedPage.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'runtime:nativeSurfaces'))
  await failedPage.waitForFunction(() => window.nativeLayoutTrace.reportedErrors.includes('Fixture native surface ACK failed'))
  assert.equal(await failedPage.evaluate(() => window.nativeLayoutTrace.active), false)
  assert.equal(await failedPage.evaluate(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:layout' && call.payload.visible)), false)
  assert.deepEqual(await failedPage.evaluate(() => window.nativeLayoutTrace.reportedErrors), ['Fixture native surface ACK failed'],
    'The actual shared-bridge failure remains visible rather than being treated as successful paper readiness')
  await failedPage.close()
  const delayedPage = await browser.newPage()
  await delayedPage.goto(server.resolvedUrls.local[0] + 'renderer/nativePDF/layout-fixture.html?deferDrawings=1')
  await delayedPage.waitForFunction(() => window.nativeLayoutTrace.waitingDrawings() === 1 && window.nativeLayoutTrace.calls.some(call => call.channel === 'runtime:nativeSurfaces'))
  await delayedPage.evaluate(() => window.nativeLayoutTrace.acknowledgeInitialSurface())
  await delayedPage.evaluate(async () => {
    window.nativeLayoutTrace.changeInitialTool()
    for (let index = 0; index < 100; index++) await new Promise(requestAnimationFrame)
  })
  assert.equal(await delayedPage.evaluate(() => window.nativeLayoutTrace.active), false)
  assert.equal(await delayedPage.evaluate(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:snapshot' || call.channel === 'pdfNative:layout' && call.payload.visible)), false,
    'Pending repository drawings cannot expose a loading native surface or poll incomplete snapshots')
  assert.equal(await delayedPage.evaluate(() => window.nativeLayoutTrace.drawingLoadAttempts), 1, 'Readiness never retries the original repository read')
  await delayedPage.evaluate(() => window.nativeLayoutTrace.acknowledgeDrawings())
  await delayedPage.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:snapshot'))
  const pendingSnapshot = await delayedPage.evaluate(() => window.nativeLayoutTrace.calls.find(call => call.channel === 'pdfNative:snapshot').payload)
  assert.equal(pendingSnapshot.loading, false)
  assert.equal(pendingSnapshot.tool.name, 'highlighter', 'A tool chosen during repository loading is included in the first snapshot')
  assert.equal(await delayedPage.evaluate(() => window.nativeLayoutTrace.active), false, 'Completed drawings still wait for the final input snapshot ACK')
  await delayedPage.evaluate(() => { window.nativeLayoutTrace.changeInitialTool('pen'); window.nativeLayoutTrace.acknowledgeInitialSnapshot() })
  await delayedPage.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:layout' && call.payload.visible))
  const delayedCalls = await delayedPage.evaluate(() => window.nativeLayoutTrace.calls)
  const delayedVisible = delayedCalls.findIndex(call => call.channel === 'pdfNative:layout' && call.payload.visible)
  const finalInput = delayedCalls.slice(0, delayedVisible).findLast(call => call.channel === 'pdfNative:snapshot').payload
  assert.equal(finalInput.loading, false); assert.equal(finalInput.tool.name, 'pen', 'The latest tool ACK still precedes first visibility after a delayed load')
  await delayedPage.close()

  const retiredPage = await browser.newPage()
  await retiredPage.goto(server.resolvedUrls.local[0] + 'renderer/nativePDF/layout-fixture.html?deferDrawings=1')
  await retiredPage.waitForFunction(() => window.nativeLayoutTrace.waitingDrawings() === 1 && window.nativeLayoutTrace.calls.some(call => call.channel === 'runtime:nativeSurfaces'))
  await retiredPage.evaluate(() => window.nativeLayoutTrace.acknowledgeInitialSurface())
  await retiredPage.evaluate(() => window.nativeLayoutTrace.hideFixture())
  await retiredPage.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:close'))
  const retiredIdentity = await retiredPage.evaluate(() => window.nativeLayoutTrace.calls.find(call => call.channel === 'pdfNative:open').payload.surfaceId)
  await retiredPage.evaluate(() => window.nativeLayoutTrace.showFixture())
  await retiredPage.waitForFunction(() => window.nativeLayoutTrace.waitingDrawings() === 2 && window.nativeLayoutTrace.calls.filter(call => call.channel === 'pdfNative:open').length === 2)
  await retiredPage.evaluate(async () => { window.nativeLayoutTrace.acknowledgeDrawings(); await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))) })
  assert.equal(await retiredPage.evaluate(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:snapshot')), false,
    'A late drawing response from an unmounted generation cannot unblock its replacement')
  await retiredPage.evaluate(() => window.nativeLayoutTrace.acknowledgeDrawings())
  await retiredPage.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:snapshot'))
  await retiredPage.evaluate(() => window.nativeLayoutTrace.acknowledgeInitialSnapshot())
  await retiredPage.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:layout' && call.payload.visible))
  assert.equal(await retiredPage.evaluate(retired => window.nativeLayoutTrace.calls.some(call => call.payload.surfaceId === retired &&
    (call.channel === 'pdfNative:snapshot' || call.channel === 'pdfNative:layout' && call.payload.visible)), retiredIdentity), false,
    'An unmounted loading session cancels its wait and retires without exposing paper')
  assert.deepEqual(await retiredPage.evaluate(() => window.nativeLayoutTrace.reportedErrors), [])
  await retiredPage.close()

  const readErrorPage = await browser.newPage()
  await readErrorPage.goto(server.resolvedUrls.local[0] + 'renderer/nativePDF/layout-fixture.html?deferDrawings=1&failDrawings=1')
  await readErrorPage.waitForFunction(() => window.nativeLayoutTrace.waitingDrawings() === 1 && window.nativeLayoutTrace.calls.some(call => call.channel === 'runtime:nativeSurfaces'))
  await readErrorPage.evaluate(() => { window.nativeLayoutTrace.acknowledgeInitialSurface(); window.nativeLayoutTrace.acknowledgeDrawings() })
  await readErrorPage.waitForFunction(() => window.nativeLayoutTrace.calls.some(call => call.channel === 'pdfNative:snapshot'))
  await readErrorPage.evaluate(() => window.nativeLayoutTrace.acknowledgeInitialSnapshot())
  await readErrorPage.waitForFunction(() => window.nativeLayoutTrace.active)
  assert.equal(await readErrorPage.evaluate(() => window.nativeLayoutTrace.drawingLoadAttempts), 1, 'A failed initial read settles normally without an automatic retry or infinite loading wait')
  await readErrorPage.close()
  console.log('PASS: semantic layout deduplication, shared/delayed ACKs, latest failure retry, stale failure isolation, geometry/occlusion/aperture changes, shared palette drag release, readiness and native lifetime')
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
