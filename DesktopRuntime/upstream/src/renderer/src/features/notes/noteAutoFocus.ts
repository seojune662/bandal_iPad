/** Async editor creation must not undo a later choice of keyboard focus. */
export function canAutoFocusNote(root: HTMLElement, initialFocus: Element | null): boolean {
  if (!root.isConnected || root.getClientRects().length === 0) return false
  const { activeElement, body } = root.ownerDocument
  // Tabs own their arrow keys; focusing their editor would change those keys
  // into caret movement. A user already editing also owns their caret position.
  if (activeElement?.closest('[role="tab"]') || root.contains(activeElement)) return false
  return activeElement === initialFocus || activeElement === body
}
