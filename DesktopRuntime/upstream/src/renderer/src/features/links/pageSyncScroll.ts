/**
 * Recognize the position we applied, rather than swallowing the next scroll
 * event for an arbitrary time. A wheel reversal can arrive before that event.
 * Keep the target until it actually changes (including duplicate scroll events).
 */
export class PageSyncScroll {
  private target: number | null = null
  private sequence = 0

  apply(scroller: Pick<HTMLElement, 'scrollTop'>, restore: () => void): void {
    restore()
    this.target = scroller.scrollTop // Use the browser's clamped position.
  }

  isEcho(scroller: Pick<HTMLElement, 'scrollTop'>): boolean {
    if (this.target === null) return false
    if (Math.abs(scroller.scrollTop - this.target) < 0.5) return true
    this.target = null
    return false
  }

  accept(sequence: number): boolean {
    if (sequence <= this.sequence) return false
    this.sequence = sequence
    return true
  }
}
