import './test-policy.mjs'
import './sidebarSwipe.test.mjs'
import assert from 'node:assert/strict'
import { readFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import plugin, { adaptLayoutSource } from './index.mjs'
import uiPlugin from '../ui/index.mjs'
import { testSettingsFocus } from './settingsFocus.test.mjs'
import { testShell } from './test-shell.mjs'
import { testSidebarSwipe } from './sidebarSwipe.integration.test.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test'), ts = require('typescript')
for (const suffix of ['app/AppShell.tsx', 'app/GlobalNavigation.tsx', 'app/shortcuts.ts', 'features/ai/AiShortcuts.tsx', 'stores/uiStore.ts', 'features/settings/SettingsApp.tsx', 'features/board/BoardPanel.tsx', 'features/board/TaskEditorPopover.tsx', 'features/assistantPanel/TabAssistantPanel.tsx', 'features/workspace/WorkspaceHost.tsx', 'features/workspace/OpenTabsMenu.tsx', 'features/workspace/NewTabMenu.tsx', 'lib/useViewportBounds.ts', 'features/workspace/adaptiveTabs.ts', 'features/materials/MaterialTree.tsx', 'features/materials/MaterialsContextMenu.tsx']) {
  const path = join(runtime, 'upstream/src/renderer/src', suffix)
  const transformed = adaptLayoutSource(await readFile(path, 'utf8'), path)
  assert.ok(transformed, `Production adapter must cover ${suffix}`)
  assert.deepEqual(ts.transpileModule(transformed.code, { fileName: path, compilerOptions: { target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX }, reportDiagnostics: true }).diagnostics, [], `Adapter JSX parses: ${suffix}`)
}
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-ipad-layout-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, define: { __APP_VERSION__: '"fixture"' }, plugins: [plugin(), uiPlugin(), react()], server: { host: '127.0.0.1', port: 0, watch: null }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  await testSidebarSwipe(browser, server.resolvedUrls.local[0] + 'renderer/ipad/layout/fixture.html')
  await testShell(browser, server.resolvedUrls.local[0] + 'renderer/ipad/layout/fixture.html')
  await testSettingsFocus(browser, server.resolvedUrls.local[0] + 'renderer/ipad/layout/fixture.html')
  const page = await browser.newPage({ viewport: { width: 1194, height: 834 }, hasTouch: true }), errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(server.resolvedUrls.local[0] + 'renderer/ipad/layout/fixture.html')
  await page.waitForFunction(() => window.ipadLayoutFixture?.snapshot()?.panels.length === 2)
  const before = await page.evaluate(() => window.ipadLayoutFixture.snapshot())
  assert.equal(await page.locator('.tab-assistant:visible').count(), 0, 'Desktop saved assistant open=true does not reopen an iPad auxiliary')
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-side'), 'none')
  await page.getByRole('button', { name: '내 공간 열기', exact: true }).tap()
  await page.getByRole('button', { name: '패널 고정 해제', exact: true }).waitFor()
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-pinned'), 'left')
  assert.ok((await page.locator('.app-workspace').boundingBox()).width >= 560)
  await page.setViewportSize({ width: 834, height: 1194 })
  await page.waitForFunction(() => document.querySelector('.ipad-shell').dataset.ipadPinned === 'none')
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-left'), 'overlay')
  await page.getByRole('button', { name: '내 공간 닫기', exact: true }).last().tap()
  await page.waitForFunction(() => window.ipadLayoutFixture.snapshot().maximized)
  assert.equal(await page.evaluate(() => window.ipadLayoutFixture.snapshot().saved.grid.maximizedNode), undefined, 'Automatic maximization is not persisted')
  await page.locator('textarea[aria-label="second"]').fill('unsaved preserved')
  await page.evaluate(() => window.ipadLayoutFixture.select('first'))
  await page.locator('textarea[aria-label="first"]').fill('other retained')
  await page.setViewportSize({ width: 1194, height: 834 })
  await page.waitForFunction(() => !window.ipadLayoutFixture.snapshot().maximized).catch(async error => {
    console.error('Split restoration diagnostics', JSON.stringify(await page.evaluate(() => ({ snapshot: window.ipadLayoutFixture.snapshot(), workspace: document.querySelector('.workspace-course').getBoundingClientRect().toJSON(), shell: document.querySelector('.ipad-shell').dataset }))))
    throw error
  })
  const after = await page.evaluate(() => window.ipadLayoutFixture.snapshot())
  assert.deepEqual(after.groups, before.groups, 'Responsive maximization retains group topology and panel IDs')
  assert.ok(after.requiredWidth < 1194, 'Switching the maximized group does not corrupt split proportions: ' + JSON.stringify({ before: before.saved.grid, after: after.saved.grid }))
  for (const pane of await page.locator('.fixture-pane:visible').all()) assert.ok((await pane.boundingBox()).width >= 560, 'Each restored document pane keeps560px')
  assert.equal(await page.locator('textarea[aria-label="second"]').inputValue(), 'unsaved preserved')
  assert.equal(await page.locator('textarea[aria-label="first"]').inputValue(), 'other retained')
  await page.getByRole('button', { name: '도움 열기 first', exact: true }).tap()
  await page.getByRole('button', { name: 'AI 고정 해제', exact: true }).tap()
  await page.locator('.tab-assistant:visible .chat-composer__input').waitFor()
  await page.waitForFunction(() => !!document.activeElement?.closest('.tab-assistant[aria-modal="true"]'))
  await page.locator('.tab-assistant:visible .chat-composer__input').focus()
  for (const key of [...Array(16).fill('Tab'), ...Array(16).fill('Shift+Tab')]) {
    await page.keyboard.press(key)
    assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.tab-assistant[aria-modal="true"]')), `${key} stays inside the modal AI drawer`)
    assert.equal(await page.evaluate(() => window.ipadLayoutFixture.snapshot().active), 'first', 'Modal keyboard traversal never activates the other document')
  }
  await page.keyboard.press('Escape')
  await page.locator('.tab-assistant:visible').waitFor({ state: 'hidden' })
  await page.waitForFunction(() => document.activeElement?.getAttribute('data-ipad-assistant-trigger') === 'first')
  await page.setViewportSize({ width: 1024, height: 834 })
  await page.waitForFunction(() => window.ipadLayoutFixture.snapshot().maximized)
  assert.ok(await page.evaluate(() => window.ipadLayoutFixture.snapshot().requiredWidth >= 1120), 'Two document columns require 560px each plus divider')
  await page.setViewportSize({ width: 1194, height: 834 })
  await page.waitForFunction(() => !window.ipadLayoutFixture.snapshot().maximized)
  await page.evaluate(() => window.ipadLayoutFixture.maximize())
  await page.setViewportSize({ width: 1366, height: 834 })
  assert.ok(await page.evaluate(() => window.ipadLayoutFixture.snapshot().maximized), 'User maximization survives resizing')
  await page.getByRole('button', { name: '도움 열기 first', exact: true }).tap()
  await page.getByRole('button', { name: 'AI 고정', exact: true }).waitFor()
  await page.locator('.tab-assistant:visible .chat-composer__action').waitFor()
  for (const selector of ['.chat-add-trigger', '.chat-composer__action', '.chat-model-trigger', '.chat-access-trigger']) {
    const size = await page.locator(`.tab-assistant:visible ${selector}`).boundingBox()
    assert.ok(size && size.width >= 44 && size.height >= 44, `Actual assistant composer ${selector} has a 44px touch target: ${JSON.stringify(size)}`)
  }
  await page.waitForFunction(() => window.ipadLayoutFixture.calls.findLast(call => call.channel === 'runtime:nativeSurfaces')?.request.blocked === true)
  await page.getByRole('button', { name: 'AI 고정', exact: true }).tap()
  await page.waitForFunction(() => window.ipadLayoutFixture.calls.findLast(call => call.channel === 'runtime:nativeSurfaces')?.request.blocked === false)
  assert.ok((await page.locator('.tab-document:visible').boundingBox()).width >= 560)
  await page.locator('.tab-assistant:visible .chat-composer__input').focus()
  await page.keyboard.press('Escape')
  assert.equal(await page.locator('.tab-assistant:visible').count(), 1, 'Pinned assistant remains a nonmodal companion')
  await page.locator('textarea[aria-label="first"]').focus()
  assert.equal(await page.evaluate(() => document.activeElement?.getAttribute('aria-label')), 'first', 'Pinned assistant permits document keyboard focus')
  await page.setViewportSize({ width: 834, height: 1194 })
  await page.waitForFunction(() => document.querySelector('.tab-with-assistant[data-assistant-open="true"]')?.getAttribute('data-assistant-overlay') === 'true')
  assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem('bandal:ipad:panel-modes:v2')).assistant), 'auto', 'Compact adaptation preserves the explicit AI pin preference')
  await page.setViewportSize({ width: 1366, height: 834 })
  await page.getByRole('button', { name: 'AI 고정 해제', exact: true }).waitFor()
  await page.evaluate(() => { window.ipadLayoutFixture.select('second'); window.ipadLayoutFixture.maximize() })
  await page.getByRole('button', { name: '도움 열기 second', exact: true }).tap()
  await page.getByRole('button', { name: 'AI 고정 해제', exact: true }).waitFor()
  assert.ok((await page.locator('.tab-document:visible').boundingBox()).width >= 560, 'Live document switch shares the global iPad pin preference')
  await page.getByRole('button', { name: '내 공간 열기', exact: true }).tap()
  await page.waitForFunction(() => document.querySelector('.ipad-shell').dataset.ipadLeft === 'docked')
  assert.equal(await page.locator('.tab-assistant:visible').count(), 1, 'Navigation and current document AI remain visible together when they fit')
  await page.getByRole('button', { name: '내 공간 닫기', exact: true }).last().tap()
  await page.evaluate(() => window.ipadLayoutFixture.restore())
  await page.getByRole('button', { name: '자료 열기', exact: true }).tap()
  await page.getByRole('button', { name: '패널 고정 해제', exact: true }).waitFor()
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-pinned'), 'right')
  await page.evaluate(() => window.ipadLayoutFixture.materialsAvailable(false))
  await page.waitForFunction(() => document.querySelector('.ipad-shell').dataset.ipadSide === 'none' && !window.ipadLayoutFixture.ui.getState().rightRailOpen)
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-pinned'), 'none', 'Learning releases the pinned materials width instead of displaying inert controls')
  await page.evaluate(() => window.ipadLayoutFixture.ui.getState().toggleRightRail())
  await page.waitForFunction(() => !window.ipadLayoutFixture.ui.getState().rightRailOpen)
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-side'), 'none', 'Keyboard toggle cannot expose an unavailable materials surface')
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-materials'), 'closed', 'Unavailable materials release their width')
  await page.evaluate(() => window.ipadLayoutFixture.materialsAvailable(true))
  await page.getByRole('button', { name: '자료 열기', exact: true }).tap()
  assert.equal(await page.locator('.ipad-shell').getAttribute('data-ipad-pinned'), 'right')
  await page.getByRole('button', { name: '자료 닫기', exact: true }).tap()
  await page.getByRole('button', { name: '설정 열기', exact: true }).tap()
  await page.locator('.settings-nav__item[data-category="account"]').tap()
  await page.getByRole('heading', { name: '계정', exact: true }).waitFor()
  await page.setViewportSize({ width: 507, height: 700 })
  await page.getByRole('button', { name: '설정 목록으로', exact: true }).tap()
  await page.locator('.settings-nav__item[data-category="general"]').tap()
  await page.getByRole('heading', { name: '일반', exact: true }).waitFor()
  assert.ok(await page.locator('.settings-sidebar').isHidden())
  assert.ok(await page.locator('.settings-content').isVisible())
  await page.waitForFunction(() => document.activeElement?.classList.contains('settings-content'))
  await page.keyboard.press('Meta+f')
  await page.waitForFunction(() => document.activeElement === document.querySelector('.settings-search input'))
  assert.ok(await page.locator('.settings-sidebar').isVisible(), 'Narrow keyboard search reveals the independent settings list')
  await page.locator('.settings-search input').fill('계정')
  await page.locator('.settings-nav__item[data-category="account"]').tap()
  await page.getByRole('heading', { name: '계정', exact: true }).waitFor()
  await page.getByRole('button', { name: '설정 목록으로', exact: true }).tap()
  await page.locator('.settings-search input').fill('')
  await page.locator('.settings-checklist').tap()
  await page.locator('.help-milestone-list li').filter({ hasText: '학교 선택' }).locator('button').tap()
  await page.getByRole('heading', { name: '학교', exact: true }).waitFor().catch(async error => {
    console.error('Settings milestone diagnostics', errors, await page.locator('body').innerText())
    throw error
  })
  assert.ok(await page.locator('.settings-sidebar').isHidden(), 'Checklist settings destinations reveal detail at narrow widths')
  await page.getByRole('button', { name: '앱으로 돌아가기', exact: true }).tap()
  await page.getByRole('button', { name: '자료 열기', exact: true }).tap()
  await page.getByRole('button', { name: '자료 닫기', exact: true }).waitFor({ state: 'visible' })
  assert.equal(Math.round((await page.locator('.ipad-right-surface').boundingBox()).width), 507, JSON.stringify(await page.locator('.ipad-right-surface').evaluate(element => ({ shell: element.parentElement.outerHTML.slice(0, 300), rect: element.getBoundingClientRect().toJSON(), css: Object.fromEntries(['width', 'min-width', 'max-width', 'left', 'right', 'position', 'display'].map(key => [key, getComputedStyle(element).getPropertyValue(key)])) }))))
  await page.getByRole('button', { name: '강의.pdf 더 보기', exact: true }).tap()
  await page.getByRole('menuitem', { name: /이름 변경/ }).waitFor()
  await page.keyboard.press('Escape')
  for (const width of [375, 507, 699, 700, 759, 760, 834, 900, 1024, 1366]) {
    await page.setViewportSize({ width, height: 650 })
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `No horizontal overflow at ${width}`)
    assert.ok(await page.getByRole('button', { name: '자료 닫기', exact: true }).isVisible())
  }
  assert.ok(await page.evaluate(() => window.ipadLayoutFixture.calls.some(call => call.channel === 'runtime:nativeSurfaces' && call.request.blocked === true)))
  await page.getByRole('button', { name: '자료 닫기', exact: true }).tap()
  // Native failure reproduction: opening from the empty-workspace action
  // anchors at y729, then the keyboard shrinks the viewport to 531px. Do not
  // filter first: that rerender previously hid the bad native AX bounds.
  await page.setViewportSize({ width: 1376, height: 1032 })
  await page.evaluate(() => {
    Object.defineProperty(window.visualViewport, 'height', { configurable: true, value: 531 })
    window.ipadLayoutFixture.openMenu(472, 729)
  })
  await page.waitForFunction(() => {
    const menu = document.querySelector('.new-tab-menu')
    return menu && menu.getBoundingClientRect().bottom <= 523 && parseFloat(menu.style.top) < 729
  })
  const directBrowserCommand = page.getByRole('button', { name: '새 브라우저 탭', exact: true })
  assert.equal(await page.locator('.new-tab-menu').evaluate(element => getComputedStyle(element).translate), 'none', 'Keyboard overflow correction moves layout rather than duplicating transformed native AX bounds')
  assert.ok((await directBrowserCommand.boundingBox()).height >= 44)
  await directBrowserCommand.tap()
  await page.locator('.new-tab-menu').waitFor({ state: 'hidden' })
  await page.evaluate(() => { delete window.visualViewport.height; window.visualViewport.dispatchEvent(new Event('resize')) })
  // Desktop WebKit has no software keyboard; emulate its real visualViewport
  // contract while retaining the actual React menus, observers and geometry.
  await page.evaluate(() => {
    const viewport = window.visualViewport
    for (const [name, value] of Object.entries({ width: 900, height: 260, offsetLeft: 40, offsetTop: 70 })) Object.defineProperty(viewport, name, { configurable: true, value })
    window.ipadLayoutFixture.openMenu(1050, 600)
  })
  const assertInVisualViewport = async selector => {
    await page.waitForFunction(selector => {
      const rect = document.querySelector(selector)?.getBoundingClientRect(), viewport = window.visualViewport
      return rect && rect.left >= viewport.offsetLeft + 7 && rect.top >= viewport.offsetTop + 7 && rect.right <= viewport.offsetLeft + viewport.width - 7 && rect.bottom <= viewport.offsetTop + viewport.height - 7
    }, selector).catch(async error => {
      console.error('Visual menu diagnostics', await page.locator(selector).evaluate(element => ({ rect: element.getBoundingClientRect().toJSON(), viewport: { top: visualViewport.offsetTop, left: visualViewport.offsetLeft, width: visualViewport.width, height: visualViewport.height }, style: element.getAttribute('style'), css: Object.fromEntries(['height','max-height','translate','transform','flex','overflow','position','top','left'].map(name => [name,getComputedStyle(element).getPropertyValue(name)])) })), errors)
      throw error
    })
    assert.equal(await page.locator(selector).getAttribute('data-bandal-native-overlay'), 'true')
    const rect = await page.locator(selector).boundingBox()
    await page.evaluate(() => window.ipadLayoutFixture.flush())
    assert.ok(await page.evaluate(rect => window.ipadLayoutFixture.calls.findLast(call => call.channel === 'runtime:nativeSurfaces')?.request.overlays.some(mask => mask.x <= rect.x && mask.y <= rect.y && mask.x + mask.width >= rect.x + rect.width && mask.y + mask.height >= rect.y + rect.height), rect), 'Native mask includes the actual menu rectangle')
  }
  await assertInVisualViewport('.new-tab-menu')
  const browserCommand = page.getByRole('button', { name: '새 브라우저 탭', exact: true })
  assert.ok((await browserCommand.boundingBox()).height >= 44)
  assert.ok((await browserCommand.boundingBox()).height < 80, 'A command exposes its own compact touch target')
  await page.evaluate(() => {
    Object.defineProperty(window.visualViewport, 'height', { configurable: true, value: 180 })
    Object.defineProperty(window.visualViewport, 'offsetTop', { configurable: true, value: 120 })
    window.visualViewport.dispatchEvent(new Event('resize')); window.visualViewport.dispatchEvent(new Event('scroll'))
  })
  await assertInVisualViewport('.new-tab-menu')
  await page.getByRole('textbox', { name: '새 탭 검색', exact: true }).fill('브라우저')
  await browserCommand.tap()
  await page.locator('.new-tab-menu').waitFor({ state: 'hidden' })
  await page.evaluate(() => { for (const name of ['width', 'height', 'offsetLeft', 'offsetTop']) delete window.visualViewport[name]; window.visualViewport.dispatchEvent(new Event('resize')) })
  await page.getByRole('button', { name: /^열린 탭 \d+개 목록$/ }).last().tap()
  await page.locator('.workspace-open-tabs-menu').waitFor()
  await page.evaluate(() => {
    Object.defineProperty(window.visualViewport, 'height', { configurable: true, value: 230 })
    Object.defineProperty(window.visualViewport, 'offsetTop', { configurable: true, value: 50 })
    window.visualViewport.dispatchEvent(new Event('resize')); window.visualViewport.dispatchEvent(new Event('scroll'))
  })
  await assertInVisualViewport('.workspace-open-tabs-menu')
  await page.getByRole('button', { name: '탭 목록 닫기', exact: true }).tap()
  await page.evaluate(() => { for (const name of ['width', 'height', 'offsetLeft', 'offsetTop']) delete window.visualViewport[name]; window.visualViewport.dispatchEvent(new Event('resize')) })
  await page.reload()
  await page.waitForFunction(() => window.ipadLayoutFixture?.snapshot()?.panels.length === 2)
  assert.equal(await page.locator('.tab-assistant:visible').count(), 0, 'Persisted pin preference never reopens AI at launch')
  await page.evaluate(() => window.ipadLayoutFixture.maximize())
  await page.getByRole('button', { name: '도움 열기 second', exact: true }).tap()
  await page.getByRole('button', { name: 'AI 고정 해제', exact: true }).waitFor()
  assert.deepEqual(errors, [])
  console.log('PASS iPad layout: actual adapted SettingsApp list/detail, touch actions, native blocker/masks, keyboard visual-viewport tab menus, pin limits, 11 widths, real Dockview topology and unsaved editor state across resize')
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
