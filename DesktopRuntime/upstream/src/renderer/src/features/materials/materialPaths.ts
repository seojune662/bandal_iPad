import type {
  MaterialKind,
  MaterialNode
} from '../../../../shared/types/materials'

export function materialBaseName(relPath: string): string {
  return relPath.split('/').at(-1) ?? relPath
}

export function materialParentPath(relPath: string): string {
  const separator = relPath.lastIndexOf('/')
  return separator < 0 ? '' : relPath.slice(0, separator)
}

export function targetDirectory(node: MaterialNode | null): string {
  if (node === null) return ''
  return node.kind === 'dir' ? node.relPath : materialParentPath(node.relPath)
}

export function findMaterialNode(
  nodes: MaterialNode[],
  relPath: string | null
): MaterialNode | null {
  if (relPath === null) return null
  for (const node of nodes) {
    if (node.relPath === relPath) return node
    if (node.kind === 'dir') {
      const child = findMaterialNode(node.children ?? [], relPath)
      if (child !== null) return child
    }
  }
  return null
}

/** Joins a POSIX material path to either a POSIX or Windows course folder. */
export function absoluteMaterialPath(
  courseFolder: string,
  relPath: string
): string {
  const folder = courseFolder.replace(/[\\/]+$/, '')
  if (relPath === '') return folder
  const separator = folder.includes('\\') && !folder.includes('/') ? '\\' : '/'
  return `${folder}${separator}${relPath.replaceAll('/', separator)}`
}

export function kindForMaterialName(name: string): MaterialKind {
  const extension = name.includes('.')
    ? `.${name.split('.').at(-1)?.toLocaleLowerCase() ?? ''}`
    : ''
  if (extension === '.pdf') return 'pdf'
  if (extension === '.md' || extension === '.markdown') return 'note'
  if (
    ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp', '.avif', '.heic']
      .includes(extension)
  ) {
    return 'image'
  }
  // main 의 kindForFile(materialsRepo.ts)과 반드시 같은 목록이어야 한다.
  if (['.mp4', '.m4v', '.webm'].includes(extension)) return 'video'
  return 'other'
}

function childrenAt(nodes: MaterialNode[], dirRelPath: string): MaterialNode[] {
  if (dirRelPath === '') return nodes
  let children = nodes
  for (const segment of dirRelPath.split('/')) {
    const directory = children.find(
      (node) => node.kind === 'dir' && node.name === segment
    )
    if (directory === undefined) return []
    children = directory.children ?? []
  }
  return children
}

/** Returns 새 폴더, 새 폴더-2, … based on the current tree snapshot. */
export function unusedFolderName(
  nodes: MaterialNode[],
  dirRelPath: string
): string {
  const names = new Set(childrenAt(nodes, dirRelPath).map((node) => node.name))
  if (!names.has('새 폴더')) return '새 폴더'
  for (let number = 2; number <= 1000; number += 1) {
    const candidate = `새 폴더-${number}`
    if (!names.has(candidate)) return candidate
  }
  return `새 폴더-1001`
}
