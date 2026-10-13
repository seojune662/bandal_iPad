export const COURSE_COLORS = [
  'gold',
  'green',
  'blue',
  'pink',
  'violet',
  'orange'
] as const

export type CourseColor = (typeof COURSE_COLORS)[number]

const colorLabels: Record<CourseColor, string> = {
  gold: '문골드',
  green: '세이지',
  blue: '블루',
  pink: '핑크',
  violet: '바이올렛',
  orange: '오렌지'
}

export function courseColorLabel(color: CourseColor): string {
  return colorLabels[color]
}

export function normalizeCourseColor(color: string): CourseColor {
  if (COURSE_COLORS.some((candidate) => candidate === color)) {
    return color as CourseColor
  }

  let hash = 0
  for (const character of color) {
    hash = (hash * 31 + character.charCodeAt(0)) >>> 0
  }
  return COURSE_COLORS[hash % COURSE_COLORS.length] ?? 'gold'
}
