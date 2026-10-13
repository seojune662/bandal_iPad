import { readdir, readFile, realpath, stat } from 'node:fs/promises'
import { join, basename, dirname } from 'node:path'
import { homedir } from 'node:os'
import { createHash } from 'node:crypto'
import type { AgentProvider } from '../../../shared/types/agent-events'
import type { ChatSkill, CreationKind } from '../../../shared/types/chatCapabilities'

interface InstalledSkill extends ChatSkill { path: string }
const categoryNames: Record<CreationKind, string[]> = {
  image: ['imagegen', 'image-generation'], document: ['documents', 'docx'], pdf: ['pdf'],
  spreadsheet: ['spreadsheets', 'xlsx'], presentation: ['presentations', 'pptx']
}
export function parseSkillMetadata(content: string, path: string): InstalledSkill {
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---/.exec(content)?.[1] ?? ''
  const field = (key: string): string => new RegExp(`^${key}:\\s*(.+)$`, 'm').exec(frontmatter)?.[1]?.trim().replace(/^['"]|['"]$/g, '') ?? ''
  const name = field('name') || basename(dirname(path))
  const keys = [name.toLowerCase(), basename(dirname(path)).toLowerCase()]
  return {
    id: createHash('sha256').update(path).digest('hex').slice(0, 24), name,
    description: field('description').replace(/^[>|]-?$/, '').slice(0, 500), path,
    creationKinds: (Object.keys(categoryNames) as CreationKind[]).filter((kind) => categoryNames[kind].some((alias) => keys.includes(alias)))
  }
}
/** Bounded async discovery; no recursive traversal of the student's course files. */
export async function discoverChatSkills(provider: AgentProvider, courseFolder?: string, rootsOverride?: string[]): Promise<InstalledSkill[]> {
  const home = homedir()
  const configRoot = provider === 'codex' ? process.env['CODEX_HOME'] ?? join(home, '.codex') : join(home, provider === 'claude-code' ? '.claude' : '.gemini')
  const roots = rootsOverride ?? [join(configRoot, 'skills'), join(configRoot, 'plugins', 'cache'),
    ...(provider === 'codex' && configRoot !== join(home, '.codex') ? [join(home, '.codex', 'skills'), join(home, '.codex', 'plugins', 'cache')] : []),
    ...(courseFolder ? [join(courseFolder, provider === 'claude-code' ? '.claude' : provider === 'codex' ? '.agents' : '.gemini', 'skills')] : [])]
  const seen = new Set<string>(), found = new Map<string, InstalledSkill>()
  let visited = 0
  async function walk(path: string, depth: number): Promise<void> {
    if (depth > 7 || ++visited > 1800) return
    try {
      const canonical = await realpath(path)
      if (seen.has(canonical)) return
      seen.add(canonical)
      const entries = await readdir(canonical, { withFileTypes: true })
      if (entries.some((entry) => entry.name === 'SKILL.md')) {
        const skillPath = join(canonical, 'SKILL.md')
        if ((await stat(skillPath)).size <= 128 * 1024) {
          const skill = parseSkillMetadata(await readFile(skillPath, 'utf8'), skillPath)
          if (!found.has(skill.name)) found.set(skill.name, skill)
        }
        return
      }
      for (const entry of entries.sort((a, b) => b.name.localeCompare(a.name, undefined, { numeric: true }))) {
        if (['node_modules', '.git', 'scripts', 'references', 'assets'].includes(entry.name)) continue
        if (entry.isDirectory() || entry.isSymbolicLink()) await walk(join(canonical, entry.name), depth + 1)
      }
    } catch { /* An absent/uninstalled directory is an empty source. */ }
  }
  for (const root of roots) await walk(root, 0)
  return [...found.values()].sort((a, b) => a.name.localeCompare(b.name))
}
