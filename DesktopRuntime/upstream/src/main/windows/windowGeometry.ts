export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(Math.max(value, lower), Math.max(lower, upper))
}

export function clampToArea(rect: Rect, area: Rect): Rect {
  return {
    ...rect,
    x: clamp(rect.x, area.x, area.x + area.width - rect.width),
    y: clamp(rect.y, area.y, area.y + area.height - rect.height)
  }
}

