import type { PalettePosition } from './preferences'
export interface Frame { left: number; top: number; width: number; height: number }
const margin = 12
export function clampPalette(viewport: Frame, size: Pick<Frame, 'width' | 'height'>, position: PalettePosition): { left: number; top: number } {
  return { left: viewport.left + margin + Math.max(0, viewport.width - size.width - margin * 2) * position.x,
    top: viewport.top + margin + Math.max(0, viewport.height - size.height - margin * 2) * position.y }
}
export function relativePalette(viewport: Frame, size: Pick<Frame, 'width' | 'height'>, point: { left: number; top: number }): PalettePosition {
  const width = Math.max(0, viewport.width - size.width - margin * 2), height = Math.max(0, viewport.height - size.height - margin * 2)
  return { x: width ? Math.min(1, Math.max(0, (point.left - viewport.left - margin) / width)) : 0.5,
    y: height ? Math.min(1, Math.max(0, (point.top - viewport.top - margin) / height)) : 0 }
}
export function placePopover(viewport: Frame, palette: Frame, size: Pick<Frame, 'width' | 'height'>): { left: number; top: number } {
  const right = viewport.left + viewport.width - margin, bottom = viewport.top + viewport.height - margin
  const below = palette.top + palette.height + 8
  return { left: Math.max(viewport.left + margin, Math.min(right - size.width, palette.left)),
    top: Math.max(viewport.top + margin, Math.min(bottom - size.height, below + size.height <= bottom ? below : palette.top - size.height - 8)) }
}
