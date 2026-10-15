import assert from 'node:assert/strict'

export async function testSidebarSwipe(browser, url) {
  const page = await browser.newPage({ viewport: { width: 1366, height: 900 }, hasTouch: true })
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  try {
    await page.goto(url)
    await page.waitForFunction(() => window.ipadLayoutFixture?.snapshot()?.panels.length === 2)
    const handle = page.locator('.ipad-sidebar-swipe')
    await handle.waitFor()
    const open = () => page.evaluate(() => window.ipadLayoutFixture.ui.getState().leftRailOpen)
    const waitOpen = value => page.waitForFunction(value => window.ipadLayoutFixture.ui.getState().leftRailOpen === value, value)
    const pointer = async (type, dx = 0, dy = 0, options = {}) => page.evaluate(({ type, dx, dy, options }) => {
      const target = options.target === 'document' ? document.querySelector('.fixture-pane textarea') : document.querySelector('.ipad-sidebar-swipe')
      const rect = target.getBoundingClientRect()
      if (type === 'pointerdown' && options.isPrimary !== false) window.swipeFixtureOrigin = { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
      const origin = window.swipeFixtureOrigin
      const event = new PointerEvent(type, { bubbles: true, cancelable: true, pointerId: options.pointerId ?? 41,
        pointerType: options.pointerType ?? 'touch', isPrimary: options.isPrimary ?? true,
        buttons: type === 'pointerup' || type === 'pointercancel' ? 0 : 1, clientX: origin.x + dx, clientY: origin.y + dy })
      if (options.time !== undefined) Object.defineProperty(event, 'timeStamp', { value: options.time })
      target.dispatchEvent(event)
    }, { type, dx, dy, options })

    const bounds = await handle.boundingBox()
    assert.equal(bounds.width, 16, 'A narrow handle owns the swipe instead of the whole document')
    assert.equal(bounds.height, 112)
    assert.equal(bounds.x + bounds.width, 56, 'Closed swipe handle remains inside the mini rail')
    await page.evaluate(() => window.ipadLayoutFixture.flush())
    assert.ok(await page.evaluate(() => {
      const rect = document.querySelector('.ipad-sidebar-swipe').getBoundingClientRect()
      return window.ipadLayoutFixture.calls.findLast(call => call.channel === 'runtime:nativeSurfaces')?.request.overlays.some(mask =>
        mask.x <= rect.x && mask.y <= rect.y && mask.x + mask.width >= rect.right && mask.y + mask.height >= rect.bottom)
    }), 'Native PDF and browser hit testing receive the handle rectangle')

    await pointer('pointerdown', 0, 0, { time: 0 })
    await pointer('pointermove', 8, 0, { time: 1 })
    assert.equal(await handle.getAttribute('data-swipe-active'), 'true', 'Feedback begins at 8px without a long press')
    assert.equal(await open(), false, 'The layout remains stable during the gesture')
    await pointer('pointerup', 48, 0, { time: 150 })
    await waitOpen(true)
    assert.equal((await handle.boundingBox()).x + bounds.width, 336, 'Open handle stays inside the course sidebar')
    await handle.dispatchEvent('click', { detail: 1 })
    assert.equal(await open(), true, 'A compatibility click after the swipe cannot toggle twice')
    await pointer('pointerdown', 0, 0, { time: 0 })
    await pointer('pointermove', -48, 0, { time: 150 })
    await pointer('pointerup', -48, 0, { time: 151 })
    await waitOpen(false)
    await handle.click()
    await waitOpen(true)
    await handle.click()
    await waitOpen(false)

    for (const pointerType of ['pen', 'mouse']) {
      await pointer('pointerdown', 0, 0, { pointerType })
      await pointer('pointermove', 80, 0, { pointerType })
      await pointer('pointerup', 80, 0, { pointerType })
      assert.equal(await open(), false, `${pointerType} movement does not open the sidebar`)
    }
    await pointer('pointerdown')
    await pointer('pointermove', 3, 15)
    await pointer('pointerup', 80, 15)
    assert.equal(await open(), false, 'Vertical scrolling cancels the gesture')
    await pointer('pointerdown')
    await pointer('pointermove', 80)
    await pointer('pointercancel', 80)
    await pointer('pointerup', 80)
    assert.equal(await open(), false, 'Pointer cancellation keeps the sidebar closed')
    assert.equal(await handle.getAttribute('data-swipe-active'), 'false')
    await pointer('pointerdown')
    await pointer('pointermove', 80)
    await pointer('pointerdown', 0, 0, { pointerId: 42, isPrimary: false })
    await pointer('pointerup', 80)
    assert.equal(await open(), false, 'A second finger cancels instead of opening')
    await pointer('pointerdown')
    await pointer('pointermove', 80)
    await page.setViewportSize({ width: 1194, height: 834 })
    await pointer('pointerup', 80)
    assert.equal(await open(), false, 'Rotation or resize cancels in-flight gestures')
    await pointer('pointerdown', 0, 0, { target: 'document' })
    await pointer('pointermove', 80, 0, { target: 'document' })
    await pointer('pointerup', 80, 0, { target: 'document' })
    assert.equal(await open(), false, 'Document movement never starts a sidebar gesture')

    await pointer('pointerdown')
    await pointer('pointermove', 80)
    await page.evaluate(() => window.ipadLayoutFixture.ui.setState({ isSettingsOpen: true }))
    await handle.waitFor({ state: 'hidden' })
    assert.equal(await open(), false, 'Settings cancels and removes the edge handle')
    await page.evaluate(() => window.ipadLayoutFixture.ui.setState({ isSettingsOpen: false }))
    await handle.waitFor()
    await handle.focus()
    await page.keyboard.press('Enter')
    await waitOpen(true)
    await handle.focus()
    await page.keyboard.press('Space')
    await waitOpen(false)
    assert.deepEqual(errors, [])
    console.log('PASS iPad sidebar swipe integration: opening/closing, feedback, cancellation, native masks and keyboard toggle')
  } finally {
    await page.close()
  }
}
