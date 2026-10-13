/**
 * What the agent may do to an element it can see.
 *
 * Pure, and separate from the code that performs the action, because these
 * are the rules that keep a poisoned page from turning a "read the syllabus"
 * request into a submitted form or a filled password field.
 *
 * ## Two rules that are structural, not conventional
 *
 * 1. **`browser_type` refuses password fields outright.** The login bridge
 *    proves "a human typed this" with `event.isTrusted` (`loginBridge.ts`),
 *    and only `browser_use_saved_login` — which goes through the native value
 *    setter, so its input is untrusted — may touch one. If typing could reach
 *    a password field, that proof would be worthless.
 *
 * 2. **Submitting is not available at this tier.** Not "gated": absent. On the
 *    web, submit is the whole set of irreversible acts — 과제 제출, 게시글,
 *    수강신청, 메시지, 결제 — and the always-prompt gate that will govern it
 *    does not exist yet. A click that would submit is refused with an
 *    explanation rather than performed, so the agent hands back to the student
 *    at exactly the point where a mistake would be permanent.
 */

/** The shape a snapshot reports for an element, and what a click resolves to. */
export interface ElementFacts {
  tag: string
  /** `type` attribute for inputs/buttons, lowercased. */
  type: string | null
  /** True when the element is inside a form whose method is not GET. */
  inNonGetForm: boolean
  /** href for anchors, when there is one. */
  href: string | null
  disabled: boolean
}

export type ActionVerdict =
  | { allowed: true }
  | { allowed: false; reason: ActionDenial; message: string }

export type ActionDenial =
  | 'disabled'
  | 'password'
  | 'submit'
  | 'not-typeable'
  | 'not-selectable'

const TYPEABLE_TAGS = new Set(['input', 'textarea'])
const NON_TEXT_INPUT_TYPES = new Set([
  'button',
  'submit',
  'reset',
  'image',
  'file',
  'checkbox',
  'radio'
])

/** Controls whose activation submits a form. */
function isSubmitControl(facts: ElementFacts): boolean {
  if (facts.type === 'submit' || facts.type === 'image') return true
  // A bare <button> inside a form defaults to type=submit.
  if (facts.tag === 'button' && facts.type === null && facts.inNonGetForm) {
    return true
  }
  return false
}

export function canClick(facts: ElementFacts): ActionVerdict {
  if (facts.disabled) {
    return {
      allowed: false,
      reason: 'disabled',
      message: '그 항목은 지금 누를 수 없는 상태예요.'
    }
  }
  if (isSubmitControl(facts)) {
    return {
      allowed: false,
      reason: 'submit',
      message:
        '제출은 반달이 대신 누르지 않습니다. 내용을 확인하고 직접 눌러 주세요.'
    }
  }
  return { allowed: true }
}

export function canType(facts: ElementFacts): ActionVerdict {
  if (facts.disabled) {
    return {
      allowed: false,
      reason: 'disabled',
      message: '그 칸은 지금 입력할 수 없는 상태예요.'
    }
  }
  if (facts.type === 'password') {
    return {
      allowed: false,
      reason: 'password',
      message:
        '비밀번호 칸에는 입력하지 않습니다. 저장된 로그인을 쓰거나 직접 입력해 주세요.'
    }
  }
  if (!TYPEABLE_TAGS.has(facts.tag)) {
    return {
      allowed: false,
      reason: 'not-typeable',
      message: '그 요소에는 글을 입력할 수 없어요.'
    }
  }
  if (
    facts.tag === 'input' &&
    facts.type !== null &&
    NON_TEXT_INPUT_TYPES.has(facts.type)
  ) {
    return {
      allowed: false,
      reason: 'not-typeable',
      message: '그 칸은 글을 입력하는 칸이 아니에요.'
    }
  }
  return { allowed: true }
}

export function canSelect(facts: ElementFacts): ActionVerdict {
  if (facts.disabled) {
    return {
      allowed: false,
      reason: 'disabled',
      message: '그 항목은 지금 선택할 수 없는 상태예요.'
    }
  }
  if (facts.tag !== 'select') {
    return {
      allowed: false,
      reason: 'not-selectable',
      message: '그 요소는 선택 목록이 아니에요.'
    }
  }
  return { allowed: true }
}
