import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import plugin, { adaptTouchSource } from './index.mjs'
import layoutPlugin from '../layout/index.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test'), ts = require('typescript')
for (const name of ['WorkspaceTab.tsx', 'WorkspaceHost.tsx', 'CourseTabMoveOverlay.tsx']) {
  const file = join(runtime, 'upstream/src/renderer/src/features/workspace', name)
  const result = adaptTouchSource(await readFile(file, 'utf8'), file)
  assert.ok(result)
  assert.deepEqual(ts.transpileModule(result.code, { fileName: file, compilerOptions: { target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX }, reportDiagnostics: true }).diagnostics, [])
}
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-tab-touch-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, plugins: [layoutPlugin(), plugin(), react()], server: { host: '127.0.0.1', port: 0 }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch(), pages = []
const fresh = async (navigation = false) => {
  const page = await browser.newPage({ viewport: { width: navigation ? 834 : 1194, height: 900 }, hasTouch: true }), errors = []
  page.on('pageerror', error => { errors.push(error.message); console.error('FIXTURE ERROR', error.message) }); pages.push({ page, errors })
  await page.goto(server.resolvedUrls.local[0] + 'renderer/ipad/touch/workspace-fixture.html' + (navigation ? '?navigation' : ''))
  await page.waitForFunction(() => window.tabTouchFixture?.ready())
  await page.evaluate(() => window.tabTouchFixture.create())
  await page.locator('.workspace-course:not([hidden]) .dv-tab').nth(2).waitFor()
  return page
}
const state = page => page.evaluate(() => window.tabTouchFixture.state())
const panels = s => s.groups[s.selected].flatMap(group => group.panels)
const label = (page, name) => page.locator('.workspace-course:not([hidden]) .workspace-tab__title').filter({ hasText: name })
const center = async locator => { const box = await locator.boundingBox(); assert.ok(box); return { x: box.x + box.width / 2, y: box.y + box.height / 2 } }
const pointer = async (page, type, point, selector = null, id = 71, pointerType = 'touch') => page.evaluate(({ type, point, selector, id, pointerType }) => {
  const target = selector ? document.querySelector(selector) : document
  const event = new PointerEvent(type, { pointerId: id, pointerType, isPrimary: id === 71, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: point.x, clientY: point.y, bubbles: true, cancelable: true })
  target.dispatchEvent(event); return event.defaultPrevented
}, { type, point, selector, id, pointerType })
const down = async (page, name = 'one') => {
  const target = label(page, name), point = await center(target)
  await target.evaluate((element, point) => element.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 71, pointerType: 'touch', isPrimary: true, button: 0, buttons: 1, clientX: point.x, clientY: point.y, bubbles: true, cancelable: true })), point)
  return point
}
const released = page => page.waitForFunction(() => window.tabTouchFixture.state().kind === null && !document.querySelector('.ipad-tab-drag-preview'))
try {
  const page = await fresh(), start = await down(page)
  assert.equal(await pointer(page, 'pointermove', { x: start.x + 4, y: start.y + 3 }), false)
  assert.equal((await state(page)).kind, null, 'A 5 px tremor remains a tap')
  await pointer(page, 'pointerup', start)
  await label(page, 'one').tap()
  assert.equal(await label(page, 'one').evaluate(node => node.closest('.dv-tab').getAttribute('aria-selected')), 'true', 'Trusted WebKit tap selects without moving')
  const before = panels(await state(page)).map(panel => panel.id)
  const origin = await down(page), third = await center(label(page, 'three')), end = { x: third.x + 55, y: third.y }
  assert.equal(await pointer(page, 'pointermove', { x: origin.x + 8, y: origin.y }), true)
  assert.equal((await state(page)).kind, 'tab', 'First 8 px movement starts immediately without long-press delay')
  assert.ok(await page.locator('.ipad-tab-drag-preview').isVisible())
  assert.equal(await page.locator('.workspace-course:not([hidden]) .dv-tab').first().evaluate(node => getComputedStyle(node).touchAction), 'none')
  await pointer(page, 'pointermove', end)
  await page.locator('.course-tab-move-preview[data-tab-insertion]').waitFor()
  await pointer(page, 'pointerup', end); await released(page)
  assert.deepEqual(panels(await state(page)).map(panel => panel.id), [before[1], before[2], before[0]], 'Original layout owner reorders exactly once')

  const splitPage = await fresh(), splitOrigin = await down(splitPage)
  const content = await splitPage.locator('.workspace-course:not([hidden]) .dv-content-container').boundingBox()
  const splitPoint = { x: content.x + content.width - 14, y: content.y + content.height / 2 }
  await pointer(splitPage, 'pointermove', { x: splitOrigin.x, y: splitOrigin.y + 9 })
  await pointer(splitPage, 'pointermove', splitPoint)
  await splitPage.locator('.course-tab-move-preview').waitFor()
  await pointer(splitPage, 'pointerup', splitPoint); await released(splitPage)
  const split = await state(splitPage)
  assert.equal(split.groups[split.selected].length, 2)
  assert.deepEqual(panels(split).map(panel => panel.title).sort(), ['one', 'three', 'two'])
  assert.equal(split.groups[split.selected][1].panels[0].title, 'one', 'Right edge creates a right-hand pane')
  await down(splitPage)
  const otherHeader = await center(label(splitPage, 'two'))
  await pointer(splitPage, 'pointermove', { x: otherHeader.x - 10, y: otherHeader.y })
  await pointer(splitPage, 'pointerup', { x: otherHeader.x - 10, y: otherHeader.y }); await released(splitPage)
  const regrouped = await state(splitPage)
  assert.equal(regrouped.groups[regrouped.selected][0].panels.length, 3, 'Moving between groups keeps every live tab')
  assert.equal(regrouped.groups[regrouped.selected][1].panels.length, 0, 'Original empty-pane preservation remains intact')

  const coursePage = await fresh(), courseStart = await down(coursePage)
  const coursePoint = await center(coursePage.locator('.course-row').nth(1))
  await pointer(coursePage, 'pointermove', { x: courseStart.x, y: courseStart.y + 8 })
  await pointer(coursePage, 'pointermove', coursePoint)
  await coursePage.waitForFunction(() => window.tabTouchFixture.state().selected === window.tabTouchFixture.ids[1])
  await pointer(coursePage, 'pointerup', coursePoint); await released(coursePage)
  await coursePage.waitForFunction(() => { const f = window.tabTouchFixture, s = f.state(); return s.groups[f.ids[1]].flatMap(group => group.panels).length === 1 })
  const transferred = await state(coursePage), ids = await coursePage.evaluate(() => window.tabTouchFixture.ids)
  assert.equal(transferred.groups[ids[0]].flatMap(group => group.panels).length, 2)
  const moved = transferred.groups[ids[1]].flatMap(group => group.panels)[0]
  assert.equal(moved.title, 'one'); assert.equal(moved.descriptor.payload.courseId, ids[0], 'Resource stays bound to its original course')
  await coursePage.evaluate(() => window.tabTouchFixture.flush())
  await coursePage.waitForFunction(() => window.tabTouchFixture.layouts.size === 2)
  await coursePage.evaluate(() => window.tabTouchFixture.select(0))
  await down(coursePage, 'two')
  await pointer(coursePage, 'pointermove', coursePoint)
  await coursePage.waitForFunction(() => window.tabTouchFixture.state().selected === window.tabTouchFixture.ids[1])
  await coursePage.waitForFunction(() => document.querySelector('.workspace-course:not([hidden]) .dv-content-container')?.getBoundingClientRect().height > 200)
  const destination = await coursePage.locator('.workspace-course:not([hidden]) .dv-content-container').boundingBox()
  const below = { x: destination.x + destination.width / 2, y: destination.y + destination.height - 14 }
  await pointer(coursePage, 'pointermove', below)
  await pointer(coursePage, 'pointerup', below); await released(coursePage)
  await coursePage.waitForFunction(() => { const f = window.tabTouchFixture; return f.state().groups[f.ids[1]].length === 2 })
  const crossSplit = await state(coursePage)
  assert.equal(crossSplit.groups[ids[0]].flatMap(group => group.panels).length, 1)
  assert.equal(crossSplit.groups[ids[1]][1].panels[0].title, 'two', 'Hovered destination accepts a bottom-edge split')

  const cancelPage = await fresh(), cancelStart = await down(cancelPage)
  await pointer(cancelPage, 'pointermove', { x: cancelStart.x + 8, y: cancelStart.y })
  await pointer(cancelPage, 'pointermove', await center(cancelPage.locator('.course-row').nth(1)))
  await cancelPage.waitForFunction(() => window.tabTouchFixture.state().selected === window.tabTouchFixture.ids[1])
  await pointer(cancelPage, 'pointercancel', cancelStart); await released(cancelPage)
  assert.equal((await state(cancelPage)).selected, ids[0])
  assert.equal(panels(await state(cancelPage)).length, 3)
  const multi = await down(cancelPage)
  await pointer(cancelPage, 'pointermove', { x: multi.x + 8, y: multi.y })
  await pointer(cancelPage, 'pointerdown', multi, null, 72); await released(cancelPage)
  assert.equal(panels(await state(cancelPage)).length, 3)
  for (const cancellation of ['Escape', 'resize', 'outside']) {
    const point = await down(cancelPage)
    await pointer(cancelPage, 'pointermove', { x: point.x + 8, y: point.y })
    if (cancellation === 'Escape') await cancelPage.keyboard.press('Escape')
    if (cancellation === 'resize') await cancelPage.setViewportSize({ width: 1100, height: 900 })
    if (cancellation === 'outside') await pointer(cancelPage, 'pointerup', { x: -10, y: -10 })
    await released(cancelPage)
    assert.deepEqual(panels(await state(cancelPage)).map(panel => panel.title), ['one', 'two', 'three'], `${cancellation} never commits an accidental move`)
  }

  const ackPage = await fresh(); await ackPage.evaluate(() => window.tabTouchFixture.defer(true))
  await down(ackPage); const ackEnd = await center(label(ackPage, 'three')), ackPoint = { x: ackEnd.x + 55, y: ackEnd.y }
  await pointer(ackPage, 'pointermove', ackPoint)
  await ackPage.waitForFunction(() => window.tabTouchFixture.nativePending())
  await pointer(ackPage, 'pointerup', ackPoint)
  assert.deepEqual(panels(await state(ackPage)).map(panel => panel.title), ['one', 'two', 'three'])
  await ackPage.evaluate(() => window.tabTouchFixture.ack()); await released(ackPage)
  assert.deepEqual(panels(await state(ackPage)).map(panel => panel.title), ['two', 'three', 'one'])
  await ackPage.waitForFunction(() => window.tabTouchFixture.calls.filter(item => item.channel === 'runtime:nativeSurfaces').at(-1)?.request.inputBlocked === false)
  const cancelAckPage = await fresh(); await cancelAckPage.evaluate(() => window.tabTouchFixture.defer(true))
  await down(cancelAckPage)
  const cancelAckEnd = await center(label(cancelAckPage, 'three'))
  await pointer(cancelAckPage, 'pointermove', { x: cancelAckEnd.x + 55, y: cancelAckEnd.y })
  await cancelAckPage.waitForFunction(() => window.tabTouchFixture.nativePending())
  await pointer(cancelAckPage, 'pointercancel', cancelAckEnd); await released(cancelAckPage)
  await cancelAckPage.evaluate(() => window.tabTouchFixture.ack())
  await cancelAckPage.waitForFunction(() => window.tabTouchFixture.calls.filter(item => item.channel === 'runtime:nativeSurfaces').at(-1)?.request.inputBlocked === false)
  assert.deepEqual(panels(await state(cancelAckPage)).map(panel => panel.title), ['one', 'two', 'three'], 'Late native ACK after cancellation only releases its barrier')

  const body = await center(cancelPage.locator('.workspace-course:not([hidden]) .document-body').first())
  assert.equal(await pointer(cancelPage, 'pointerdown', body, '.workspace-course:not([hidden]) .document-body'), false)
  assert.equal(await pointer(cancelPage, 'pointermove', { x: body.x, y: body.y + 80 }), false)
  await pointer(cancelPage, 'pointerup', body)
  assert.equal((await state(cancelPage)).kind, null)
  assert.equal(await cancelPage.locator('.document-body').first().evaluate(node => getComputedStyle(node).touchAction), 'pan-y')
  const tabSelector = '.workspace-course:not([hidden]) .workspace-tab__title'
  for (const kind of ['pen', 'mouse']) {
    await pointer(cancelPage, 'pointerdown', cancelStart, tabSelector, 71, kind)
    assert.equal(await pointer(cancelPage, 'pointermove', { x: cancelStart.x + 40, y: cancelStart.y }, null, 71, kind), false)
    await pointer(cancelPage, 'pointerup', cancelStart, null, 71, kind)
    assert.equal((await state(cancelPage)).kind, null)
  }
  await cancelPage.getByRole('button', { name: 'three 탭 닫기', exact: true }).tap()
  await cancelPage.waitForFunction(() => { const f = window.tabTouchFixture; return f.apis.get(f.ids[0]).panels.length === 2 })
  const navPage = await fresh(true), icon = navPage.locator('.global-navigation').getByRole('button', { name: '과목', exact: true })
  assert.equal(await navPage.locator('.fixture-navigation').getAttribute('data-ipad-left'), 'closed')
  await icon.evaluate(element => {
    const dataTransfer = new DataTransfer(); dataTransfer.setData('application/x-bandal-tab', '{}')
    element.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer }))
  })
  assert.equal(await navPage.locator('.fixture-navigation').getAttribute('data-ipad-left'), 'closed', 'External payload without a live tab session cannot open the sidebar')
  await down(navPage)
  const iconPoint = await center(icon)
  await pointer(navPage, 'pointermove', iconPoint)
  await navPage.waitForFunction(() => document.querySelector('.fixture-navigation')?.getAttribute('data-ipad-left') === 'overlay')
  assert.equal((await state(navPage)).selected, ids[0], 'Course icon opens destinations without changing the selected course')
  assert.equal(await navPage.locator('.app-workspace').evaluate(element => element.inert), true, 'Compact main sidebar preserves the actual inert workspace policy')
  const revision = await navPage.evaluate(() => window.tabTouchFixture.panelRevision())
  await pointer(navPage, 'pointermove', iconPoint)
  assert.equal(await navPage.evaluate(() => window.tabTouchFixture.panelRevision()), revision, 'Repeated hover does not churn the sidebar coordination state')
  const navDestination = await center(navPage.locator('.course-row').nth(1))
  await pointer(navPage, 'pointermove', navDestination)
  await pointer(navPage, 'pointerup', navDestination); await released(navPage)
  await navPage.waitForFunction(() => { const f = window.tabTouchFixture; return f.state().groups[f.ids[1]].flatMap(group => group.panels).length === 1 })
  assert.equal((await state(navPage)).groups[ids[0]].flatMap(group => group.panels).length, 2, 'Window-owned touch drag survives source becoming inert and moves the tab once')
  for (const entry of pages) assert.deepEqual(entry.errors, [])
  console.log('PASS WebKit immediate 8 px tab drag, real Dockview reorder/split/regroup/course row transfer/cross-course bottom split with resource identity and persistence, compact actual navigation hover-open/inert-source drop, cancel/hover restore/multitouch/Escape/resize/outside, native ACK/late-cancel barriers, tap/close/scroll/Pencil/mouse exclusions')
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
