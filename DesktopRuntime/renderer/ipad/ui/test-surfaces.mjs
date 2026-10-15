import assert from 'node:assert/strict'
import { mkdtemp, rm, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import touchPlugin from '../touch/index.mjs'
const { require } = dependencies(), { webkit } = require('@playwright/test')
const { createServer } = await import(pathToFileURL(require.resolve('vite')).href)
const { default: react } = await import(pathToFileURL(require.resolve('@vitejs/plugin-react')).href)
const cacheDir = await mkdtemp(join(tmpdir(), 'bandal-surfaces-ui-'))
const server = await createServer({ configFile: false, root: runtime, cacheDir, plugins: [touchPlugin(), react()], server: { host: '127.0.0.1', port: 0, watch: null, hmr: false }, resolve: { dedupe: ['react', 'react-dom'] } })
await server.listen()
const browser = await webkit.launch()
const baseline = process.argv.includes('--capture-before')
try {
  for (const [width, height, scale] of [[1194, 900, 1], [834, 900, 1], [507, 700, 1], [375, 700, 1], [375, 400, 1], [507, 700, 1.25]]) for (const theme of ['light', 'dark']) {
    if (baseline && !(scale === 1 && height >= 700 && ((width === 834 && theme === 'light') || (width === 507 && theme === 'dark') || (width === 375 && theme === 'light')))) continue
    const page = await browser.newPage({ viewport: { width, height }, hasTouch: true }), errors = []
    page.on('pageerror', error => errors.push(error.message))
    await page.goto(server.resolvedUrls.local[0] + 'renderer/ipad/ui/surfaces-fixture.html' + (baseline ? '?before=1' : ''))
    await page.waitForFunction(() => !!window.surfacesUI)
    await page.evaluate(({ theme, scale }) => { document.documentElement.dataset.theme = theme; document.documentElement.style.setProperty('--font-scale', scale) }, { theme, scale: String(scale) })
    const show = async view => { await page.evaluate(view => window.surfacesUI.show(view), view); await page.waitForTimeout(240) }
    const targets = async locator => { for (const el of await locator.all()) { const box = await el.boundingBox(); assert.ok(box && box.width >= 43.9 && box.height >= 43.9, `${width}/${theme}: target below 44px ${await el.evaluate(node => node.outerHTML.slice(0, 180))} ${JSON.stringify(box)}`) } }
    const fits = async locator => { const box = await locator.boundingBox(); assert.ok(box && box.x >= -1 && box.y >= -1 && box.x + box.width <= width + 1 && box.y + box.height <= height + 1, `Surface escaped viewport: ${JSON.stringify(box)} at ${width}×${height}`) }
    const noOverflow = async () => assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `Horizontal overflow at ${width}/${theme}`)
    const capture = async name => { if (scale === 1 && height >= 700 && ((width === 834 && theme === 'light') || (width === 507 && theme === 'dark') || (width === 375 && theme === 'light'))) await page.screenshot({ path: `/tmp/bandal-ui-redesign-surfaces-${name}-${width}-${theme}${baseline ? '-before' : ''}.png` }) }
    if (baseline) {
      await page.locator('.learning-navigation').waitFor(); await capture('learning')
      await show('course'); await capture('dialog')
      await show('recording'); await page.getByRole('combobox', { name: '재생 속도' }).selectOption('1.5')
      await page.locator('audio').evaluate(node => { let time = 0; Object.defineProperty(node, 'currentTime', { configurable: true, get: () => time, set: value => { time = value } }) })
      await page.getByRole('button', { name: '10초 앞으로', exact: true }).click(); await capture('recording')
      await show('canvas'); await capture('canvas'); await show('browser'); await capture('browser'); await page.close(); continue
    }
    await page.locator('.learning-navigation').waitFor()
    await targets(page.locator('.learning-navigation button,.learning-sources button,.learning-field select,.learning-field textarea'))
    await page.getByRole('button', { name: '원문 예문으로 돌아가기' }).click()
    assert.equal(await page.evaluate(() => window.surfacesUI.events.filter(value => value === 'source:article').length), 1)
    if (width <= 507) assert.equal(await page.locator('.learning-project-grid').evaluate(node => getComputedStyle(node).gridTemplateColumns.split(' ').length), 1)
    assert.ok(await page.locator('.learning-form-row').evaluate(node => { const parent = node.getBoundingClientRect(); return [...node.querySelectorAll('input,textarea,select')].every(control => { const box = control.getBoundingClientRect(); return box.left >= parent.left && box.right <= parent.right + 1 }) }), 'Long-option controls stay inside the form, including a column layout')
    await noOverflow()
    await page.locator('.learning-content-scroll').evaluate(node => { node.scrollTop = 0 })
    await capture('learning')

    await show('course'); await page.getByRole('dialog').waitFor()
    await fits(page.getByRole('dialog')); await targets(page.getByRole('dialog').locator('button,input'))
    await capture('dialog')
    await page.getByRole('textbox', { name: '이름', exact: true }).fill('읽기 연습')
    await page.locator('.color-swatch[data-course-color="blue"]').click()
    await page.getByRole('button', { name: '과목 만들기', exact: true }).click()
    assert.equal(await page.evaluate(() => window.surfacesUI.events.filter(value => value === 'course:읽기 연습:blue').length), 1, 'Original course submit executes once')
    await show('feedback'); await page.getByRole('dialog').waitFor(); await fits(page.getByRole('dialog')); await targets(page.getByRole('dialog').locator('button,textarea'))
    await page.keyboard.press('Escape'); await page.getByRole('dialog').waitFor({ state: 'detached' })

    await show('recording'); await page.locator('.recording-playback').waitFor(); await targets(page.locator('.recording button,.recording select,.recording input[type="range"]'))
    await page.getByRole('combobox', { name: '재생 속도' }).selectOption('1.5')
    assert.equal(await page.locator('audio').evaluate(node => node.playbackRate), 1.5)
    // No real lecture is loaded by this fixture. Keep media seeking local so
    // an empty audio decoder cannot reset the real component's seek state.
    await page.locator('audio').evaluate(node => { let time = 0; Object.defineProperty(node, 'currentTime', { configurable: true, get: () => time, set: value => { time = value } }) })
    await page.getByRole('button', { name: '10초 앞으로', exact: true }).click()
    assert.equal(await page.getByRole('slider', { name: '재생 위치' }).inputValue(), '10')
    assert.ok(await page.locator('.recording-playback__transport').evaluate(node => node.scrollWidth <= node.clientWidth), 'Playback controls wrap without clipping')
    await noOverflow()
    await capture('recording')

    await show('canvas'); await page.getByRole('toolbar').waitFor(); await targets(page.getByRole('toolbar').locator('button,input[type="range"],select'))
    await page.getByRole('button', { name: '페이지 추가', exact: true }).click(); await page.getByRole('button', { name: 'PDF로 내보내기', exact: true }).click()
    assert.deepEqual(await page.evaluate(() => window.surfacesUI.events.filter(value => ['page', 'export'].includes(value))), ['page', 'export'])
    if (height === 400) assert.ok((await page.locator('.canvas-tab__viewport').boundingBox()).height >= 200, 'Compact toolbar leaves 200px of paper')
    await noOverflow()
    await page.getByRole('toolbar').evaluate(node => { node.scrollLeft = 0 })
    await capture('canvas')

    await show('browser'); await fits(page.locator('.browser-toolbar-menu')); await targets(page.locator('.browser-toolbar-menu button,.browser-toolbar button,.browser-address input')); await noOverflow()
    const font = async (selector, pixels) => assert.equal(await page.locator(selector).first().evaluate(node => parseFloat(getComputedStyle(node).fontSize)), pixels * scale, `Browser ${selector} scales with app font`)
    await font('.browser-address input', 16); await font('.browser-address__display', 15)
    await font('.ipad-browser-menu-section > button', 15); await font('.ipad-browser-presentation button', 15)
    await font('.ipad-browser-menu-section h3', 13); await font('.ipad-browser-presentation small', 13); await font('.ipad-browser-history span', 13)
    const selectedColor = () => page.locator('.ipad-browser-presentation button[aria-pressed="true"]').evaluate(node => { const probe = document.createElement('span'); probe.style.backgroundColor = 'var(--accent)'; probe.style.color = 'var(--on-accent)'; document.body.append(probe); const actual = getComputedStyle(node), expected = getComputedStyle(probe); const matches = actual.backgroundColor === expected.backgroundColor && actual.color === expected.color; probe.remove(); return matches })
    assert.ok(await selectedColor(), 'Browser presentation selection uses theme accent and its readable text color')
    await page.getByRole('button', { name: '모바일', exact: true }).click(); assert.ok(await selectedColor())
    await page.getByRole('button', { name: '데스크톱', exact: true }).click()
    await page.locator('.browser-toolbar-menu').evaluate(node => { node.scrollTop = 0 }); await capture('browser')
    if (width === 507 && scale === 1.25) await page.screenshot({ path: `/tmp/bandal-ui-redesign-surfaces-browser-${width}-${theme}-125.png` })
    await show('browserprofiles'); await targets(page.locator('.browser-find input,.browser-find button,.browser-profile-manager input,.browser-profile-manager select')); await noOverflow()
    await font('.browser-find input', 16); await font('.browser-profile-manager input', 16); await font('.browser-profile-manager__form select', 16); await font('.browser-profile-select select', 16)
    assert.ok(await page.locator('.browser-profile-manager').evaluate(node => [...node.querySelectorAll('input,select')].every(control => { const box = control.getBoundingClientRect(), parent = node.getBoundingClientRect(); return box.left >= parent.left && box.right <= parent.right + 1 })), 'Browser profile fields stay inside their panel')
    assert.deepEqual(await page.locator('.browser-profile-manager select').evaluateAll(nodes => nodes.map(node => getComputedStyle(node).appearance)), ['none', 'none'], 'WebKit profile selects keep their authored 44px touch height')

    await show('menu'); await fits(page.getByRole('menu')); await targets(page.getByRole('menu').locator('button')); await noOverflow()
    await show('toast'); await fits(page.locator('.toast')); await targets(page.locator('.toast button'))
    await page.getByRole('button', { name: '다시 시도' }).click(); assert.equal(await page.evaluate(() => window.surfacesUI.events.filter(value => value === 'retry').length), 1)
    assert.ok(await page.locator('.toast__message').evaluate(node => node.scrollHeight <= node.clientHeight + 1 && getComputedStyle(node).whiteSpace === 'normal'), 'Long notification remains readable')
    await show('market'); await targets(page.locator('.study-market button,.study-market input,.study-market select')); await noOverflow()

    for (const view of ['board', 'graph']) {
      await show(view); await page.evaluate(() => window.surfacesUI.settings(true))
      await page.locator('.shell-settings-overlay').waitFor()
      assert.ok(await page.evaluate(() => document.elementFromPoint(innerWidth / 2, 60)?.closest('.shell-settings-overlay')), `Settings must visually cover a mounted ${view}`)
      await page.evaluate(() => window.surfacesUI.settings(false))
    }
    await show('documents')
    const ink = await page.locator('.document-ink').evaluate(node => getComputedStyle(node).color)
    assert.equal(ink, 'rgb(20, 23, 31)', 'Paper ink is independent of app theme')
    assert.deepEqual(errors, [])
    await page.close()
  }
  if (baseline) console.log('Captured baseline surfaces with the shared UI layer omitted; existing iPad layout/touch adapters remain enabled')
  // Foundation and feature chrome must not alter note body metrics.
  const sourceRoot = join(runtime, 'upstream/src/renderer/src')
  const styles = (await Promise.all(['styles/tokens.css', 'styles/base.css', 'features/notes/note-tab.css'].map(path => readFile(join(sourceRoot, path), 'utf8')))).join('\n').replace(/@import[^;]+;/g, '')
  const page = await browser.newPage()
  await page.setContent('<html data-platform="ipad"><body><div class="note-tab"><div class="milkdown"><div class="editor" contenteditable="true"><p>Document metrics</p></div></div></div></body></html>')
  await page.addStyleTag({ content: styles })
  const metrics = () => page.locator('.editor').evaluate(node => { const style = getComputedStyle(node); return [style.fontSize, style.lineHeight, style.padding, style.fontFamily] })
  const before = await metrics()
  await page.addStyleTag({ content: await readFile(new URL('./surfaces.css', import.meta.url), 'utf8') })
  assert.deepEqual(await metrics(), before)
  await page.close()
  if (!baseline) console.log('PASS iPad surfaces: real course/feedback/playback/source/canvas actions, browser chrome typography/selection/select sizing, light/dark 375–1194px, 125% font, touch targets, dialogs, long notices, settings layering and document/ink invariants')
} finally { await browser.close(); await server.close(); await rm(cacheDir, { recursive: true, force: true }) }
