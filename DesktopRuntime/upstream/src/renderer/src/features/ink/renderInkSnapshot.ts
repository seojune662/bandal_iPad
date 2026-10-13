const SVG_NS = 'http://www.w3.org/2000/svg'
const OMIT = '.ink-layer__selection-frame, [class*="-resize"], .ink-layer__textbox-hit-target, .ink-layer__preview, .ink-layer__image-frame'
const PAINT = [
  'color', 'fill', 'stroke', 'stroke-width', 'stroke-linecap', 'stroke-linejoin',
  'opacity', 'mix-blend-mode', 'overflow', 'font-family', 'font-size', 'font-weight',
  'font-style', 'line-height', 'text-align', 'text-decoration', 'white-space',
  'overflow-wrap', 'word-break', 'letter-spacing', 'background-color',
  'box-sizing', 'padding', 'border-width', 'border-style', 'border-color',
  'border-radius', 'display', 'vertical-align'
]
const TEXT_PIXEL_LENGTHS = ['font-size', 'line-height', 'letter-spacing', 'padding', 'border-width', 'border-radius', 'width', 'height']

/** Lay out exported HTML at output resolution, never at the viewer's zoom. */
function normalizeTextObjects(svg: SVGSVGElement, outputWidth: number): void {
  for (const object of Array.from(svg.querySelectorAll<SVGForeignObjectElement>('.ink-layer__textbox-object'))) {
    const transform = /^scale\(([^)]+)\)$/.exec(object.getAttribute('transform') ?? '')
    const [scaleX, scaleY] = transform?.[1]?.trim().split(/[\s,]+/).map(Number) ?? []
    if (!scaleX || !scaleY || !Number.isFinite(scaleX) || !Number.isFinite(scaleY)) continue
    const factor = outputWidth * scaleX
    for (const attribute of ['x', 'y', 'width', 'height']) {
      const value = Number(object.getAttribute(attribute))
      if (Number.isFinite(value)) object.setAttribute(attribute, String(value * factor))
    }
    object.setAttribute('transform', `scale(${scaleX / factor} ${scaleY / factor})`)
    for (const element of Array.from(object.querySelectorAll<HTMLElement>('*'))) {
      for (const property of TEXT_PIXEL_LENGTHS) {
        const value = element.style.getPropertyValue(property)
        element.style.setProperty(property, value.replace(/(-?(?:\d*\.)?\d+(?:e[+-]?\d+)?)px/gi,
          (_, pixels: string) => `${Number(pixels) * factor}px`))
      }
    }
    const content = object.querySelector<HTMLElement>('.ink-layer__textbox')
    if (content) { content.style.width = '100%'; content.style.height = '100%' }
  }
}

function blobUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(new Error('이미지를 읽지 못했어요.'))
    reader.readAsDataURL(blob)
  })
}

async function dataUrl(url: string, signal: AbortSignal): Promise<string> {
  signal.throwIfAborted()
  // Local drawing images already arrive through IPC as data URLs. Fetching
  // those again is unnecessary and is blocked by the renderer's connect-src.
  if (url.startsWith('data:')) return url
  const response = await fetch(url, { signal })
  if (!response.ok) throw new Error('필기의 이미지를 불러오지 못했어요.')
  return blobUrl(await response.blob())
}

function containsCharacter(text: string, range: string): boolean {
  if (!range) return true
  return range.split(',').some((part) => {
    const [from, to] = part.trim().replace(/^U\+/i, '').split('-')
    if (!from) return false
    const min = parseInt(from.replace(/\?/g, '0'), 16)
    const max = parseInt((to ?? from).replace(/\?/g, 'F'), 16)
    return [...text].some((char) => { const cp = char.codePointAt(0)!; return cp >= min && cp <= max })
  })
}

/** Image-mode SVG cannot fetch web fonts: embed only the subsets used here. */
async function embedFonts(text: string, families: Set<string>, signal: AbortSignal): Promise<string> {
  const rules: CSSFontFaceRule[] = []
  const visit = (list: CSSRuleList): void => {
    for (const rule of Array.from(list)) {
      if (rule instanceof CSSFontFaceRule) rules.push(rule)
      else if ('cssRules' in rule) visit((rule as CSSGroupingRule).cssRules)
    }
  }
  for (const sheet of Array.from(document.styleSheets)) {
    try { visit(sheet.cssRules) } catch { /* Cross-origin styles do not supply our ink font. */ }
  }
  const needed = rules.filter((rule) => {
    const family = rule.style.getPropertyValue('font-family').replace(/["']/g, '').trim()
    return [...families].some((value) => value.replace(/["']/g, '').split(',').some((part) => part.trim() === family)) &&
      containsCharacter(text, rule.style.getPropertyValue('unicode-range'))
  })
  return (await Promise.all(needed.map(async (rule) => {
    let css = rule.cssText
    let src = rule.style.getPropertyValue('src')
    const urls = [...css.matchAll(/url\(["']?([^"')]+)["']?\)/g)]
    for (const match of urls) {
      const url = new URL(match[1]!, rule.parentStyleSheet?.href ?? document.baseURI).href
      const data = await dataUrl(url, signal)
      const embedded = `url("${data}")`
      css = css.replace(match[0], embedded)
      src = src.replace(match[0], embedded)
    }
    // A one-shot SVG raster cannot repaint after font-display:swap replaces a
    // fallback. Decode the same embedded font first, then block fallback paint.
    const font = new FontFace(rule.style.getPropertyValue('font-family').replace(/["']/g, ''), src, {
      weight: rule.style.getPropertyValue('font-weight') || 'normal',
      style: rule.style.getPropertyValue('font-style') || 'normal',
      stretch: rule.style.getPropertyValue('font-stretch') || 'normal',
      unicodeRange: rule.style.getPropertyValue('unicode-range') || 'U+0-10FFFF',
      display: 'block'
    })
    await font.load()
    signal.throwIfAborted()
    css = css.replace(/font-display\s*:[^;}]+/g, 'font-display: block')
    return css
  }))).join('\n')
}

/** Freeze current ink and PDF text highlights before menu focus commits text. */
export function captureInkSnapshot(page: HTMLElement): ((paper: HTMLCanvasElement, signal: AbortSignal) => Promise<HTMLImageElement>) | null {
  if (page.querySelector('.ink-layer__image-placeholder, .ink-layer__clip-placeholder, .pdf-drawing-layer.is-loading')) {
    throw new Error('필기와 이미지를 모두 불러온 뒤 다시 복사해 주세요.')
  }
  const highlights = Array.from(page.querySelectorAll<HTMLElement>('.pdf-highlight'))
  const source = page.querySelector<SVGSVGElement>('.pdf-drawing-layer') ?? document.createElementNS(SVG_NS, 'svg')
  if (!source.childElementCount && !highlights.length) return null
  const clone = source.cloneNode(true) as SVGSVGElement
  clone.setAttribute('viewBox', '0 0 1 1')
  clone.setAttribute('preserveAspectRatio', 'none')
  const originals = [source, ...Array.from(source.querySelectorAll('*'))]
  const copies = [clone, ...Array.from(clone.querySelectorAll('*'))]
  const images: ((signal: AbortSignal) => Promise<void>)[] = []
  const families = new Set<string>()
  for (let index = 0; index < originals.length; index++) {
    const original = originals[index]!, copy = copies[index] as HTMLElement | SVGElement
    const style = getComputedStyle(original)
    for (const property of PAINT) copy.style.setProperty(property, style.getPropertyValue(property))
    if (original instanceof HTMLElement) {
      families.add(style.fontFamily)
      copy.style.width = style.width
      copy.style.height = style.height
    }
    if (original.matches('.ink-layer__textbox')) {
      // CSS resolves a subpixel border to a device pixel on Windows. Keep the
      // authored em inset so exporting does not amplify that zoom rounding.
      const inline = (original as HTMLElement).style
      if (inline.padding) copy.style.padding = inline.padding
      if (inline.borderWidth) copy.style.borderWidth = inline.borderWidth
      copy.style.borderColor = 'transparent'
      copy.style.boxShadow = 'none'
      // Editing adds a panel-colored background, which is not part of the note.
      copy.style.background = original.hasAttribute('data-fill') ? style.getPropertyValue('--textbox-fill') : 'transparent'
    }
    if (original instanceof HTMLImageElement) {
      const url = original.currentSrc || original.src
      images.push((signal) => dataUrl(url, signal).then((value) => { (copy as HTMLImageElement).src = value }))
    }
    if (original instanceof SVGImageElement) {
      const url = original.href.baseVal
      images.push((signal) => dataUrl(url, signal).then((value) => { copy.setAttribute('href', value) }))
    }
    copy.removeAttribute('contenteditable')
    copy.removeAttribute('tabindex')
  }
  clone.querySelectorAll(OMIT).forEach((node) => node.remove())
  const highlightLayer = document.createElementNS(SVG_NS, 'g')
  for (const highlight of highlights) {
    const rect = document.createElementNS(SVG_NS, 'rect')
    for (const [attribute, property] of [['x', 'left'], ['y', 'top'], ['width', 'width'], ['height', 'height']]) {
      rect.setAttribute(attribute!, String(parseFloat(highlight.style.getPropertyValue(property!)) / 100))
    }
    rect.setAttribute('fill', getComputedStyle(highlight).backgroundColor)
    // Hover, selection and flash opacity belong to editor chrome.
    rect.setAttribute('opacity', '.42')
    rect.style.mixBlendMode = 'multiply'
    highlightLayer.append(rect)
  }
  clone.prepend(highlightLayer)
  const text = source.textContent ?? ''
  return async (paper, signal) => {
    signal.throwIfAborted()
    clone.setAttribute('width', String(paper.width))
    clone.setAttribute('height', String(paper.height))
    clone.style.cssText = 'overflow:hidden'
    normalizeTextObjects(clone, paper.width)
    const [fonts] = await Promise.all([embedFonts(text, families, signal), Promise.all(images.map((load) => load(signal)))])
    signal.throwIfAborted()
    const blob = await new Promise<Blob>((resolve, reject) => paper.toBlob((value) => value ? resolve(value) : reject(new Error('페이지를 읽지 못했어요. 다시 시도해 주세요.')), 'image/png'))
    const backdrop = document.createElementNS(SVG_NS, 'image')
    backdrop.setAttribute('href', await blobUrl(blob))
    backdrop.setAttribute('width', '1')
    backdrop.setAttribute('height', '1')
    backdrop.setAttribute('preserveAspectRatio', 'none')
    // Put paper inside the SVG so multiply ink blends with original text.
    clone.prepend(backdrop)
    if (fonts) {
      const style = document.createElementNS(SVG_NS, 'style')
      style.textContent = fonts
      clone.prepend(style)
    }
    signal.throwIfAborted()
    const image = new Image()
    const cancel = (): void => image.removeAttribute('src')
    signal.addEventListener('abort', cancel, { once: true })
    try {
      // Data URLs keep foreignObject SVG origin-clean in Chromium.
      image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(clone))}`
      await image.decode()
      signal.throwIfAborted()
      return image
    } catch (error) {
      cancel()
      throw error
    } finally {
      signal.removeEventListener('abort', cancel)
    }
  }
}
