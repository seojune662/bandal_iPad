/**
 * 키보드 단축키가 입력 필드를 침범하지 않게 하는 공용 판정.
 * 툴레일들(CanvasToolRail 등)이 각자 들고 있던 패턴의 단일화 지점.
 */
export function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  return (
    target.tagName === 'INPUT' ||
    target.tagName === 'TEXTAREA' ||
    target.isContentEditable
  )
}
