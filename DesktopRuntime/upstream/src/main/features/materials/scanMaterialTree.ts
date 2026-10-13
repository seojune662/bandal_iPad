import { opendir, stat } from 'node:fs/promises'
import type { Dirent, Stats } from 'node:fs'
import { join, posix } from 'node:path'
import type { MaterialKind, MaterialNode } from '../../../shared/types/materials'
import { materialKindForPath } from '../../../shared/materialKind'
import type { MaterialsScanLimits } from './materialsRepo'


export type ScanTruncation = 'depth' | 'entries'

interface WalkState {
  entriesRead: number
  files: MaterialNode[]
  limits: MaterialsScanLimits
  truncation: Set<ScanTruncation>
}

export interface MaterialWalk {
  nodes: MaterialNode[]
  files: MaterialNode[]
  truncation: Set<ScanTruncation>
}

export function kindForFile(fileName: string): MaterialKind {
  return materialKindForPath(fileName)
}

function isHidden(name: string): boolean {
  return name.startsWith('.')
}

async function sortedEntries(absDir: string, state: WalkState): Promise<Dirent<string>[]> {
  if (state.truncation.has('entries')) return []

  const directory = await opendir(absDir)
  const entries: Dirent<string>[] = []
  try {
    while (true) {
      const entry = await directory.read()
      if (entry === null) break

      // One look-ahead entry is necessary to distinguish exactly-at-limit
      // from truncated. It is never stat'ed or returned.
      if (state.entriesRead >= state.limits.maxEntries) {
        state.truncation.add('entries')
        break
      }
      state.entriesRead += 1
      // Hidden and special entries still consume the scan budget: otherwise
      // a folder full of them could bypass the main-thread work ceiling.
      if (!isHidden(entry.name)) entries.push(entry)
    }
  } finally {
    await directory.close()
  }

  return entries.sort((a, b) => {
    if (a.isDirectory() !== b.isDirectory()) {
      return a.isDirectory() ? -1 : 1
    }
    return a.name.localeCompare(b.name)
  })
}

async function walkDir(
  absDir: string,
  relDir: string,
  depth: number,
  state: WalkState
): Promise<MaterialNode[]> {
  const entries = await sortedEntries(absDir, state)
  const nodes: MaterialNode[] = []
  const files = entries.filter(entry => entry.isFile())
  const metadata = new Map<string, Stats>()
  for (let offset = 0; offset < files.length; offset += 4) {
    await Promise.all(files.slice(offset, offset + 4).map(async entry => {
      metadata.set(entry.name, await stat(join(absDir, entry.name)))
    }))
  }
  for (const entry of entries) {
    const relPath = relDir === '' ? entry.name : posix.join(relDir, entry.name)
    const absPath = join(absDir, entry.name)
    if (entry.isDirectory()) {
      let children: MaterialNode[] = []
      if (depth >= state.limits.maxDepth) {
        state.truncation.add('depth')
      } else {
        children = await walkDir(absPath, relPath, depth + 1, state)
      }
      nodes.push({
        relPath,
        name: entry.name,
        kind: 'dir',
        children
      })
    } else if (entry.isFile()) {
      const info = metadata.get(entry.name)!
      const node: MaterialNode = {
        relPath,
        name: entry.name,
        kind: kindForFile(entry.name),
        size: info.size,
        mtime: Math.round(info.mtimeMs)
      }
      nodes.push(node)
      state.files.push(node)
    }
    // Symlinks and other entry types are intentionally skipped.
  }
  return nodes
}

export async function scanMaterialTree(
  folder: string,
  limits: MaterialsScanLimits
): Promise<MaterialWalk> {
  const state: WalkState = {
    entriesRead: 0,
    files: [],
    limits,
    truncation: new Set()
  }
  const nodes = await walkDir(folder, '', 0, state)
  return { nodes, files: state.files, truncation: state.truncation }
}
