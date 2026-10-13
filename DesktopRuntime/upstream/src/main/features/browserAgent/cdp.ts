/**
 * The Chrome DevTools Protocol, used for exactly three things.
 *
 * CDP is the LAST rung of the ladder, not the first. Most of what this agent
 * does never touches it: an LMS list comes from a JSON endpoint, and a click
 * comes from injected JS in an isolated world. It is here only for capability
 * gaps that genuinely have no DOM-tier equivalent:
 *
 *  1. **`Input.insertText` for Hangul.** `sendInputEvent` has no IME path.
 *     Synthesising `char` events for 한글 either produces mojibake or nothing
 *     at all on any site that listens for `compositionend`. This one gap is
 *     what decides CDP over `sendInputEvent`.
 *  2. **`DOM.setFileInputFiles`.** JavaScript cannot set
 *     `input[type=file].files` from an OS path. There is no substitute.
 *  3. **Trusted `Input.dispatchMouseEvent`**, for the minority of controls
 *     that check `event.isTrusted` or need real hit-testing.
 *
 * ## It is not a privilege escalation, and the comment matters
 *
 * Main already has strictly more power over a guest than CDP grants: it can
 * `executeJavaScript` arbitrary code in it (`loginFiller.ts` does exactly
 * that, holding a password), read and write its cookies, `loadURL` it
 * anywhere, and destroy it. Attaching a debugger changes no `webPreferences`,
 * re-enables no `nodeIntegration`, defeats no `webSecurity`, reaches outside
 * no partition, and cannot be initiated by the guest.
 *
 * ## The one thing it DOES change, and how that is contained
 *
 * CDP-dispatched input has `isTrusted === true`. `loginBridge.ts` uses exactly
 * that property to prove a human typed a password. So `browser_type` refuses
 * password fields outright (`actionPolicy.ts`) and only
 * `browser_use_saved_login` may touch one — and that path goes through
 * `createLoginFiller`, whose native-value-setter writes are UNtrusted and
 * therefore cannot poison the capture gate.
 *
 * ## Attachment is per action
 *
 * Never held across a navigation, always detached in `finally`, and skipped
 * entirely when DevTools is already attached (only one debugger client is
 * allowed, and stealing it from a student who opened DevTools would be rude
 * and confusing). Callers degrade to the DOM tier rather than failing.
 */

import { randomUUID } from 'node:crypto'
import { TARGET_INDEX_SOURCE } from './snapshot'
import { runGuestScript } from './pageDriver'

export interface DebuggerLike {
  isAttached: () => boolean
  attach: (protocolVersion?: string) => void
  detach: () => void
  sendCommand: (method: string, params?: object) => Promise<unknown>
}

export interface CdpTarget {
  debugger: DebuggerLike
}

/** Signals that CDP was unavailable, so the caller can fall back. */
export class CdpUnavailable extends Error {
  constructor(reason: string) {
    super(reason)
    this.name = 'CdpUnavailable'
  }
}

/**
 * Attaches, runs, and detaches — in that order, with the detach guaranteed.
 *
 * Returns whatever `fn` returns. Throws `CdpUnavailable` when the debugger
 * cannot be attached, which callers treat as "use the DOM tier", not as a
 * failure of the action.
 */
export async function withDebugger<T>(
  target: CdpTarget,
  fn: (send: (method: string, params?: object) => Promise<unknown>) => Promise<T>
): Promise<T> {
  const dbg = target.debugger

  // Someone else — almost certainly the student's own DevTools — already owns
  // it. Only one client may attach.
  if (dbg.isAttached()) {
    throw new CdpUnavailable('debugger already attached')
  }

  try {
    dbg.attach('1.3')
  } catch (error) {
    throw new CdpUnavailable(
      error instanceof Error ? error.message : 'attach failed'
    )
  }

  try {
    return await fn((method, params) => dbg.sendCommand(method, params))
  } finally {
    try {
      dbg.detach()
    } catch {
      // Already gone (the page navigated, the guest died). Nothing to do, and
      // certainly nothing worth masking the real result with.
    }
  }
}

/**
 * Types text as if the IME committed it.
 *
 * `Input.insertText` is the whole reason CDP is here. It bypasses key-event
 * synthesis entirely, which is what makes 한글 work.
 */
export async function insertText(
  target: CdpTarget,
  text: string
): Promise<void> {
  await withDebugger(target, async (send) => {
    await send('Input.insertText', { text })
  })
}

/** Resolve the same visible-element ordinal as the snapshot, in its frame. */
export async function setFileInputFiles(
  target: CdpTarget,
  frame: { executeJavaScript(code: string): Promise<unknown> },
  elementIndex: number,
  paths: readonly string[]
): Promise<boolean> {
  if (!Number.isSafeInteger(elementIndex) || elementIndex < 0) return false
  const marker = `data-bandal-upload-${randomUUID()}`
  const attribute = JSON.stringify(marker)
  try {
    const marked = await runGuestScript(() => frame.executeJavaScript(`(() => {
      ${TARGET_INDEX_SOURCE}
      const target = __bandalTargets()[${elementIndex}];
      if (!(target instanceof HTMLInputElement) || target.type !== 'file' || target.disabled) return false;
      target.setAttribute(${attribute}, '');
      return true;
    })()`))
    if (marked !== true) return false
    return await withDebugger(target, async (send) => {
      // Include iframe documents. Never fall back to an unrelated input if
      // Chromium cannot expose a child frame to this debugger target.
      interface Node { nodeId?: number; nodeName?: string; attributes?: string[]; children?: Node[]; contentDocument?: Node; shadowRoots?: Node[] }
      const document = await runGuestScript(() => send('DOM.getDocument', { depth: -1, pierce: true })) as { root?: Node }
      const matches: number[] = []
      const visit = (node: Node): void => {
        const attrs = node.attributes ?? []
        const hasAttribute = (name: string, value?: string): boolean => attrs.some((attr, index) => index % 2 === 0 && attr === name && (value === undefined || attrs[index + 1]?.toLowerCase() === value))
        if (node.nodeName === 'INPUT' && hasAttribute(marker) && hasAttribute('type', 'file') && !hasAttribute('disabled') && typeof node.nodeId === 'number' && node.nodeId > 0) matches.push(node.nodeId)
        for (const child of node.children ?? []) visit(child)
        for (const child of node.shadowRoots ?? []) visit(child)
        if (node.contentDocument) visit(node.contentDocument)
      }
      if (document.root) visit(document.root)
      if (matches.length !== 1) return false
      await runGuestScript(() => send('DOM.setFileInputFiles', { nodeId: matches[0], files: [...paths] }))
      return true
    })
  } finally {
    try { await runGuestScript(() => frame.executeJavaScript(`document.querySelectorAll('[${marker}]').forEach(el => el.removeAttribute(${attribute}))`)) }
    catch { /* The original frame may have navigated or closed. */ }
  }
}
