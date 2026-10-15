import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { dependencies, runtime } from '../../../scripts/dependencies.mjs'
import { adaptIpadUISource } from './index.mjs'

const { webkit } = dependencies().require('@playwright/test')
const source = resolve(runtime, 'upstream/src/renderer/src')
const originalStyles = (await Promise.all([
  'styles/themes/light.css', 'styles/themes/dark.css', 'styles/tokens.css',
  'styles/base.css', 'app/app-shell.css', 'features/notes/note-tab.css'
].map(path => readFile(resolve(source, path), 'utf8')))).join('\n').replace(/@import\s+[^;]+;/g, '')
const style = await readFile(new URL('./base.css', import.meta.url), 'utf8')
const entry = await readFile(resolve(source, 'main.tsx'), 'utf8')
assert.match(adaptIpadUISource(entry, resolve(source, 'main.tsx')).code, /ui\/styles.css/)
assert.throws(() => adaptIpadUISource(entry.replace("import './styles/base.css'", ''), resolve(source, 'main.tsx')), /anchor changed/)

const browser = await webkit.launch()
try {
  for (const theme of ['light', 'dark']) for (const density of ['comfortable', 'compact']) {
    const page = await browser.newPage({ viewport: { width: 507, height: 700 }, hasTouch: true })
    await page.setContent(`<html data-platform="ipad" data-theme="${theme}" data-density="${density}"><body>
      <main style="padding:16px;display:grid;gap:12px">
        <button class="button button--primary">새 자료 가져오기</button>
        <button class="button button--secondary">취소</button>
        <button class="bare-icon-button" aria-label="닫기">×</button>
        <button class="button button--danger">삭제</button>
        <div class="note-tab"><div class="milkdown"><div class="editor" contenteditable="true"><p>본문 글꼴과 행간 보존 검사</p></div></div></div>
      </main></body></html>`)
    await page.addStyleTag({ content: originalStyles })
    const documentMetrics = () => page.locator('.editor').evaluate(node => {
      const css = getComputedStyle(node)
      return [css.fontSize, css.lineHeight, css.fontFamily, css.padding]
    })
    const before = await documentMetrics()
    await page.addStyleTag({ content: style })
    assert.deepEqual(await documentMetrics(), before, 'Chrome styling must not change document text metrics')
    for (const button of await page.getByRole('button').all()) {
      const bounds = await button.boundingBox()
      assert.ok(bounds.width >= 44 && bounds.height >= 44, 'Every common control retains its touch target in compact mode')
    }
    assert.ok((await page.locator('.button--primary').boundingBox()).height >= 48)
    const contrasts = await page.evaluate(() => {
      const luminance = color => {
        const values = color.match(/[\d.]+/g).slice(0, 3).map(Number).map(value => {
          const normalized = value / 255
          return normalized <= .04045 ? normalized / 12.92 : ((normalized + .055) / 1.055) ** 2.4
        })
        return values[0] * .2126 + values[1] * .7152 + values[2] * .0722
      }
      return [...document.querySelectorAll('.button')].map(node => {
        const css = getComputedStyle(node), a = luminance(css.color), b = luminance(css.backgroundColor)
        return (Math.max(a, b) + .05) / (Math.min(a, b) + .05)
      })
    })
    assert.ok(contrasts.every(value => value >= 4.5), `${theme} button text contrast: ${contrasts}`)
    await page.keyboard.press('Tab')
    // WebKit follows the host's Full Keyboard Access preference for buttons.
    // Explicit focus after keyboard input verifies our keyboard focus styling;
    // modal Tab traversal is exercised by the real settings/sidebar fixtures.
    await page.locator('.button--primary').focus()
    assert.equal(await page.locator('.button--primary').evaluate(node => node.matches(':focus-visible')), true)
    const normalText = await page.locator('.button--secondary').evaluate(node => parseFloat(getComputedStyle(node).fontSize))
    await page.evaluate(() => document.documentElement.style.setProperty('--font-scale', '1.25'))
    assert.equal(await page.locator('.button--secondary').evaluate(node => parseFloat(getComputedStyle(node).fontSize)), normalText * 1.25)
    await page.close()
  }
  console.log('PASS iPad UI foundation: light/dark contrast, compact touch targets, font scaling, focus, unchanged document metrics, strict entry integration')
} finally { await browser.close() }
