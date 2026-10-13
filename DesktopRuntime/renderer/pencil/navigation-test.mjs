import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'

const { require } = dependencies()
const { webkit } = require('@playwright/test')
const ts = require('typescript')
const navigation = await readFile(resolve(runtime, 'renderer/pencil/navigation.ts'), 'utf8')
const wheel = await readFile(resolve(runtime, 'upstream/src/renderer/src/features/pdf/lib/zoomInput.ts'), 'utf8')
const script = ts.transpileModule(`${navigation}\n${wheel}\nwindow.installNavigationFixture = installPencilNavigation; window.originalWheelZoomFactor = wheelZoomFactor`.replace(/^export /gm, ''), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None }
}).outputText

// Synthetic TouchEvents verify the iOS adapter branch in real WebKit. They do
// not replace physical two-finger/Pencil acceptance tests. In particular, the
// original touch target keeps receiving events after PDF replaces that node;
// those detached events no longer bubble to document on physical iPad WebKit.
const browser = await webkit.launch()
try {
  for (const touchEvents of [false, true]) {
    const page = await browser.newPage({ viewport: { width: 800, height: 700 } })
    const failures = []
    page.on('pageerror', error => failures.push(error.message))
    await page.setContent('<div class="pdf-scroller" style="width:600px;height:400px;overflow:auto"><section data-pdf-page="1" style="width:600px;height:900px"><span id="rendered-target">PDF text/canvas target</span></section></div>')
    await page.evaluate(touch => {
      Object.defineProperty(navigator, 'maxTouchPoints', { configurable: true, value: touch ? 5 : 0 })
      if (touch) Object.defineProperty(window, 'ontouchstart', { configurable: true, value: null })
    }, touchEvents)
    await page.addScriptTag({ content: script })
    const result = await page.evaluate(async touch => {
      const dispose = window.installNavigationFixture()
      const viewport = document.querySelector('.pdf-scroller')
      const target = document.getElementById('rendered-target')
      let zoom = 1, renderedZoom = 1, pendingFrame = false
      const wheels = [], fingers = new Map(), listeners = new Map()
      const trackListeners = node => {
        const active = new Map()
        listeners.set(node, active)
        const add = node.addEventListener.bind(node), remove = node.removeEventListener.bind(node)
        node.addEventListener = (type, callback, options) => {
          if (['touchmove', 'touchend', 'touchcancel'].includes(type)) {
            if (!active.has(type)) active.set(type, new Set())
            active.get(type).add(callback)
          }
          add(type, callback, options)
        }
        node.removeEventListener = (type, callback, options) => { active.get(type)?.delete(callback); remove(type, callback, options) }
      }
      const listenerCount = () => [...listeners.values()].reduce((count, types) => count + [...types.values()].reduce((sum, callbacks) => sum + callbacks.size, 0), 0)
      trackListeners(target)
      // The actual PDF updates its ref synchronously, then paints once per
      // animation frame. Exercise that same accumulation with its real factor.
      viewport.addEventListener('wheel', event => {
        if (!event.ctrlKey) return
        event.preventDefault()
        zoom *= window.originalWheelZoomFactor(event.deltaY, event.deltaMode, viewport.clientHeight)
        wheels.push({ targetIsViewport: event.target === viewport, x: event.clientX, y: event.clientY })
        if (!pendingFrame) {
          pendingFrame = true
          requestAnimationFrame(() => { renderedZoom = zoom; pendingFrame = false })
        }
      }, { passive: false })
      const send = (type, changes, eventTarget = viewport) => {
        if (touch) {
          const changedTouches = changes.map(([identifier, clientX, clientY]) => ({ identifier, clientX, clientY, target: fingers.get(identifier)?.target ?? eventTarget, touchType: 'direct' }))
          for (const point of changedTouches) {
            if (type === 'end' || type === 'cancel') fingers.delete(point.identifier)
            else fingers.set(point.identifier, point)
          }
          const event = new Event(`touch${type}`, { bubbles: true, cancelable: true })
          Object.defineProperties(event, { changedTouches: { value: changedTouches }, touches: { value: [...fingers.values()] } })
          eventTarget.dispatchEvent(event)
          return event.defaultPrevented
        } else {
          for (const [pointerId, clientX, clientY] of changes) eventTarget.dispatchEvent(new PointerEvent(
            `pointer${type === 'start' ? 'down' : type === 'end' ? 'up' : 'move'}`,
            { bubbles: true, cancelable: true, pointerType: 'touch', pointerId, clientX, clientY }
          ))
        }
      }
      send('start', [[10, 200, 200], [11, 400, 200]], target)
      const continuationTarget = touch ? target : viewport
      send('move', [[11, 420, 200]], continuationTarget) // 1.10 before replacement; connected target must not double-handle.
      const replacement = document.createElement('span')
      replacement.textContent = 'Replacement PDF render'
      trackListeners(replacement)
      target.replaceWith(replacement)
      // Both changed touches in one event/frame must accumulate, not discard
      // one side of the distance change. Final distance 320 / initial 200.
      const detachedPrevented = send('move', [[10, 180, 200], [11, 460, 200]], continuationTarget)
      send('move', [[10, 160, 200], [11, 480, 200]], continuationTarget)
      send('end', [[10, 160, 200], [11, 480, 200]], continuationTarget)
      await new Promise(requestAnimationFrame)
      const first = { zoom, renderedZoom, wheels: [...wheels], initialTargetConnected: target.isConnected, detachedPrevented, listenersAfterEnd: listenerCount() }
      // Reusing the same touch identifiers must start a fresh gesture. A lost
      // detached end would leave both old owners and block this two-finger pair.
      send('start', [[10, 200, 200], [11, 400, 200]], replacement)
      send('move', [[11, 450, 200]], touch ? replacement : viewport)
      send('cancel', [[10, 200, 200], [11, 450, 200]], touch ? replacement : viewport)
      const afterFresh = { zoom, listeners: listenerCount() }
      send('start', [[10, 200, 200], [11, 400, 200]], replacement)
      window.dispatchEvent(new Event('blur'))
      const listenersAfterReset = listenerCount()
      send('start', [[10, 200, 200], [11, 400, 200]], replacement)
      dispose()
      const listenersAfterDispose = listenerCount()
      send('move', [[11, 500, 200]], replacement)
      return { ...first, afterFresh, listenersAfterReset, listenersAfterDispose, zoomAfterDispose: zoom }
    }, touchEvents)
    assert.equal(result.initialTargetConnected, false)
    assert.ok(Math.abs(result.zoom - 1.6) < 1e-10, `${touchEvents ? 'TouchEvent' : 'PointerEvent'} must retain full 1.6× distance after PDF target replacement, got ${result.zoom}`)
    assert.equal(result.renderedZoom, result.zoom, 'RAF uses the accumulated final zoom')
    assert.equal(result.wheels.length, 5)
    assert.ok(result.wheels.every(event => event.targetIsViewport))
    assert.deepEqual(result.wheels.at(-1), { targetIsViewport: true, x: 320, y: 200 })
    if (touchEvents) assert.equal(result.detachedPrevented, true, 'detached move remains non-passive')
    assert.equal(result.listenersAfterEnd, 0)
    assert.ok(Math.abs(result.afterFresh.zoom - 2) < 1e-10, 'a fresh 1.25× gesture works after detached touchend')
    assert.equal(result.afterFresh.listeners, 0, 'touchcancel cleans every retained target listener')
    assert.equal(result.listenersAfterReset, 0)
    assert.equal(result.listenersAfterDispose, 0)
    assert.equal(result.zoomAfterDispose, result.afterFresh.zoom)
    assert.deepEqual(failures, [])
    await page.close()
  }
  console.log('WebKit navigation: detached original touch move/end, stable wheel target, paired changedTouches, fresh gesture, cancel/reset/dispose cleanup and original RAF accumulation passed')
} finally { await browser.close() }
