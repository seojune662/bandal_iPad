export const ICON_MOON_CX: 512
export const ICON_MOON_CY: 498
export const MARK_CX: 12
export const MARK_CY: 12
export const MARK_RADIUS: 9
export const MOON_TILT: -14
export const TERMINATOR_BULGE: 0.15

export function litHalfPath(
  cx: number,
  cy: number,
  radius: number,
  tilt: number,
  bulge: number
): string
export const MOON_SHAPES: { name: string; pivot: number[]; path: string }[]
export const MOON_SCALE: number
export const MOON_VIEWBOX: string
export const MOON_LOOP_MS: number
export const MOON_INTRO_MS: number
export function moonPose(progress: number): [number, number]
export function moonTransform(index: number, angle?: number): string
export function moonSvgPaths(fill?: string): string
