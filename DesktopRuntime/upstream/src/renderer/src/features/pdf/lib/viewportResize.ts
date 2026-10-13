import type { PdfViewportAnchor } from '../useVisiblePages'

export interface PdfResizeGeometry {
  width: number
  height: number
  pageWidth: number
}

/** One semantic anchor owns the entire reflow, including delayed page renders. */
export class PdfViewportResize {
  private retained: PdfViewportAnchor | null = null
  private target: PdfResizeGeometry | null = null
  private stableFrames = 0
  private restoredScrollTop: number | null = null

  get anchor(): PdfViewportAnchor | null { return this.retained }

  begin(anchor: PdfViewportAnchor | null, target: PdfResizeGeometry): void {
    this.retained ??= anchor
    this.target = target
    this.stableFrames = 0
  }

  /** A viewport alone can be stable while React still displays old page boxes. */
  observe(geometry: PdfResizeGeometry): boolean {
    const target = this.target
    if (target === null || geometry.width !== target.width ||
      geometry.height !== target.height || Math.abs(geometry.pageWidth - target.pageWidth) >= 0.5) {
      this.stableFrames = 0
      return false
    }
    if (++this.stableFrames < 3) return false
    this.retained = null
    this.target = null
    return true
  }

  recordRestoredScroll(scrollTop: number): void { this.restoredScrollTop = scrollTop }

  isScrollEcho(scrollTop: number): boolean {
    return this.restoredScrollTop !== null && Math.abs(scrollTop - this.restoredScrollTop) < 0.5
  }

  /** Real navigation takes ownership immediately, even during an animation. */
  cancel(): void {
    this.retained = null
    this.target = null
    this.stableFrames = 0
    this.restoredScrollTop = null
  }
}
