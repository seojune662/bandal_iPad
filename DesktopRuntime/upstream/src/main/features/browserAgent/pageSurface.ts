/**
 * Binds the agent's page tools to real guests.
 *
 * Everything Electron-shaped lives here so `browserTools` and `pageDriver`
 * stay testable without a browser. The interesting parts are the two places
 * this has to wait on something outside main:
 *
 *  - opening a tab, which the RENDERER owns (guests live in its fixed layer),
 *    so main asks and then waits for the tab to register itself
 *  - a handoff, which waits on the student
 *
 * Both are bounded. An agent that hangs forever is worse than one that gives
 * up and says what it could not do.
 */

import type { GuestWebContents } from './guestRegistry'
import { createPageDriver, type DriverFrame } from './pageDriver'
import type { PageSurface } from './browserTools'
import type { GenerationTracker } from './refs'
import { RunStopped } from './run'

/** A tab that never registers is a tab the agent cannot use. */
const OPEN_TIMEOUT_MS = 10_000
/** Long enough for a portal redirect chain, short enough to not feel stuck. */
const SETTLE_TIMEOUT_MS = 3_000
/** Long enough for an OTP, short enough that a forgotten run ends. */
const HANDOFF_TIMEOUT_MS = 5 * 60 * 1000

export interface PageSurfaceDeps {
  resolveGuest: (tabId: string) => GuestWebContents | null
  /** Frames of a guest, main frame first. */
  framesOf: (guest: GuestWebContents) => DriverFrame[]
  /**
   * Asks the renderer for a tab and resolves with its id.
   *
   * One call, not a request plus a separate wait: the split is what made the
   * two sides impossible to correlate, so main matched them by URL prefix and
   * a redirecting portal reported a working tab as a failure.
   */
  requestTab: (url: string, timeoutMs: number) => Promise<string | null>
  /**
   * Waits for the page to stop moving after an action, bounded.
   *
   * There was NO wait anywhere in the agent path. A click is synchronous; the
   * navigation it triggers is not — so the next snapshot ran against the old
   * document, and because the generation counter only bumps on the renderer's
   * `dom-ready` round trip, the stale outline still looked valid.
   */
  settle: (tabId: string, timeoutMs: number) => Promise<void>
  /** Asks the renderer to bring an existing tab forward. */
  requestActivateTab: (tabId: string) => void
  /** Resolves once that tab's guest has registered itself again. */
  awaitTabRegister: (tabId: string, timeoutMs: number) => Promise<boolean>
  sendKey: (tabId: string, key: string) => Promise<void>
  history: (
    tabId: string,
    action: 'back' | 'forward' | 'reload' | 'stop'
  ) => Promise<void>
  tabLifecycle: (
    tabId: string,
    action: 'focus' | 'close'
  ) => Promise<boolean>
  findInPage: (tabId: string, text: string) => Promise<number>
  generations: GenerationTracker
  /**
   * Commits text over CDP. Optional: without it typing degrades to the DOM
   * tier, which is correct for plain fields and wrong only for pages that
   * listen for `compositionend`.
   */
  insertText?: (tabId: string, text: string) => Promise<void>
  run: {
    assertLive: (tabId?: string) => void
    step: (action: string, url?: string) => void
    wait: (message: string) => void
    /** Resolves when the student presses 계속, or rejects if they stop. */
    awaitResume: (timeoutMs: number) => Promise<'resumed' | 'stopped'>
  }
}

export function createPageSurface(deps: PageSurfaceDeps): PageSurface {
  function driverFor(tabId: string): ReturnType<typeof createPageDriver> | null {
    const guest = deps.resolveGuest(tabId)
    if (guest === null) return null
    return createPageDriver({
      frames: () => deps.framesOf(guest),
      currentUrl: () => guest.getURL()
    })
  }

  /**
   * Lets the page finish whatever the action started, then reports the state
   * the agent should reason about — not the one that existed a millisecond
   * after the click.
   */
  function currentOutcome(
    tabId: string,
    before: string,
    result: { ok: boolean; problem?: string | null; options?: { value: string; label: string }[] }
  ): {
    ok: boolean
    problem: string | null
    options?: { value: string; label: string }[]
    url: string
    title: string
    navigated: boolean
  } {
    const guest = deps.resolveGuest(tabId)
    let url = before
    let title = ''
    if (guest !== null) {
      try {
        url = guest.getURL()
        title = guest.getTitle()
      } catch {
        // Destroyed mid-settle; `before` is the last thing we knew.
      }
    }
    return {
      ok: result.ok,
      problem: result.problem ?? null,
      ...(result.options === undefined ? {} : { options: result.options }),
      url,
      title,
      navigated: url !== before
    }
  }

  async function settled(
    tabId: string,
    before: string,
    result: { ok: boolean; problem?: string | null; options?: { value: string; label: string }[] }
  ) {
    await deps.settle(tabId, SETTLE_TIMEOUT_MS)
    return currentOutcome(tabId, before, result)
  }

  return {
    async openTab(url) {
      const tabId = await deps.requestTab(url, OPEN_TIMEOUT_MS)
      if (tabId === null) {
        throw new Error('탭을 여는 데 실패했어요.')
      }
      return { tabId, url }
    },

    async wakeTab(tabId) {
      if (deps.resolveGuest(tabId) !== null) return true
      deps.requestActivateTab(tabId)
      return deps.awaitTabRegister(tabId, OPEN_TIMEOUT_MS)
    },

    generation(tabId) {
      return deps.generations.current(tabId)
    },

    currentUrl(tabId) {
      const guest = deps.resolveGuest(tabId)
      if (guest === null) return null
      try {
        return guest.getURL()
      } catch {
        return null
      }
    },

    async snapshot(tabId, maxChars) {
      const driver = driverFor(tabId)
      if (driver === null) return null
      const result = await driver.snapshot(
        deps.generations.current(tabId),
        maxChars
      )
      return { url: result.url, outline: result.outline }
    },

    async read(tabId, maxChars) {
      const driver = driverFor(tabId)
      if (driver === null) return null
      return driver.read(maxChars)
    },

    async factsFor(tabId, frameIndex, elementIndex) {
      const driver = driverFor(tabId)
      if (driver === null) return null
      return driver.factsFor(frameIndex, elementIndex)
    },

    async act(tabId, frameIndex, elementIndex, action) {
      const driver = driverFor(tabId)
      if (driver === null) {
        return {
          ok: false,
          problem: '그 탭을 찾지 못했어요.',
          url: '',
          title: '',
          navigated: false
        }
      }
      const before = this.currentUrl(tabId) ?? ''

      if (action.kind === 'type' && deps.insertText !== undefined) {
        // The reason CDP exists here. `Input.insertText` commits text the way
        // an IME does, so 한글 arrives intact and `compositionend` listeners
        // actually fire — neither is true of a value-setter write.
        //
        // Focus the field through the DOM tier first (harmless, and the only
        // way to say WHICH field), then commit the text over CDP. If the
        // debugger is unavailable — the student has DevTools open — fall back
        // to the DOM tier rather than failing the action.
        const focused = await driver.act(frameIndex, elementIndex, {
          kind: 'type',
          text: ''
        })
        if (!focused.ok) {
          return {
            ok: false,
            problem: focused.problem ?? '그 요소에 입력하지 못했어요.',
            url: before,
            title: '',
            navigated: false
          }
        }
        try {
          await deps.insertText(tabId, action.text)
          return settled(tabId, before, { ok: true, problem: null })
        } catch {
          // Degrade, do not fail.
        }
      }

      const result = await driver.act(frameIndex, elementIndex, action)
      return settled(tabId, before, result)
    },

    async scroll(tabId, to) {
      const driver = driverFor(tabId)
      if (driver === null) {
        return currentOutcome(tabId, '', {
          ok: false,
          problem: '그 탭을 찾지 못했어요.'
        })
      }
      const before = this.currentUrl(tabId) ?? ''
      return settled(tabId, before, await driver.scroll(to))
    },

    async pressKey(tabId, key) {
      const before = this.currentUrl(tabId)
      if (before === null) {
        return currentOutcome(tabId, '', {
          ok: false,
          problem: '그 탭을 찾지 못했어요.'
        })
      }
      try {
        await deps.sendKey(tabId, key)
        return settled(tabId, before, { ok: true, problem: null })
      } catch {
        return currentOutcome(tabId, before, {
          ok: false,
          problem: '키를 누르지 못했어요.'
        })
      }
    },

    async hover(tabId, frameIndex, elementIndex) {
      const driver = driverFor(tabId)
      if (driver === null) {
        return currentOutcome(tabId, '', {
          ok: false,
          problem: '그 탭을 찾지 못했어요.'
        })
      }
      const before = this.currentUrl(tabId) ?? ''
      const result = await driver.hover(frameIndex, elementIndex)
      // Hover opens transient menus but cannot navigate by itself. Waiting for
      // a navigation settle here makes every menu interaction unnecessarily slow.
      return currentOutcome(tabId, before, result)
    },

    async navigateHistory(tabId, action) {
      const before = this.currentUrl(tabId)
      if (before === null) {
        return currentOutcome(tabId, '', {
          ok: false,
          problem: '그 탭을 찾지 못했어요.'
        })
      }
      try {
        await deps.history(tabId, action)
        return settled(tabId, before, { ok: true, problem: null })
      } catch {
        return currentOutcome(tabId, before, {
          ok: false,
          problem: '페이지 이동을 실행하지 못했어요.'
        })
      }
    },

    tabLifecycle(tabId, action) {
      return deps.tabLifecycle(tabId, action)
    },

    findInPage(tabId, text) {
      return deps.findInPage(tabId, text)
    },

    async handoff(_tabId, message) {
      deps.run.assertLive(_tabId)
      deps.run.wait(message)
      try {
        return await deps.run.awaitResume(HANDOFF_TIMEOUT_MS)
      } catch (error) {
        if (error instanceof RunStopped) return 'stopped'
        return 'stopped'
      }
    },

    assertLive(tabId) {
      deps.run.assertLive(tabId)
    },

    step(action, url) {
      deps.run.step(action, url)
    }
  }
}
