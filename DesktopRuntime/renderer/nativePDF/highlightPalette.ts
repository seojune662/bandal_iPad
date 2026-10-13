export type HighlightPalette = Record<string, number[]>

/** Resolve the original CSS theme (including oklch) through WebKit's color
 * renderer. Native annotation colors must not borrow the handwriting palette. */
export function readHighlightPalette(element: Element): HighlightPalette {
  const style = getComputedStyle(element), canvas = document.createElement('canvas')
  canvas.width = 1; canvas.height = 1
  const context = canvas.getContext('2d', { willReadFrequently: true })
  if (!context) return {}
  const result: HighlightPalette = {}
  for (const color of ['yellow', 'green', 'pink', 'blue']) {
    const value = style.getPropertyValue(`--highlight-${color}`).trim()
    if (!value) continue
    context.clearRect(0, 0, 1, 1); context.fillStyle = value; context.fillRect(0, 0, 1, 1)
    result[color] = [...context.getImageData(0, 0, 1, 1).data].map(channel => channel/255)
  }
  return result
}
