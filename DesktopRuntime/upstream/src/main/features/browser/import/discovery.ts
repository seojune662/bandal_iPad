import { access, readFile, readdir } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { basename, join, resolve } from 'node:path'
import type { BrowserImportBrowser, BrowserImportCapability, BrowserImportFileKind, BrowserImportItem, BrowserImportSource } from '../../../../shared/types/browserImport'

export interface PrivateImportSource {
  public: BrowserImportSource
  path: string
  root?: string
}

const ITEMS: BrowserImportItem[] = ['bookmarks', 'history', 'cookies', 'passwords']
export function capabilities(browser: BrowserImportBrowser, kind: BrowserImportSource['kind'], platform: NodeJS.Platform): Record<BrowserImportItem, BrowserImportCapability> {
  const supported = kind === 'passwords-csv' ? ['passwords'] : kind === 'bookmarks-html' ? ['bookmarks']
    : kind === 'safari-zip' ? ['bookmarks', 'passwords', 'history']
      : browser === 'firefox' ? ['bookmarks', 'history', 'cookies']
        : platform === 'darwin' || platform === 'win32' ? ITEMS : ['bookmarks', 'history']
  return Object.fromEntries(ITEMS.map((item) => [item, {
    supported: supported.includes(item),
    description: item === 'history' ? '최근 90일 · 최대 20,000개 URL'
      : item === 'cookies' && kind === 'safari-zip' ? 'Safari 쿠키는 내보내기에 포함되지 않습니다. 다시 로그인해 주세요.'
      : item === 'passwords' && browser === 'firefox' ? 'Firefox에서 내보낸 비밀번호 CSV를 선택해 주세요.'
      : item === 'cookies' && browser === 'firefox' ? '일반 쿠키만 지원합니다. 컨테이너·파티션 쿠키는 제외됩니다.'
      : (item === 'passwords' || item === 'cookies') && kind === 'profile' && platform === 'win32'
        ? 'Windows가 허용하는 암호화만 지원합니다. 앱 바운드 암호화는 제외됩니다.'
        : (item === 'passwords' || item === 'cookies') && kind === 'profile' && platform === 'darwin'
          ? 'macOS 키체인 접근 허용이 필요할 수 있습니다.'
          : supported.includes(item) ? '지원됨' : '이 원본에서는 지원하지 않습니다.'
  }])) as Record<BrowserImportItem, BrowserImportCapability>
}

async function exists(path: string): Promise<boolean> {
  try { await access(path); return true } catch { return false }
}

export async function discoverImportSources(options: {
  platform: NodeJS.Platform
  homeDir: string
  localAppData?: string
  appData?: string
}): Promise<PrivateImportSource[]> {
  const { platform, homeDir } = options
  const sources: PrivateImportSource[] = []
  if (platform !== 'darwin' && platform !== 'win32') return sources
  const chromiumRoots: Array<[BrowserImportBrowser, string, string]> = platform === 'darwin'
    ? [['chrome', 'Google Chrome', join(homeDir, 'Library/Application Support/Google/Chrome')], ['edge', 'Microsoft Edge', join(homeDir, 'Library/Application Support/Microsoft Edge')]]
    : [['chrome', 'Google Chrome', join(options.localAppData ?? join(homeDir, 'AppData/Local'), 'Google/Chrome/User Data')], ['edge', 'Microsoft Edge', join(options.localAppData ?? join(homeDir, 'AppData/Local'), 'Microsoft/Edge/User Data')]]
  for (const [browser, name, root] of chromiumRoots) {
    if (!await exists(root)) continue
    let names: Record<string, { name?: string }> = {}
    try {
      const state = JSON.parse(await readFile(join(root, 'Local State'), 'utf8')) as { profile?: { info_cache?: Record<string, { name?: string }> } }
      names = state.profile?.info_cache ?? {}
    } catch { /* A profile can remain readable without Local State metadata. */ }
    let dirs: string[] = []
    try { dirs = (await readdir(root, { withFileTypes: true })).filter((entry) => entry.isDirectory() && /^(Default|Profile \d+)$/.test(entry.name)).map((entry) => entry.name) } catch { continue }
    for (const dir of dirs) {
      sources.push({ public: { id: randomUUID(), browser, name, profileName: (names[dir]?.name ?? dir).slice(0, 100), kind: 'profile', capabilities: capabilities(browser, 'profile', platform) }, path: join(root, dir), root })
    }
  }
  const firefoxRoot = platform === 'darwin' ? join(homeDir, 'Library/Application Support/Firefox') : join(options.appData ?? join(homeDir, 'AppData/Roaming'), 'Mozilla/Firefox')
  try {
    const ini = await readFile(join(firefoxRoot, 'profiles.ini'), 'utf8')
    for (const section of ini.split(/(?=^\[)/m)) {
      if (!/^\[Profile\d+\]/.test(section)) continue
      const values = Object.fromEntries(section.split(/\r?\n/).map((line) => /^([^=]+)=(.*)$/.exec(line)).filter((match) => match !== null).map((match) => [match[1]!.trim(), match[2]!.trim()]))
      if (!values.Path) continue
      const path = values.IsRelative === '0' ? resolve(values.Path) : resolve(firefoxRoot, values.Path)
      if (!await exists(path)) continue
      sources.push({ public: { id: randomUUID(), browser: 'firefox', name: 'Firefox', profileName: (values.Name ?? basename(path)).slice(0, 100), kind: 'profile', capabilities: capabilities('firefox', 'profile', platform) }, path })
    }
  } catch { /* Firefox is not installed or has no profile. */ }
  return sources
}

export function fileImportSource(path: string, kind: BrowserImportFileKind, platform: NodeJS.Platform): PrivateImportSource {
  const browser = kind === 'safari-zip' ? 'safari' : 'file'
  return { public: { id: randomUUID(), browser, name: kind === 'safari-zip' ? 'Safari 내보내기' : kind === 'passwords-csv' ? '비밀번호 CSV' : '북마크 HTML', profileName: basename(path).slice(0, 120), kind, capabilities: capabilities(browser, kind, platform) }, path }
}
