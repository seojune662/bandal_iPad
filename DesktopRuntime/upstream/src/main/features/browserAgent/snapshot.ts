/**
 * What the agent is shown of a page.
 *
 * NOT the DOM, and NOT `Accessibility.getFullAXTree`. A Korean 학사 포털 is
 * nested `<table>` layout with `<font>` tags and no `<label>`s; an accessibility
 * tree of one is fifteen thousand `generic`/`StaticText` nodes with no
 * accessible names — the worst possible trade, expensive AND uninformative.
 *
 * Instead: a flat, ref-indexed outline of the things a student could act on,
 * plus the text around them, hard-capped. One line per element:
 *
 *   f0:e12@3 link "3주차 강의자료" → /mod/resource/view.php?id=88213
 *   f0:e21@3 button "주차 접기"
 *   f2:e04@3 textbox "아이디" (empty, required)
 *
 * ## Why it runs in an isolated world
 *
 * Guests get no preload by policy (`hardenWebviews`), so the existing bridges
 * inject into the MAIN world and exfiltrate through a prefixed `console.log`
 * — which the page can read, tamper with, and forge. For the agent path that
 * is not good enough, so this runs via `executeJavaScriptInIsolatedWorld`,
 * where the page cannot see it, and the value comes back on the promise.
 */

/** Default budget. A snapshot is context, not a document. */
export const DEFAULT_SNAPSHOT_CHARS = 6_000
export const MAX_SNAPSHOT_CHARS = 20_000

export interface SnapshotElement {
  /** Index within its frame, used to build the ref. */
  index: number
  role:
    | 'link'
    | 'button'
    | 'tab'
    | 'menuitem'
    | 'textbox'
    | 'select'
    | 'checkbox'
    | 'heading'
    | 'text'
  name: string
  href: string | null
  /** Element facts the action policy needs, carried so a click need not re-read. */
  tag: string
  type: string | null
  inNonGetForm: boolean
  disabled: boolean
  value: string | null
  required: boolean
  /** Select choices as the student sees them, capped page-side. */
  options?: { value: string; label: string }[]
  /** Original option count, so a capped list can say how much is missing. */
  optionCount?: number
}

export interface FrameSnapshot {
  frameIndex: number
  url: string
  elements: SnapshotElement[]
  /** Named, visible candidates left out by the page-side element cap. */
  omittedElementCount?: number
}

/**
 * The ONE definition of which elements the agent can address, and in what
 * order.
 *
 * This used to exist in three copies — the snapshot collector, the \`act\`
 * locator, and the submit locator — and they drifted. The snapshot filtered
 * \`opacity: 0\` and the others did not, so a single faded element shifted
 * every ordinal by one and a click landed on the row NEXT to the one the
 * model meant, reporting success. Widening the snapshot's selector without
 * the others would have broken it far worse.
 *
 * So the enumeration is defined once, as source, and injected by everything
 * that needs it. A ref is an ordinal into \`__bandalTargets()\`; if this
 * function is the only thing that produces that order, the copies cannot
 * disagree.
 */
const TARGET_SELECTOR = 'a, button, input, select, textarea, h1, h2, h3, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [onclick], label, summary'

/** Page-side prelude defining \`__bandalTargets()\`. Injected, never imported. */
export const TARGET_INDEX_SOURCE = `
  const visible = (el) => {
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    if (Number(style.opacity) === 0) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };

  const textOf = (node, max = 120) => {
    const text = (node && node.textContent ? node.textContent : '')
      .replace(/\\s+/g, ' ')
      .trim();
    return text.slice(0, max);
  };

  const labelledByName = (el) => {
    const ids = (el.getAttribute('aria-labelledby') || '').trim().split(/\\s+/).filter(Boolean);
    if (ids.length === 0) return '';
    return ids.map((id) => textOf(document.getElementById(id))).filter(Boolean).join(' ').slice(0, 120);
  };

  // Korean portals commonly put a select after a th/td heading cell, or
  // directly after a text node, without a real label.
  const nearbySelectName = (el) => {
    let sibling = el.previousSibling;
    while (sibling) {
      const text = textOf(sibling, 60);
      if (text) return text;
      sibling = sibling.previousSibling;
    }
    const parent = el.parentElement;
    if (parent) {
      const previousCell = parent.previousElementSibling;
      const text = textOf(previousCell, 60);
      if (text) return text;
    }
    return '';
  };

  const nameOf = (el) => {
    const aria = el.getAttribute('aria-label');
    if (aria && aria.trim()) return aria.trim();
    if (el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA') {
      const id = el.getAttribute('id');
      if (id) {
        const label = document.querySelector('label[for="' + CSS.escape(id) + '"]');
        const labelText = textOf(label);
        if (labelText) return labelText;
      }
      const wrapping = el.closest('label');
      const wrappingText = textOf(wrapping);
      if (wrappingText) return wrappingText;
      const labelledBy = labelledByName(el);
      if (labelledBy) return labelledBy;
      if (el.tagName === 'SELECT') {
        const nearby = nearbySelectName(el);
        if (nearby) return nearby;
      }
      const placeholder = el.getAttribute('placeholder');
      if (placeholder && placeholder.trim()) return placeholder.trim();
      const name = el.getAttribute('name');
      if (name) return name;
      return '';
    } else {
      const labelledBy = labelledByName(el);
      if (labelledBy) return labelledBy;
    }
    return textOf(el);
  };

  const inNonGetForm = (el) => {
    const form = el.closest('form');
    if (!form) return false;
    return (form.getAttribute('method') || 'get').toLowerCase() !== 'get';
  };

  const roleOf = (el) => {
    const tag = el.tagName.toLowerCase();
    const explicitRole = (el.getAttribute('role') || '').toLowerCase();
    if (explicitRole === 'button' || explicitRole === 'link' || explicitRole === 'tab' ||
        explicitRole === 'menuitem' || explicitRole === 'checkbox') return explicitRole;
    if (tag === 'a') return 'link';
    if (tag === 'button') return 'button';
    if (tag === 'summary') return 'button';
    if (tag === 'select') return 'select';
    if (tag === 'textarea') return 'textbox';
    if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (type === 'checkbox' || type === 'radio') return 'checkbox';
      if (type === 'button' || type === 'submit' || type === 'reset' || type === 'image') {
        return 'button';
      }
      return 'textbox';
    }
    if (/^h[1-6]$/.test(tag)) return 'heading';
    if (el.hasAttribute('onclick')) return 'button';
    return 'text';
  };

  const __bandalTargets = () => {
    const seenTargets = new Set();
    const targets = [];
    document.querySelectorAll('${TARGET_SELECTOR}').forEach((el) => {
      if (seenTargets.has(el)) return;
      if (!visible(el)) return;
      seenTargets.add(el);
      // Nameless rows consume context without telling the model what it can
      // use — and they must be skipped HERE so every consumer skips them.
      if (!nameOf(el)) return;
      targets.push(el);
    });
    return targets;
  };
`

/**
 * The page-side collector, as source. Kept as a string because it is injected,
 * not imported — it runs in the guest's isolated world, not in main.
 *
 * Deliberately conservative about what counts as actionable: an outline that
 * lists every `<div>` is the DOM dump this exists to avoid.
 */
export const SNAPSHOT_SOURCE = `(() => {
  const MAX_ELEMENTS = 250;
  const MAX_OPTIONS = 20;
  const out = [];
  let omittedElementCount = 0;

${TARGET_INDEX_SOURCE}

  const collect = (el) => {
    // Visibility, dedup and the nameless skip already happened in
    // __bandalTargets — doing them again here is how the copies drifted.
    const name = nameOf(el);
    if (out.length >= MAX_ELEMENTS) {
      omittedElementCount += 1;
      return;
    }
    const tag = el.tagName.toLowerCase();
    const type = el.getAttribute ? (el.getAttribute('type') || '').toLowerCase() : '';
    const selectOptions = tag === 'select' ? Array.from(el.options || []) : [];
    out.push({
      index: out.length,
      role: roleOf(el),
      name,
      href: tag === 'a' ? el.getAttribute('href') : null,
      tag: tag,
      type: type === '' ? null : type,
      inNonGetForm: inNonGetForm(el),
      disabled: Boolean(el.disabled),
      // Never report the contents of a password field, not even its length.
      value: type === 'password' ? null : (el.value == null ? null : String(el.value).slice(0, 80)),
      required: Boolean(el.required),
      options: tag === 'select'
        ? selectOptions.slice(0, MAX_OPTIONS).map((option) => ({
            value: String(option.value),
            label: String(option.label || option.textContent || '')
              .replace(/\\s+/g, ' ')
              .trim()
              .slice(0, 60)
          }))
        : undefined,
      optionCount: tag === 'select' ? selectOptions.length : undefined
    });
  };

  __bandalTargets().forEach(collect);

  return { url: location.href, elements: out, omittedElementCount };
})()`

/** Renders one frame's elements as the lines the model sees. */
export function renderSnapshot(
  frames: readonly FrameSnapshot[],
  generation: number,
  maxChars: number = DEFAULT_SNAPSHOT_CHARS
): string {
  const budget = Math.min(Math.max(maxChars, 500), MAX_SNAPSHOT_CHARS)
  const lines: string[] = []
  let used = 0
  let currentFrameElementsOmitted = 0
  let currentFrameCappedElements = 0
  let wholeFramesOmitted = 0
  let budgetTruncated = false

  const pushWithinBudget = (line: string): boolean => {
    const cost = line.length + (lines.length === 0 ? 0 : 1)
    if (used + cost > budget) return false
    lines.push(line)
    used += cost
    return true
  }

  for (const [framePosition, frame] of frames.entries()) {
    currentFrameCappedElements = frame.omittedElementCount ?? 0
    const header = renderFrameHeader(frame)
    if (!pushWithinBudget(header)) {
      budgetTruncated = true
      wholeFramesOmitted = frames.length - framePosition
      break
    }

    for (const [elementPosition, element] of frame.elements.entries()) {
      const line = renderElement(frame.frameIndex, element, generation)
      if (!pushWithinBudget(line)) {
        budgetTruncated = true
        currentFrameElementsOmitted = frame.elements.length - elementPosition
        wholeFramesOmitted = frames.length - framePosition - 1
        break
      }
    }
    if (budgetTruncated) break

    const omitted = frame.omittedElementCount ?? 0
    if (omitted > 0) {
      const notice = `(이 프레임에서 ${omitted}개 더 있는데 생략했어요)`
      const cost = notice.length + (lines.length === 0 ? 0 : 1)
      lines.push(notice)
      used += cost
    }
  }

  if (budgetTruncated) {
    if (currentFrameElementsOmitted > 0) {
      lines.push(`(문자 예산 때문에 이 프레임 요소 ${currentFrameElementsOmitted}개를 더 보여주지 못했어요)`)
    }
    if (currentFrameElementsOmitted > 0 && currentFrameCappedElements > 0) {
      lines.push(
        `(이 프레임에서 ${currentFrameCappedElements}개 더 있는데 생략했어요)`
      )
    }
    if (wholeFramesOmitted > 0) {
      lines.push(`(프레임 ${wholeFramesOmitted}개를 더 보여주지 못했어요 — maxChars를 올려 보세요)`)
    } else if (currentFrameElementsOmitted === 0) {
      lines.push('(문자 예산 때문에 일부 정보를 더 보여주지 못했어요)')
    }
  }
  return lines.join('\n')
}

function renderFrameHeader(frame: FrameSnapshot): string {
  const address = frame.url === '' ? '(주소 없음)' : frame.url
  return `[f${frame.frameIndex}] ${address} (요소 ${frame.elements.length}개)`
}

function renderElement(
  frameIndex: number,
  element: SnapshotElement,
  generation: number
): string {
  const ref = `f${frameIndex}:e${element.index}@${generation}`
  const name = element.name === '' ? '' : ` "${element.name}"`
  const parts = [`${ref} ${element.role}${name}`]
  if (element.href !== null && element.href !== '') {
    parts.push(`→ ${element.href}`)
  }
  const flags: string[] = []
  if (element.disabled) flags.push('disabled')
  if (element.required) flags.push('required')
  if (element.type === 'password') flags.push('password')
  if (element.value !== null && element.value !== '') {
    flags.push(`value=${JSON.stringify(element.value)}`)
  }
  if (flags.length > 0) parts.push(`(${flags.join(', ')})`)
  if (element.options !== undefined) {
    const visibleOptions = element.options.slice(0, 20)
    const renderedOptions = visibleOptions.map(({ value, label }) =>
      label === value ? label : `${label}=${value}`
    )
    const totalOptions = Math.max(
      element.optionCount ?? element.options.length,
      element.options.length
    )
    const omitted = totalOptions - visibleOptions.length
    const suffix = omitted > 0 ? ` | …외 ${omitted}개` : ''
    parts.push(`[옵션 ${renderedOptions.join(' | ')}${suffix}]`)
  }
  return parts.join(' ')
}

/** Text of the page for `browser_read`, with the same hard cap. */
export const READ_SOURCE = `(() => {
  const text = (document.body ? document.body.innerText : '') || '';
  return { url: location.href, text: text.replace(/\\n{3,}/g, '\\n\\n') };
})()`
