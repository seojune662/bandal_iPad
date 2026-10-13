/** Renderer selection coordinates are display-local DIP, thumbnails are physical pixels. */
export function cropPixels(rect: { x: number; y: number; width: number; height: number }, viewport: { width: number; height: number }, image: { width: number; height: number }) {
  const sx = image.width / viewport.width, sy = image.height / viewport.height
  const x = Math.max(0, Math.min(image.width - 1, Math.floor(rect.x * sx)))
  const y = Math.max(0, Math.min(image.height - 1, Math.floor(rect.y * sy)))
  const right = Math.max(x + 1, Math.min(image.width, Math.ceil((rect.x + rect.width) * sx)))
  const bottom = Math.max(y + 1, Math.min(image.height, Math.ceil((rect.y + rect.height) * sy)))
  return { x, y, width: right - x, height: bottom - y }
}
