import assert from 'node:assert/strict'

/** Actual adapted Settings + Board/editor portal + graph + global shortcuts. */
export async function testSettingsFocus(browser, url) {
  const page = await browser.newPage({ viewport: { width: 1194, height: 834 }, hasTouch: true })
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  try {
    await page.goto(url)
    await page.waitForFunction(() => window.ipadLayoutFixture?.snapshot()?.panels.length === 2)
    await page.evaluate(() => window.ipadLayoutFixture.ui.getState().toggleBoardOverlay())
    await page.locator('.board-view-switch').getByRole('button', { name: '목록', exact: true }).tap()
    await page.getByRole('button', { name: '보존할 태스크 상세 편집', exact: true }).click({ button: 'right' })
    await page.locator('.board-context-menu').waitFor()
    await page.keyboard.press('Escape')
    await page.locator('.board-context-menu').waitFor({ state: 'hidden' })
    await page.getByRole('button', { name: '보존할 태스크 상세 편집', exact: true }).tap()
    const notes = page.locator('#board-task-notes')
    await notes.fill('설정에서 돌아와도 남을 미저장 내용')
    const editor = await page.locator('.board-editor').elementHandle()
    const assertSettingsOwnsFocus = async () => {
      await page.waitForFunction(() => !!document.activeElement?.closest('.ipad-settings'))
      await page.locator('.settings-search input').focus()
      for (const key of [...Array(32).fill('Tab'), ...Array(32).fill('Shift+Tab')]) {
        await page.keyboard.press(key)
        assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.ipad-settings')), `${key} remains in foreground settings: ${await page.evaluate(() => document.activeElement?.outerHTML.slice(0, 300))}`)
      }
    }
    for (const close of ['Escape', '앱으로 돌아가기']) {
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
      await notes.focus()
      await page.evaluate(() => {
        window.settingsOpener = null
        window.addEventListener('keydown', function record(event) {
          if (event.key !== ',') return
          window.settingsOpener = event.target.id
          window.removeEventListener('keydown', record, true)
        }, true)
      })
      await page.keyboard.press('Meta+,')
      assert.equal(await page.evaluate(() => window.settingsOpener), 'board-task-notes', 'Settings shortcut starts in the intended draft input')
      await assertSettingsOwnsFocus()
      assert.ok(await page.locator('.board-overlay').evaluate(element => element.inert))
      assert.ok(await page.locator('.board-editor').evaluate(element => element.inert), 'Portaled task editor is also suspended')
      assert.equal(await page.evaluate(() => window.ipadLayoutFixture.calls.filter(call => call.channel === 'board:updateTask').length), 0, 'Opening settings never saves the draft implicitly')
      await page.locator('.settings-checklist').tap()
      await page.waitForFunction(() => !!document.activeElement?.closest('.help-milestones'))
      await page.keyboard.press('Shift+Tab')
      assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.help-milestones')), 'Nested settings dialog owns the top focus trap')
      await page.keyboard.press('Escape')
      await page.locator('.help-milestones').waitFor({ state: 'hidden' })
      assert.ok(await page.evaluate(() => window.ipadLayoutFixture.ui.getState().isSettingsOpen), 'Nested Escape leaves settings open')
      await page.evaluate(() => window.ipadLayoutFixture.openPortal())
      await page.waitForFunction(() => !!document.activeElement?.closest('.browser-import-dialog'))
      const source = page.locator('.browser-import-dialog select').first()
      await source.focus()
      await page.keyboard.press('Tab')
      assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.browser-import-dialog')), 'Settings yields middle Tab to a real body portal dialog')
      await page.locator('.browser-import-close').focus()
      await page.keyboard.press('Shift+Tab')
      assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.browser-import-dialog')), 'Portal owns its boundary Tab')
      await page.keyboard.press('Escape')
      await page.locator('.browser-import-dialog').waitFor({ state: 'hidden' })
      assert.ok(await page.evaluate(() => window.ipadLayoutFixture.ui.getState().isSettingsOpen))
      if (close === 'Escape') await page.keyboard.press('Escape')
      else await page.getByRole('button', { name: '앱으로 돌아가기', exact: true }).tap()
      await page.locator('.ipad-settings').waitFor({ state: 'hidden' })
      await page.waitForFunction(() => document.activeElement?.id === 'board-task-notes').catch(async error => {
        console.error('Settings return focus', close, await page.evaluate(() => ({ active: document.activeElement?.outerHTML.slice(0, 500), notes: document.querySelector('#board-task-notes')?.outerHTML, editor: document.querySelector('.board-editor')?.getAttribute('inert'), board: document.querySelector('.board-overlay')?.getAttribute('inert'), ui: { settings: window.ipadLayoutFixture.ui.getState().isSettingsOpen, board: window.ipadLayoutFixture.ui.getState().isBoardOverlayOpen } })))
        throw error
      })
      assert.ok(await editor.evaluate(element => element === document.querySelector('.board-editor')), 'Background editor stays mounted')
      assert.equal(await notes.inputValue(), '설정에서 돌아와도 남을 미저장 내용')
      assert.equal(await page.locator('.board-overlay').evaluate(element => element.hasAttribute('inert')), false)
      assert.equal(await page.locator('.board-editor').evaluate(element => element.hasAttribute('inert')), false)
    }
    await page.locator('.board-editor').getByRole('button', { name: '저장', exact: true }).tap()
    await page.locator('.board-editor').waitFor({ state: 'hidden' })
    assert.equal(await page.evaluate(() => window.ipadLayoutFixture.calls.findLast(call => call.channel === 'board:updateTask')?.request.notes), '설정에서 돌아와도 남을 미저장 내용', 'Original explicit save path receives the retained draft')
    await page.evaluate(() => window.ipadLayoutFixture.ui.getState().closeBoardOverlay())
    await page.evaluate(() => window.ipadLayoutFixture.ui.getState().toggleLinkGraph())
    const graphClose = page.locator('.link-graph-overlay__actions button').last()
    await graphClose.focus()
    await page.keyboard.press('Meta+,')
    await assertSettingsOwnsFocus()
    assert.ok(await page.locator('.link-graph-overlay').evaluate(element => element.inert))
    await page.keyboard.press('Escape')
    await page.locator('.ipad-settings').waitFor({ state: 'hidden' })
    await page.waitForFunction(() => document.activeElement === document.querySelector('.link-graph-overlay__actions button:last-child'))
    assert.ok(await page.evaluate(() => window.ipadLayoutFixture.ui.getState().isLinkGraphOpen), 'Settings dismissal preserves graph state')
    await graphClose.tap()
    // The visible navigation action closes its rail; return to the surviving
    // navigation trigger instead of attempting to focus an inert old button.
    await page.setViewportSize({ width: 507, height: 700 })
    await page.getByRole('button', { name: '내 공간 열기', exact: true }).tap()
    await page.locator('.global-navigation').getByRole('button', { name: '설정', exact: true }).tap()
    await assertSettingsOwnsFocus()
    await page.getByRole('button', { name: '앱으로 돌아가기', exact: true }).tap()
    await page.waitForFunction(() => document.activeElement === document.querySelector('.ipad-shell-chrome button'))
    assert.deepEqual(errors, [])
    console.log('PASS settings focus: Cmd+, and visible action; Tab/ShiftTab; nested Escape; background board/portal draft + explicit save; graph retention; close focus restore')
    await testSettingsPackDialogs(browser, url)
  } finally { await page.close() }
}

/** Real Settings → plugin center → both pack import entries, with only IPC held. */
export async function testSettingsPackDialogs(browser, url) {
  const page = await browser.newPage({ viewport: { width: 1194, height: 834 }, hasTouch: true })
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  const json = JSON.stringify({ schemaVersion: 1, id: 'custom:focus-fixture', name: 'Focus fixture', description: 'Dialog ownership fixture', author: 'Test', version: '1.0.0', locale: 'ko-KR', worksOn: ['course'], recipe: 'Produce a fixture result.', allowedTools: [], usesWeb: false, outputs: { dir: 'output', primary: 'result.md' } })
  try {
    await page.goto(url)
    await page.waitForFunction(() => window.ipadLayoutFixture?.snapshot()?.panels.length === 2)
    await page.evaluate(async () => {
      const { setIpcAdapter } = await import('/upstream/src/renderer/src/lib/ipc.ts')
      const original = window.bandal.invoke
      window.packImportRequests = []
      const invoke = async (channel, request) => {
        if (channel === 'plugins:catalog') return { entries: [], sources: [] }
        if (channel === 'packs:list') return { packs: [] }
        if (channel === 'mcp:list') return { servers: [], availability: { available: false, reason: 'Fixture' } }
        if (channel === 'packs:importText') {
          window.packImportRequests.push(request)
          return new Promise((resolve, reject) => { window.settlePackImport = success => success ? resolve({}) : reject(new Error('Fixture import failed')) })
        }
        return original(channel, request)
      }
      setIpcAdapter({ invoke, on: window.bandal.on })
      window.addEventListener('keydown', event => { if (event.key === 'Escape') window.packEscapeConsumed = event.defaultPrevented })
    })
    for (const entry of ['catalog', 'study-tool']) {
      await page.keyboard.press('Meta+,')
      await page.locator('.settings-nav__item[data-category="packs"]').tap()
      if (entry === 'catalog') await page.getByRole('button', { name: '플러그인 찾아보기', exact: true }).tap()
      const open = async () => {
        if (entry === 'catalog') {
          await page.locator('.settings-catalog-install-menu > button').tap()
          await page.getByRole('menuitem', { name: '팩 JSON 붙여넣기', exact: true }).tap()
        } else {
          await page.locator('.plugin-center-add > button').tap()
          await page.getByRole('menuitem', { name: '학습 도구 가져오기', exact: true }).tap()
        }
        await page.locator('.settings-pack-dialog').waitFor()
      }
      const dialog = page.locator('.settings-pack-dialog')
      const textarea = dialog.locator('textarea')
      const assertParent = async () => {
        assert.ok(await page.evaluate(() => window.ipadLayoutFixture.ui.getState().isSettingsOpen), `${entry}: child Escape/completion retains parent settings`)
        assert.ok(await page.locator('.ipad-settings').isVisible())
      }
      const escape = async () => {
        await page.evaluate(() => { window.packEscapeConsumed = null })
        await page.keyboard.press('Escape')
        assert.equal(await page.evaluate(() => window.packEscapeConsumed), true, `${entry}: child consumes Escape, including pending import`)
        await assertParent()
      }
      const before = await page.evaluate(() => window.packImportRequests.length)
      await open()
      await textarea.fill(json)
      await escape()
      await dialog.waitFor({ state: 'hidden' })
      assert.equal(await page.evaluate(() => window.packImportRequests.length), before, `${entry}: idle Escape never imports`)

      for (const success of [false, true]) {
        await open()
        await textarea.fill(json)
        for (const key of [...Array(5).fill('Tab'), ...Array(5).fill('Shift+Tab')]) {
          await page.keyboard.press(key)
          assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.settings-pack-dialog')), `${entry}: idle ${key} belongs to child`)
        }
        await dialog.getByRole('button', { name: '가져오기', exact: true }).tap()
        const expected = before + (success ? 2 : 1)
        await page.waitForFunction(count => window.packImportRequests.length === count, expected)
        await dialog.getByRole('button', { name: '가져오는 중…', exact: true }).waitFor()
        await textarea.focus()
        for (const key of ['Tab', 'Shift+Tab']) {
          await page.keyboard.press(key)
          assert.ok(await page.evaluate(() => !!document.activeElement?.closest('.settings-pack-dialog')), `${entry}: pending ${key} belongs to child`)
        }
        await escape()
        assert.ok(await dialog.isVisible(), `${entry}: pending Escape cannot dismiss the active import`)
        assert.equal(await textarea.inputValue(), json, `${entry}: pending Escape preserves pasted JSON`)
        assert.equal(await page.evaluate(() => window.packImportRequests.length), expected, `${entry}: Escape never retries the write`)
        await page.evaluate(value => window.settlePackImport(value), success)
        if (!success) {
          await dialog.locator('.settings-pack-feedback[role="alert"]').waitFor()
          await assertParent()
          assert.equal(await textarea.inputValue(), json, `${entry}: failed import retains the user's JSON`)
          await escape()
        }
        await dialog.waitFor({ state: 'hidden' })
        await assertParent()
        assert.equal(await page.evaluate(() => window.packImportRequests.length), expected, `${entry}: settlement never replays the import`)
      }
      await page.keyboard.press('Escape')
      await page.locator('.ipad-settings').waitFor({ state: 'hidden' })
    }
    assert.deepEqual(errors, [])
    console.log('PASS settings pack dialogs: actual Catalog/Packs entries; idle/pending Tab and consumed Escape; parent retention; draft/error visibility; success closes child only; no write replay')
  } finally { await page.close() }
}
