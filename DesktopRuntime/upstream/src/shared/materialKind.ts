import type { MaterialKind } from './types/materials'

const IMAGE_EXTENSIONS = new Set([
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.svg',
  '.bmp',
  '.avif',
  '.heic'
])

// bandal-media:// 스트리밍으로 재생 가능한 컨테이너만.
const VIDEO_EXTENSIONS = new Set(['.mp4', '.m4v', '.webm'])

function extensionFor(relPath: string): string {
  const fileName = relPath.split('/').at(-1) ?? relPath
  const dot = fileName.lastIndexOf('.')
  return dot <= 0 ? '' : fileName.slice(dot).toLowerCase()
}

/** 과목 상대 경로의 확장자를 자료 레일에서 쓰는 종류로 분류한다. */
export function materialKindForPath(relPath: string): MaterialKind {
  const extension = extensionFor(relPath)
  if (extension === '.pdf') return 'pdf'
  if (extension === '.md' || extension === '.markdown') return 'note'
  if (IMAGE_EXTENSIONS.has(extension)) return 'image'
  if (VIDEO_EXTENSIONS.has(extension)) return 'video'
  return 'other'
}
