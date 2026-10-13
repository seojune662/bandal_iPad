export interface PDFFrame { x: number; y: number; width: number; height: number }

/** Only explicit HTML text editing uses this affine projection. Native ink,
 * PDF navigation and object persistence never depend on a DOM measurement. */
export function editorTransform(page: PDFFrame, native: PDFFrame, viewport: Pick<PDFFrame, 'x' | 'y'>, baseX: number, baseY: number): string | null {
  if (![page.x,page.y,page.width,page.height,native.x,native.y,native.width,native.height,viewport.x,viewport.y,baseX,baseY].every(Number.isFinite)
    || [page.width,page.height,native.width,native.height,baseX,baseY].some(value => value <= 0)) return null
  return `matrix(${native.width/page.width*baseX} 0 0 ${native.height/page.height*baseY} ${(viewport.x+native.x-page.x)/page.width} ${(viewport.y+native.y-page.y)/page.height})`
}

export class NativePDFEditorGeometry {
  private originals = new Map<SVGForeignObjectElement, { original: string; applied: string }>()
  apply(editor: HTMLElement, native: PDFFrame, viewport: Pick<PDFFrame, 'x'|'y'>): void {
    const object = editor.closest('foreignObject'), page = editor.closest<HTMLElement>('[data-pdf-page]')
    if (!(object instanceof SVGForeignObjectElement) || !page) return
    const previous = this.originals.get(object), current = object.getAttribute('transform') ?? ''
    const original = previous && current === previous.applied ? previous.original : current
    const scale = /^scale\(\s*([-+\deE.]+)[ ,]+([-+\deE.]+)\s*\)$/.exec(original)
    if (!scale) return
    const rect = page.getBoundingClientRect()
    const applied = editorTransform(rect, native, viewport, Number(scale[1]), Number(scale[2]))
    if (!applied) return
    this.originals.set(object, { original, applied })
    if (current !== applied) object.setAttribute('transform', applied)
  }
  prune(): void {
    for (const [object, value] of this.originals) {
      if (object.isConnected && object.querySelector('.ink-layer__textbox-editor')) continue
      if (object.getAttribute('transform') === value.applied) object.setAttribute('transform', value.original)
      this.originals.delete(object)
    }
  }
  dispose(): void {
    for (const [object, value] of this.originals) if (object.getAttribute('transform') === value.applied) object.setAttribute('transform', value.original)
    this.originals.clear()
  }
}
