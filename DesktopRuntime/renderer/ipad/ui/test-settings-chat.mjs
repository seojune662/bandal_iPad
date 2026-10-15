import assert from 'node:assert/strict'
import { readFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import platform from '../../platform/index.mjs'
import recording from '../../recording/index.mjs'
import layout from '../layout/index.mjs'
import settingsChat, { adaptSettingsChatSource } from './settingsChatPlugin.mjs'

const { require } = dependencies(), { webkit } = require('@playwright/test')
const sourcePath = join(runtime, 'upstream/src/renderer/src/features/chat/ComposerPopover.tsx')
const source = await readFile(sourcePath, 'utf8')
assert.match(adaptSettingsChatSource(source, sourcePath).code, /IpadComposerPopover/)
assert.throws(() => adaptSettingsChatSource(source.replace('export function ComposerPopover(', 'export function Changed('), sourcePath), /anchor changed/)
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-settings-chat-ui-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, define: { __APP_VERSION__: '"fixture"' }, plugins: [platform(), recording(), layout(), settingsChat(), react()], server: { host: '127.0.0.1', port: 0, watch: null, hmr: false }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1194, height: 834 }, hasTouch: true })
  const settle = async () => page.evaluate(async () => {
    await document.fonts.ready
    await Promise.all(document.getAnimations().filter(animation => animation.effect?.getTiming().iterations !== Infinity).map(animation => animation.finished.catch(() => {})))
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
  })
  const errors = []
  page.on('pageerror', error => { errors.push(error.message); console.error('Fixture renderer error:', error.message) })
  page.on('console', message => { if (message.type() === 'error') console.error(message.text()) })
  await page.goto(server.resolvedUrls.local[0] + 'renderer/ipad/ui/settings-chat-fixture.html')
  await page.locator('.ipad-settings .setting-row').first().waitFor().catch(async error => { console.error((await page.locator('body').innerText()).slice(0, 4000)); throw error })
  const categories = await page.evaluate(() => window.ipadSettingsChatFixture.categories)
  const targetFailures = async selector => page.locator(selector).evaluateAll(elements => elements.filter(element => {
    const box = element.getBoundingClientRect()
    return box.width && box.height && getComputedStyle(element).visibility !== 'hidden' && (box.width < 43.9 || box.height < 43.9)
  }).map(element => ({ tag: element.tagName, class: element.className, text: element.textContent?.slice(0, 35), width: element.getBoundingClientRect().width, height: element.getBoundingClientRect().height })))
  for (const width of [1194, 834, 507, 375]) {
    await page.setViewportSize({ width, height: 834 })
    for (const category of categories) {
      await page.evaluate(category => window.ipadSettingsChatFixture.show('settings', category), category)
      await page.waitForFunction(category => document.querySelector(`.settings-nav__item[data-category="${category}"]`)?.getAttribute('aria-current') === 'page', category)
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
      assert.equal(await page.locator('.settings-content').evaluate(element => element.scrollWidth <= element.clientWidth + 1), true, `No settings overflow: ${category} at ${width}: ${JSON.stringify(await page.locator('.settings-content').evaluate(element => [...element.querySelectorAll('*')].filter(child => child.getBoundingClientRect().right > element.getBoundingClientRect().right + 1).slice(0, 8).map(child => ({class:child.className,width:child.getBoundingClientRect().width,text:child.textContent?.slice(0,40)}))))}`)
      assert.deepEqual(await targetFailures('.ipad-settings button, .ipad-settings select'), [], `44px settings targets: ${category} at ${width}`)
      assert.ok((await page.locator('.settings-content__inner').boundingBox()).width <= 760.1, 'Readable settings column')
    }
    const returnButton = page.getByRole('button', { name: '앱으로 돌아가기', exact: true })
    assert.ok(await returnButton.evaluate(element => {
      const box = element.getBoundingClientRect()
      return box.left >= 0 && box.right <= innerWidth && element.scrollWidth <= element.clientWidth
    }), `Return to app label stays visible at ${width}px`)
    await returnButton.tap()
    await page.locator('.ipad-settings').waitFor({ state: 'detached' })
    await page.locator('.chat-composer__input').waitFor()
  }
  await page.evaluate(() => window.ipadSettingsChatFixture.show('settings', 'tabs'))
  for (const label of ['마크다운', '브라우저', 'AI', '녹음', '화이트보드', '학업 보드']) {
    await page.getByRole('tab', { name: label, exact: true }).tap()
    assert.deepEqual(await targetFailures('.settings-panel button, .settings-panel select'), [], `Subtab targets: ${label}`)
    assert.equal(await page.locator('.settings-content').evaluate(element => element.scrollWidth <= element.clientWidth + 1), true, `Subtab fits: ${label}`)
  }
  await page.evaluate(() => window.ipadSettingsChatFixture.show('settings', 'general'))
  await page.locator('.settings-panel .toggle').first().waitFor()
  const toggle = page.locator('.settings-panel .toggle').first(), before = await toggle.getAttribute('aria-checked')
  await toggle.tap()
  await page.waitForFunction(before => document.querySelector('.settings-panel .toggle')?.getAttribute('aria-checked') !== before, before)
  const after = await toggle.getAttribute('aria-checked')
  await page.evaluate(() => { window.ipadSettingsChatFixture.saved.fail = true })
  await toggle.tap()
  await page.waitForFunction(() => document.body.textContent.includes('설정을 저장하지 못'))
  assert.equal(await toggle.getAttribute('aria-checked'), after, 'Failed setting preserves committed state')
  await page.locator('.toast').first().tap()
  await page.evaluate(() => { window.ipadSettingsChatFixture.saved.fail = false; window.ipadSettingsChatFixture.show('tab') })
  await page.locator('.chat-composer__input').waitFor()
  await page.locator('.chat-empty__desc').waitFor({ state: 'visible' })
  assert.match(await page.locator('.chat-empty__desc').innerText(), /10주차/)
  assert.match(await page.getByRole('region', { name: '현재 대화 자료' }).innerText(), /선택한 글 포함/)
  const topSummary = await page.locator('.ipad-chat-context-summary').boundingBox()
  assert.ok(topSummary.y < (await page.locator('.chat-reading-area').boundingBox()).y, 'Current document and selection remain above the conversation')
  await page.getByRole('button', { name: '자동 연결 자료 제거', exact: true }).tap()
  await page.waitForFunction(() => document.querySelector('.ipad-chat-context-summary').textContent.includes('현재 자료 연결 해제됨'))
  await page.getByRole('button', { name: '현재 자료 연결', exact: true }).tap()
  await page.waitForFunction(() => document.querySelector('.ipad-chat-context-summary').textContent.includes('선택한 글 포함'))
  await page.locator('.chat-composer__input').fill('전환해도 남는 한국어 초안')
  for (const variant of ['sidebar', 'tab']) {
    await page.evaluate(variant => window.ipadSettingsChatFixture.show(variant), variant)
    await page.waitForFunction(variant => document.querySelector('.chat-tab')?.getAttribute('data-variant') === variant, variant)
    assert.equal(await page.locator('.chat-composer__input').inputValue(), '전환해도 남는 한국어 초안')
    assert.deepEqual(await targetFailures('.chat-tab button'), [], `Both AI variants use 44px targets: ${variant}`)
    assert.equal(await page.locator('.chat-composer__input').evaluate(element => parseFloat(getComputedStyle(element).fontSize) >= 16), true)
  }
  await page.setViewportSize({ width: 1194, height: 834 })
  await page.locator('.chat-composer__input').fill('화면 너비가 달라져도 입력하고 있는 긴 초안의 모든 줄이 자연스럽게 이어지고 다시 넓어지면 입력창 높이가 돌아와야 합니다. '.repeat(2))
  await settle()
  const wideHeight = (await page.locator('.chat-composer__input').boundingBox()).height
  await page.setViewportSize({ width: 507, height: 834 })
  await page.waitForFunction(height => document.querySelector('.chat-composer__input').getBoundingClientRect().height > height, wideHeight)
  await page.locator('.chat-composer__input').fill('전환해도 남는 한국어 초안')
  // Simulate the OS visual viewport without changing the layout viewport.
  await page.evaluate(() => {
    const fake = new EventTarget()
    Object.assign(fake, { offsetLeft: 0, offsetTop: 100, width: 507, height: 500 })
    Object.defineProperty(window, 'visualViewport', { configurable: true, value: fake })
  })
  await page.locator('.chat-model-trigger').tap()
  await page.locator('.chat-composer-popover').waitFor()
  const popup = await page.locator('.chat-composer-popover').boundingBox()
  assert.ok(popup.y >= 108 && popup.y + popup.height <= 593, `Popover above keyboard: ${JSON.stringify(popup)}`)
  for (const key of [...Array(8).fill('Tab'), ...Array(8).fill('Shift+Tab')]) {
    await page.keyboard.press(key)
    assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.chat-composer-popover')), 'Popover owns keyboard traversal')
  }
  await page.evaluate(() => { Object.assign(window.visualViewport, { height: 350, offsetTop: 140 }); window.visualViewport.dispatchEvent(new Event('resize')) })
  await page.waitForFunction(() => document.querySelector('.chat-composer-popover').getBoundingClientRect().bottom <= 483)
  await page.keyboard.press('Escape')
  await page.locator('.chat-composer-popover').waitFor({ state: 'hidden' })
  assert.ok(await page.locator('.chat-model-trigger').evaluate(element => element === document.activeElement), 'Escape restores model trigger focus')
  await page.locator('.chat-add-trigger').tap()
  await page.getByRole('button', { name: '현재 브라우저 페이지', exact: true }).focus()
  await page.keyboard.press('Enter')
  await page.locator('.chat-composer-popover').waitFor({ state: 'hidden' })
  await page.waitForFunction(() => document.activeElement?.matches('.chat-composer__input'))
  assert.ok(await page.locator('.chat-composer__input').evaluate(element => element === document.activeElement), 'Attachment selection preserves the original return-to-composer behavior')
  assert.match(await page.locator('.ipad-chat-context-summary').innerText(), /첨부 1개/)
  await page.locator('.chat-model-trigger').tap()
  await page.locator('.chat-composer__input').tap()
  await page.locator('.chat-composer-popover').waitFor({ state: 'hidden' })
  assert.ok(await page.locator('.chat-composer__input').evaluate(element => element === document.activeElement), 'Outside pointer keeps the intended input focus')
  await page.evaluate(() => {
    const fixture = window.ipadSettingsChatFixture
    fixture.sessions.setState(store => ({ sessions: { ...store.sessions, 'ui-conversation': { ...store.sessions['ui-conversation'], state: { ...fixture.initialChatViewState, streaming: true, messages: [{ id: 'answer', role: 'assistant', blocks: [{ id: 'text', kind: 'text', text: '핵심 내용을 정리하고 있어요.', streaming: true }], streaming: true, interrupted: false }] } } } }))
  })
  await page.getByRole('button', { name: '응답 중단', exact: true }).waitFor()
  assert.deepEqual(await targetFailures('.chat-tab button'), [], 'Streaming controls remain reachable')
  await page.getByRole('button', { name: '응답 중단', exact: true }).tap()
  assert.ok(await page.evaluate(() => window.ipadSettingsChatFixture.calls.some(call => call.channel === 'chat:cancel')), 'Stop calls original cancel contract')
  await page.locator('.chat-composer__input').focus()
  await page.evaluate(() => {
    const fixture = window.ipadSettingsChatFixture
    fixture.sessions.setState(store => ({ sessions: { ...store.sessions, 'ui-conversation': { ...store.sessions['ui-conversation'], state: { ...fixture.initialChatViewState, pendingPermissionId: 'permission', messages: [{ id: 'approval-answer', role: 'assistant', blocks: [{ id: 'summary', kind: 'text', text: '핵심 개념을 정리했어요. 이 요약을 노트에 저장할까요?', streaming: false }, { id: 'permission', kind: 'permission', toolName: 'Write', input: { file_path: 'notes/summary.md' } }], streaming: false, interrupted: false }] } } } }))
  })
  await page.locator('.chat-approval-dock').waitFor()
  assert.ok(await page.locator('.chat-composer__input').evaluate(element => element === document.activeElement), 'Approval arrival never steals the writing focus')
  assert.deepEqual(await targetFailures('.chat-tab button'), [], 'Approval actions retain 44px targets')
  await settle()
  await page.screenshot({ path: '/tmp/bandal-ui-redesign-settings-chat-approval.png' })
  await page.locator('.chat-approval-dock').getByRole('button', { name: '취소', exact: true }).tap()
  assert.ok(await page.evaluate(() => window.ipadSettingsChatFixture.calls.some(call => call.channel === 'chat:respondPermission' && call.request.response.behavior === 'deny')), 'Approval uses the original explicit permission contract')
  await page.evaluate(() => {
    const fixture = window.ipadSettingsChatFixture
    fixture.sessions.setState(store => ({ sessions: { ...store.sessions, 'ui-conversation': { ...store.sessions['ui-conversation'], phase: 'error', openError: '연결이 끊겼어요. 다시 시도해 주세요.' } } }))
  })
  await page.getByText('채팅을 열지 못했어요', { exact: true }).waitFor()
  assert.deepEqual(await targetFailures('.chat-tab button'), [], 'Error recovery controls remain reachable')
  await page.evaluate(() => {
    const fixture = window.ipadSettingsChatFixture
    fixture.sessions.setState(store => ({ sessions: { ...store.sessions, 'ui-conversation': { ...store.sessions['ui-conversation'], phase: 'ready', state: fixture.initialChatViewState } } }))
  })
  for (const theme of ['light', 'dark']) {
    await page.setViewportSize({ width: theme === 'light' ? 1194 : 507, height: 834 })
    await page.evaluate(theme => { document.documentElement.dataset.theme = theme; document.documentElement.style.setProperty('--font-scale', theme === 'dark' ? '1.25' : '1'); window.ipadSettingsChatFixture.saved.value = { ...window.ipadSettingsChatFixture.saved.value, theme, fontScale: theme === 'dark' ? 1.25 : 1 }; window.ipadSettingsChatFixture.show('tab') }, theme)
    await page.locator('.chat-composer__input').waitFor()
    await settle()
    await page.screenshot({ path: `/tmp/bandal-ui-redesign-settings-chat-${theme}-ai.png` })
    assert.equal(await page.locator('.chat-tab').evaluate(element => element.scrollWidth <= element.clientWidth + 1), true, `AI fits ${theme} / large text`)
    assert.ok((await page.locator('.chat-composer').boundingBox()).width >= Math.min(760, page.viewportSize().width - 32) - 1, 'Composer uses the full reading column, without inherited double margins')
    assert.deepEqual(await targetFailures('.chat-tab button'), [], `AI targets ${theme} / large text`)
    await page.evaluate(() => window.ipadSettingsChatFixture.show('settings', 'general'))
    await page.locator('.ipad-settings .setting-row').first().waitFor()
    await settle()
    await page.screenshot({ path: `/tmp/bandal-ui-redesign-settings-chat-${theme}-settings.png` })
    assert.equal(await page.locator('.settings-content').evaluate(element => element.scrollWidth <= element.clientWidth + 1), true, `Settings fits ${theme} / large text`)
  }
  assert.deepEqual(errors, [], 'No renderer exceptions')
  const comparisonSettings = await page.evaluate(() => window.ipadSettingsChatFixture.saved.value)
  const beforePage = await browser.newPage({ viewport: { width: 1194, height: 834 }, hasTouch: true })
  await beforePage.goto(server.resolvedUrls.local[0] + 'renderer/ipad/ui/settings-chat-fixture.html?before=1')
  await beforePage.locator('.ipad-settings .setting-row').first().waitFor()
  for (const theme of ['light', 'dark']) {
    await beforePage.setViewportSize({ width: theme === 'light' ? 1194 : 507, height: 834 })
    await beforePage.evaluate(({ theme, comparisonSettings }) => {
      const fixture = window.ipadSettingsChatFixture
      fixture.saved.value = { ...comparisonSettings, theme, fontScale: theme === 'dark' ? 1.25 : 1 }
      document.documentElement.dataset.theme = theme
      document.documentElement.style.setProperty('--font-scale', theme === 'dark' ? '1.25' : '1')
      fixture.updateComposerDraft('ui-conversation', { text: '전환해도 남는 한국어 초안', browser: true })
      fixture.show('tab')
    }, { theme, comparisonSettings })
    await beforePage.locator('.chat-composer__input').waitFor()
    await beforePage.evaluate(async () => { await document.fonts.ready; await Promise.all(document.getAnimations().filter(animation => animation.effect?.getTiming().iterations !== Infinity).map(animation => animation.finished.catch(() => {}))) })
    await beforePage.screenshot({ path: `/tmp/bandal-ui-redesign-settings-chat-before-${theme}-ai.png` })
    await beforePage.evaluate(() => window.ipadSettingsChatFixture.show('settings', 'general'))
    await beforePage.locator('.ipad-settings .setting-row').first().waitFor()
    await beforePage.evaluate(async () => { await document.fonts.ready; await Promise.all(document.getAnimations().filter(animation => animation.effect?.getTiming().iterations !== Infinity).map(animation => animation.finished.catch(() => {}))) })
    await beforePage.screenshot({ path: `/tmp/bandal-ui-redesign-settings-chat-before-${theme}-settings.png` })
  }
  await beforePage.close()
  console.log('PASS settings/chat UI: 20 routes × 4 widths (375–1194px), 6 subtabs, 44px targets, settings save failure, persistent document/selection/attachment summary, actual ChatSurface draft retention + streaming cancel/approval/error, keyboard viewport popover + focus, light/dark/large text before/after screenshots')
  await page.close()
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
