/**
 * Running the agent's reads and actions inside a guest.
 *
 * Two things make this different from the existing in-page bridges
 * (`loginBridge`, `selectionBridge`), and both matter:
 *
 * 1. **Isolated world.** Those bridges inject into the page's MAIN world and
 *    exfiltrate through a prefixed `console.log`, which the page can read,
 *    tamper with, and forge — any page can emit
 *    `console.log('__bandal_login_form__…')`. Harmless today because main
 *    re-validates the origin, but not a foundation for an agent. Here the
 *    script runs where the page cannot see it and the value returns on the
 *    promise.
 *
 * 2. **Every frame.** Both bridges are main-frame only
 *    (`loginBridge.ts`: `if (window.top !== window) return`), which means they
 *    are blind to Xinics LearningX's Canvas iframe, Moodle's player iframes,
 *    and SSO iframes. `webFrameMain.framesInSubtree` covers them, and it needs
 *    no CDP.
 *
 * The Electron surface is behind `PageDriverDeps` so the logic stays testable
 * without a running browser.
 */

import {
  canClick,
  canSelect,
  canType,
  type ActionVerdict,
  type ElementFacts
} from './actionPolicy'
import {
  DEFAULT_SNAPSHOT_CHARS,
  READ_SOURCE,
  renderSnapshot,
  SNAPSHOT_SOURCE,
  TARGET_INDEX_SOURCE,
  type FrameSnapshot,
  type SnapshotElement
} from './snapshot'

/** One frame we can run script in. Mirrors `WebFrameMain`'s useful surface. */
export interface DriverFrame {
  /** Runs in an isolated world — invisible to the page. */
  executeJavaScript: (code: string) => Promise<unknown>
}

export interface PageDriverDeps {
  /** Main frame first, then descendants, in a stable order. */
  frames: () => DriverFrame[]
  currentUrl: () => string
}

export interface SnapshotResult {
  url: string
  outline: string
  /** Kept so an action need not re-read the page to know what it is touching. */
  frames: FrameSnapshot[]
}

export interface ActResult {
  ok: boolean
  facts: ElementFacts | null
  /** ok === false 일 때, 학생/모델이 읽을 한국어 한 줄. */
  problem: string | null
  /** select 를 만졌을 때 그 요소가 실제로 제공하는 값들. */
  options?: { value: string; label: string }[]
}

export type ScrollTarget =
  | { kind: 'down' | 'up' | 'top' | 'bottom' }
  | { kind: 'ref'; frameIndex: number; elementIndex: number }

interface RawFrameResult {
  url?: unknown
  elements?: unknown
}

function toElements(raw: unknown): SnapshotElement[] {
  if (!Array.isArray(raw)) return []
  return raw.flatMap((entry, index) => {
    if (typeof entry !== 'object' || entry === null) return []
    const row = entry as Record<string, unknown>
    return [
      {
        index: typeof row['index'] === 'number' ? row['index'] : index,
        role: (typeof row['role'] === 'string'
          ? row['role']
          : 'text') as SnapshotElement['role'],
        name: typeof row['name'] === 'string' ? row['name'] : '',
        href: typeof row['href'] === 'string' ? row['href'] : null,
        tag: typeof row['tag'] === 'string' ? row['tag'] : '',
        type: typeof row['type'] === 'string' ? row['type'] : null,
        inNonGetForm: row['inNonGetForm'] === true,
        disabled: row['disabled'] === true,
        value: typeof row['value'] === 'string' ? row['value'] : null,
        required: row['required'] === true
      }
    ]
  })
}

function toActResult(raw: unknown): ActResult {
  const row =
    typeof raw === 'object' && raw !== null
      ? (raw as Record<string, unknown>)
      : {}
  const result: ActResult = {
    ok: row['ok'] === true,
    facts: (row['facts'] ?? null) as ElementFacts | null,
    problem: typeof row['problem'] === 'string' ? row['problem'] : null
  }
  if (Array.isArray(row['options'])) {
    result.options = row['options'].flatMap((option) => {
      if (typeof option !== 'object' || option === null) return []
      const item = option as Record<string, unknown>
      if (typeof item['value'] !== 'string' || typeof item['label'] !== 'string') {
        return []
      }
      return [{ value: item['value'], label: item['label'] }]
    })
  }
  return result
}

/**
 * A page script that never comes back.
 *
 * A guest showing a native `alert()` blocks its renderer, so
 * `executeJavaScript` never settles — and with no timeout, EVERY later tool
 * call on that tab hung with it. The agent did not fail; it stopped existing.
 *
 * Rejecting is the honest outcome: the caller turns it into a message the
 * student can act on ("페이지가 응답하지 않아요"), which is recoverable. A
 * silent hang is not.
 */
export const PAGE_SCRIPT_TIMEOUT_MS = 5_000

class PageScriptTimeout extends Error {
  constructor() {
    super('페이지가 응답하지 않아요. 알림 창이 떠 있는지 확인해 주세요.')
    this.name = 'PageScriptTimeout'
  }
}

export function runGuestScript<T>(
  exec: () => Promise<T>,
  timeoutMs: number = PAGE_SCRIPT_TIMEOUT_MS
): Promise<T> {
  return new Promise((resolve, reject) => {
    let settled = false
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      reject(new PageScriptTimeout())
    }, timeoutMs)
    let pending: Promise<T>
    try {
      pending = exec()
    } catch (error) {
      settled = true
      clearTimeout(timer)
      reject(error instanceof Error ? error : new Error(String(error)))
      return
    }
    pending.then(
      (value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(value)
      },
      (error: unknown) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        reject(error instanceof Error ? error : new Error(String(error)))
      }
    )
  })
}

export function createPageDriver(deps: PageDriverDeps) {
  async function snapshot(
    generation: number,
    maxChars: number = DEFAULT_SNAPSHOT_CHARS
  ): Promise<SnapshotResult> {
    const frames = deps.frames()
    const collected: FrameSnapshot[] = []

    for (const [frameIndex, frame] of frames.entries()) {
      try {
        const raw = (await runGuestScript(() =>
          frame.executeJavaScript(SNAPSHOT_SOURCE)
        )) as RawFrameResult
        collected.push({
          frameIndex,
          url: typeof raw?.url === 'string' ? raw.url : '',
          elements: toElements(raw?.elements)
        })
      } catch {
        // A cross-origin frame we cannot script is simply not in the outline.
        // Reporting it as an error would make every SSO page look broken.
      }
    }

    return {
      url: deps.currentUrl(),
      outline: renderSnapshot(collected, generation, maxChars),
      frames: collected
    }
  }

  async function read(maxChars: number): Promise<{ url: string; text: string }> {
    const [main] = deps.frames()
    if (main === undefined) return { url: deps.currentUrl(), text: '' }
    try {
      const raw = (await runGuestScript(() => main.executeJavaScript(READ_SOURCE))) as {
        url?: unknown
        text?: unknown
      }
      const text = typeof raw?.text === 'string' ? raw.text : ''
      return {
        url: deps.currentUrl(),
        text: text.slice(0, Math.max(500, maxChars))
      }
    } catch {
      return { url: deps.currentUrl(), text: '' }
    }
  }

  /**
   * Performs one action, after the policy has approved it.
   *
   * The element is addressed by the SAME ordinal the snapshot used, recomputed
   * page-side with the same selector — so a page that changed shape between
   * snapshot and action resolves to a different element, which is why the
   * caller compares the facts it got back before trusting the result.
   */
  async function act(
    frameIndex: number,
    elementIndex: number,
    action:
      | { kind: 'click' }
      | { kind: 'type'; text: string }
      | { kind: 'select'; value: string }
  ): Promise<ActResult> {
    const frame = deps.frames()[frameIndex]
    if (frame === undefined) {
      return {
        ok: false,
        facts: null,
        problem: '그 프레임을 찾지 못했어요.'
      }
    }

    const payload = JSON.stringify({ index: elementIndex, action })
    const source = `(() => {
      const input = ${payload};
      ${TARGET_INDEX_SOURCE}
      // The SAME enumeration the snapshot used. Three copies of this had
      // drifted: this one did not filter \`opacity: 0\`, so one faded element
      // shifted every ordinal and a click landed on the neighbouring row —
      // reporting success.
      const target = __bandalTargets()[input.index] || null;
      if (!target) return {
        ok: false,
        facts: null,
        problem: '그 요소를 찾지 못했어요. 페이지가 바뀌었을 수 있어요.'
      };
      const tag = target.tagName.toLowerCase();
      const type = (target.getAttribute('type') || '').toLowerCase();
      const form = target.closest('form');
      const facts = {
        tag: tag,
        type: type === '' ? null : type,
        inNonGetForm: form ? (form.getAttribute('method') || 'get').toLowerCase() !== 'get' : false,
        href: tag === 'a' ? target.getAttribute('href') : null,
        disabled: Boolean(target.disabled)
      };
      if (input.action.kind === 'facts') return { ok: true, facts: facts, problem: null };
      if (input.action.kind === 'click') {
        target.click();
        return { ok: true, facts: facts, problem: null };
      }
      if (input.action.kind === 'type') {
        const setter = Object.getOwnPropertyDescriptor(
          tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
          'value'
        );
        if (setter && setter.set) setter.set.call(target, input.action.text);
        else target.value = input.action.text;
        target.dispatchEvent(new Event('input', { bubbles: true }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
        if (target.value !== input.action.text) return {
          ok: false,
          facts: facts,
          problem: '입력이 반영되지 않았어요.'
        };
        return { ok: true, facts: facts, problem: null };
      }
      if (input.action.kind === 'select') {
        if (target.tagName !== 'SELECT') return {
          ok: false,
          facts: facts,
          problem: 'select 요소가 아니에요.'
        };
        const selectOptions = Array.from(target.options);
        const options = selectOptions.slice(0, 200).map((option) => ({
          value: option.value,
          label: (option.textContent || '').trim().slice(0, 100)
        }));
        const wanted = input.action.value;
        let selectedIndex = selectOptions.findIndex((option) => option.value === wanted);
        if (selectedIndex < 0) {
          const wantedLabel = wanted.trim();
          selectedIndex = selectOptions.findIndex(
            (option) => (option.textContent || '').trim() === wantedLabel
          );
        }
        if (selectedIndex < 0) {
          const normalizedWanted = wanted.replace(/\\s+/g, '');
          selectedIndex = selectOptions.findIndex(
            (option) => (option.textContent || '').replace(/\\s+/g, '') === normalizedWanted
          );
        }
        if (selectedIndex < 0) return {
          ok: false,
          facts: facts,
          problem: '그 값을 고를 수 없어요.',
          options: options
        };
        const intendedValue = selectOptions[selectedIndex].value;
        target.selectedIndex = selectedIndex;
        target.dispatchEvent(new Event('input', { bubbles: true }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
        if (target.value !== intendedValue) return {
          ok: false,
          facts: facts,
          problem: '값을 바꾸지 못했어요.',
          options: options
        };
        return { ok: true, facts: facts, problem: null, options: options };
      }
      return { ok: false, facts: facts, problem: '지원하지 않는 행동이에요.' };
    })()`

    try {
      return toActResult(await runGuestScript(() => frame.executeJavaScript(source)))
    } catch {
      return {
        ok: false,
        facts: null,
        problem: '페이지에서 실행하지 못했어요.'
      }
    }
  }

  /** Reads an element's facts without touching it, so the policy can rule. */
  async function factsFor(
    frameIndex: number,
    elementIndex: number
  ): Promise<ElementFacts | null> {
    const result = await act(frameIndex, elementIndex, {
      kind: 'facts'
    } as unknown as { kind: 'click' })
    return result.facts
  }

  async function scroll(to: ScrollTarget): Promise<ActResult> {
    const frameIndex = to.kind === 'ref' ? to.frameIndex : 0
    const frame = deps.frames()[frameIndex]
    if (frame === undefined) {
      return { ok: false, facts: null, problem: '그 프레임을 찾지 못했어요.' }
    }
    const payload = JSON.stringify(to)
    const source = `(() => {
      const input = ${payload};
      if (input.kind === 'ref') {
        ${TARGET_INDEX_SOURCE}
        const target = __bandalTargets()[input.elementIndex] || null;
        if (!target) return {
          ok: false,
          facts: null,
          problem: '그 요소를 찾지 못했어요. 페이지가 바뀌었을 수 있어요.'
        };
        target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' });
        return { ok: true, facts: null, problem: null };
      }
      const height = Math.max(1, Math.floor(window.innerHeight * 0.8));
      if (input.kind === 'down') window.scrollBy({ top: height, behavior: 'auto' });
      else if (input.kind === 'up') window.scrollBy({ top: -height, behavior: 'auto' });
      else if (input.kind === 'top') window.scrollTo({ top: 0, behavior: 'auto' });
      else if (input.kind === 'bottom') window.scrollTo({
        top: Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0),
        behavior: 'auto'
      });
      else return { ok: false, facts: null, problem: '지원하지 않는 스크롤이에요.' };
      return { ok: true, facts: null, problem: null };
    })()`
    try {
      return toActResult(await runGuestScript(() => frame.executeJavaScript(source)))
    } catch {
      return { ok: false, facts: null, problem: '페이지에서 스크롤하지 못했어요.' }
    }
  }

  async function hover(
    frameIndex: number,
    elementIndex: number
  ): Promise<ActResult> {
    const frame = deps.frames()[frameIndex]
    if (frame === undefined) {
      return { ok: false, facts: null, problem: '그 프레임을 찾지 못했어요.' }
    }
    const source = `(() => {
      ${TARGET_INDEX_SOURCE}
      const target = __bandalTargets()[${JSON.stringify(elementIndex)}] || null;
      if (!target) return {
        ok: false,
        facts: null,
        problem: '그 요소를 찾지 못했어요. 페이지가 바뀌었을 수 있어요.'
      };
      for (const type of ['pointerover', 'mouseover', 'mouseenter', 'mousemove']) {
        const EventClass = type === 'pointerover' && typeof PointerEvent === 'function'
          ? PointerEvent
          : MouseEvent;
        target.dispatchEvent(new EventClass(type, {
          bubbles: type !== 'mouseenter', cancelable: true, view: window
        }));
      }
      return { ok: true, facts: null, problem: null };
    })()`
    try {
      return toActResult(await runGuestScript(() => frame.executeJavaScript(source)))
    } catch {
      return { ok: false, facts: null, problem: '페이지에서 마우스를 올리지 못했어요.' }
    }
  }

  return { snapshot, read, act, factsFor, scroll, hover }
}

/** Picks the policy check for an action kind. */
export function verdictFor(
  kind: 'click' | 'type' | 'select',
  facts: ElementFacts
): ActionVerdict {
  if (kind === 'click') return canClick(facts)
  if (kind === 'type') return canType(facts)
  return canSelect(facts)
}
