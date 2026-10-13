import { createPageDriver, verdictFor } from '../upstream/src/main/features/browserAgent/pageDriver'
import { TARGET_INDEX_SOURCE } from '../upstream/src/main/features/browserAgent/snapshot'
import { resolveRef } from '../upstream/src/main/features/browserAgent/refs'

let captured: Element[] = []
let capturedGeneration = -1
let focused: Element | null = null
let focusGeneration = -1
let focusToken = 0
const targets = (): Element[] => (0, eval)(`(() => { ${TARGET_INDEX_SOURCE}; return __bandalTargets() })()`)
function facts(node: Element) {
  const tag = node.tagName.toLowerCase(), type = (node.getAttribute('type') || '').toLowerCase(), form = (node as HTMLInputElement).form ?? node.closest('form')
  return { tag, type: type || null, inNonGetForm: form ? (form.getAttribute('method') || 'get').toLowerCase() !== 'get' : false,
    href: tag === 'a' ? node.getAttribute('href') : null, disabled: Boolean((node as HTMLInputElement).disabled),
    formAction: form ? ((node as HTMLInputElement).hasAttribute('formaction') ? (node as HTMLInputElement).formAction : form.action) : null,
    formMethod: form ? (node.getAttribute('formmethod') ?? form.method).toLowerCase() : null,
    formTarget: form ? (node.getAttribute('formtarget') ?? form.target) : null }
}
async function run(input: { tool: string; generation: number; expectedUrl: string; ref?: string; action?: {kind:'click'|'type'|'select';text?:string;value?:string}; to?: any; maxChars?: number; expectedFacts?: unknown; approved?: boolean; focused?: boolean; focusToken?: number; key?: string; file?: {name:string;mimeType:string;dataBase64:string} }) {
  const samePage = (): void => { if (location.href !== input.expectedUrl) throw new Error('페이지가 변경되었습니다. 다시 살펴봐 주세요.') }
  samePage()
  const max = Math.max(500, Math.min(20000, input.maxChars ?? 6000))
  let resolved: {frameIndex: number; elementIndex: number} | undefined
  if (input.ref) {
    const value = resolveRef(input.ref, input.generation)
    if (!value.ok) throw new Error(value.message)
    if (value.frameIndex !== 0) throw new Error('iPad에서는 다른 출처의 내장 프레임을 자동으로 조작할 수 없습니다. 원문을 직접 열어 주세요.')
    resolved = value
  }
  const validateTarget = (): void => {
    if (!resolved) return
    const node = targets()[resolved.elementIndex]
    if (capturedGeneration !== input.generation || !node || captured[resolved.elementIndex] !== node) throw new Error('요소 순서가 변경되었습니다. 다시 살펴봐 주세요.')
    if (input.expectedFacts && Object.entries(facts(node)).some(([key,value]) => (input.expectedFacts as Record<string,unknown>)[key] !== value)) throw new Error('확인한 요소가 변경되었습니다. 다시 살펴봐 주세요.')
    if (input.tool === 'act' && input.action) {
      if (input.action.kind === 'click' && ((node instanceof HTMLButtonElement && node.form && node.type === 'submit') || (node instanceof HTMLInputElement && ['submit','image','file'].includes(node.type)))) throw new Error('제출 또는 파일 첨부는 별도 확인 후 진행해 주세요.')
      const verdict = verdictFor(input.action.kind, facts(node))
      if (!verdict.allowed) throw new Error(verdict.message)
    }
  }
  const driver = createPageDriver({ currentUrl: () => location.href, frames: () => [{ executeJavaScript: async source => {
    samePage(); validateTarget()
    // The identity/policy check and original action run synchronously in the
    // same isolated JS task. A page cannot insert a new ordinal between them.
    return (0, eval)(source)
  } }] })
  switch (input.tool) {
    case 'snapshot': {
      captured = targets(); capturedGeneration = input.generation
      const result = await driver.snapshot(input.generation, max)
      const current = targets()
      if (captured.length !== current.length || captured.some((node, index) => current[index] !== node)) throw new Error('페이지가 변경되었습니다. 다시 살펴봐 주세요.')
      return { status: 'ok', url: result.url, title: document.title, outline: result.outline, generation: input.generation }
    }
    case 'read': return {status:'ok', ...await driver.read(max), title:document.title, generation:input.generation}
    case 'inspect': {
      if (input.focused) {
        focused = document.activeElement; focusGeneration = input.generation; focusToken++
        return {status:'ok',url:location.href,generation:input.generation,focusToken,facts:focused ? facts(focused) : null}
      }
      validateTarget()
      return {status:'ok',url:location.href,generation:input.generation,...(resolved ? {facts:facts(targets()[resolved.elementIndex])} : {})}
    }
    case 'submit': {
      if (!input.approved || !input.expectedFacts || !resolved) throw new Error('이번 제출에 대한 확인이 필요합니다.')
      validateTarget()
      const node = targets()[resolved.elementIndex]
      if (!(node instanceof HTMLElement) || (node as HTMLInputElement).disabled ||
        !(node instanceof HTMLButtonElement || node instanceof HTMLInputElement && ['submit','image','button'].includes(node.type) || node.getAttribute('role') === 'button')) throw new Error('제출할 버튼을 다시 확인해 주세요.')
      node.click()
      return {status:'ok',url:location.href,title:document.title,semanticAction:'activate-approved-submit-control',navigated:location.href !== input.expectedUrl}
    }
    case 'attachFile': {
      if (!input.approved || !input.expectedFacts || !resolved || !input.file) throw new Error('파일 첨부 확인이 필요합니다.')
      validateTarget()
      const node = targets()[resolved.elementIndex], file = input.file
      if (!(node instanceof HTMLInputElement) || node.type !== 'file' || node.disabled) throw new Error('파일 입력 항목을 다시 확인해 주세요.')
      const raw = atob(file.dataBase64)
      if (raw.length > 25 * 1024 * 1024 || !file.name || file.name.includes('/') || file.name.includes('\\')) throw new Error('25MB 이하 파일을 선택해 주세요.')
      const bytes = Uint8Array.from(raw, value => value.charCodeAt(0)), transfer = new DataTransfer()
      transfer.items.add(new File([bytes], file.name, {type:file.mimeType}))
      node.files = transfer.files
      if (node.files.length !== 1 || node.files[0].size !== bytes.length || node.files[0].name !== file.name) throw new Error('이 페이지에 파일을 첨부하지 못했습니다.')
      node.dispatchEvent(new Event('input',{bubbles:true})); node.dispatchEvent(new Event('change',{bubbles:true}))
      return {status:'ok',url:location.href,title:document.title,attached:true,semanticAction:'set-file-input',submitted:false}
    }
    case 'key': {
      if (!input.expectedFacts || input.focusToken !== focusToken || input.generation !== focusGeneration || focused !== document.activeElement || !focused) throw new Error('입력 위치가 바뀌었습니다. 다시 확인해 주세요.')
      if (input.expectedFacts && Object.entries(facts(focused)).some(([key,value]) => (input.expectedFacts as Record<string,unknown>)[key] !== value)) throw new Error('입력 항목이 바뀌었습니다. 다시 확인해 주세요.')
      const action = semanticKey(focused, input.key, input.approved === true)
      return {status:'ok',url:location.href,title:document.title,semanticAction:action,navigated:location.href !== input.expectedUrl}
    }
    case 'act': {
      if (!resolved || !input.action || !['click','type','select'].includes(input.action.kind)) throw new Error('행동과 요소를 확인해 주세요.')
      if ((input.action.text?.length ?? 0) > 20000 || (input.action.value?.length ?? 0) > 20000) throw new Error('입력 길이가 너무 깁니다.')
      validateTarget()
      const result = await driver.act(0,resolved.elementIndex,input.action as any)
      if (!result.ok) throw new Error(result.problem ?? '행동이 반영되지 않았습니다.')
      return {status:'ok',url:location.href,title:document.title,navigated:location.href !== input.expectedUrl}
    }
    case 'scroll': {
      const target = resolved ? {kind:'ref' as const,frameIndex:0,elementIndex:resolved.elementIndex} : input.to
      if (!target || !['down','up','top','bottom','ref'].includes(target.kind)) throw new Error('스크롤 위치를 확인해 주세요.')
      const result = await driver.scroll(target)
      if (!result.ok) throw new Error(result.problem ?? '페이지를 이동하지 못했습니다.')
      return {status:'ok',url:location.href,title:document.title}
    }
    case 'hover': {
      if (!resolved) throw new Error('요소 참조가 없습니다.')
      const result = await driver.hover(0,resolved.elementIndex)
      if (!result.ok) throw new Error(result.problem ?? '요소를 확인하지 못했습니다.')
      return {status:'ok',url:location.href,title:document.title}
    }
    default: throw new Error('iPad 브라우저에서 지원하지 않는 동작입니다.')
  }
}

/** WK exposes no trusted keyboard synthesis API. Perform explicit DOM actions
 * with observable results and report their semantics, rather than claiming a
 * synthetic key event performed a browser default action. */
function semanticKey(node: Element, key: string | undefined, approved: boolean): string {
  if (key === 'Tab') {
    const candidates = Array.from(document.querySelectorAll<HTMLElement>('a[href],button,input,select,textarea,[tabindex]')).filter(item =>
      item.tabIndex >= 0 && !(item as HTMLInputElement).disabled && item.getBoundingClientRect().width > 0 && item.getBoundingClientRect().height > 0 && getComputedStyle(item).visibility !== 'hidden')
    const next = candidates[(candidates.indexOf(node as HTMLElement) + 1) % candidates.length]
    if (!next || next === node) throw new Error('다음 입력 항목이 없습니다.')
    next.focus(); if (document.activeElement !== next) throw new Error('입력 항목으로 이동하지 못했습니다.')
    return 'focus-next-element'
  }
  if (key === 'Escape') {
    const dialog = node.closest('dialog[open]')
    if (dialog instanceof HTMLDialogElement) { dialog.close(); return 'close-dialog' }
    if (node instanceof HTMLElement && node !== document.body) { node.blur(); if (document.activeElement !== node) return 'blur-active-element' }
    throw new Error('닫거나 입력을 해제할 항목이 없습니다.')
  }
  if (key === 'Enter') {
    if (!approved) throw new Error('Enter 동작을 실행하려면 이번 한 번의 확인이 필요합니다.')
    if (node instanceof HTMLTextAreaElement && !node.disabled && !node.readOnly) {
      node.setRangeText('\n',node.selectionStart,node.selectionEnd,'end'); node.dispatchEvent(new Event('input',{bubbles:true})); return 'insert-newline'
    }
    if (node instanceof HTMLButtonElement || node instanceof HTMLAnchorElement || node instanceof HTMLInputElement && ['button','submit','image'].includes(node.type)) {
      if ((node as HTMLInputElement).disabled) throw new Error('이 항목은 비활성 상태입니다.')
      node.click(); return 'activate-focused-control'
    }
    if (node instanceof HTMLInputElement && node.form && !node.disabled && node.type !== 'file') { node.form.requestSubmit(); return 'submit-focused-form' }
    throw new Error('이 입력 항목의 Enter 동작은 iPad에서 직접 실행해 주세요.')
  }
  if (!['ArrowUp','ArrowDown','ArrowLeft','ArrowRight'].includes(key ?? '')) throw new Error('지원하지 않는 키입니다.')
  if (node instanceof HTMLSelectElement && !node.disabled) {
    const direction = key === 'ArrowUp' || key === 'ArrowLeft' ? -1 : 1
    let next = node.selectedIndex + direction
    while (next >= 0 && next < node.options.length && node.options[next].disabled) next += direction
    if (next < 0 || next >= node.options.length) throw new Error('다음 선택 항목이 없습니다.')
    node.selectedIndex = next; node.dispatchEvent(new Event('input',{bubbles:true})); node.dispatchEvent(new Event('change',{bubbles:true})); return 'select-adjacent-option'
  }
  if ((node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement) && ['ArrowLeft','ArrowRight'].includes(key!) && node.selectionStart !== null && node.selectionEnd !== null && node.type !== 'password') {
    const before = key === 'ArrowLeft' ? node.selectionStart : node.selectionEnd
    const next = Math.max(0,Math.min(node.value.length,before + (key === 'ArrowLeft' ? -1 : 1)))
    if (next === before && node.selectionStart === node.selectionEnd) throw new Error('커서가 입력의 끝에 있습니다.')
    node.setSelectionRange(next,next); return 'move-text-caret'
  }
  if (node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement || (node instanceof HTMLElement && node.isContentEditable)) throw new Error('이 입력 항목의 방향키는 직접 사용해 주세요.')
  const scroller = document.scrollingElement
  if (!scroller) throw new Error('스크롤할 페이지가 없습니다.')
  const top = scroller.scrollTop, left = scroller.scrollLeft
  if (key === 'ArrowUp') scroller.scrollTop -= 40
  if (key === 'ArrowDown') scroller.scrollTop += 40
  if (key === 'ArrowLeft') scroller.scrollLeft -= 40
  if (key === 'ArrowRight') scroller.scrollLeft += 40
  if (top === scroller.scrollTop && left === scroller.scrollLeft) throw new Error('스크롤할 여백이 없습니다.')
  return 'scroll-document'
}
;(globalThis as any).__bandalBrowserAgent = run
