import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const source = join(root, 'resources/ipad-bridge/bridge.py')
const sourceHash = () => createHash('sha256').update(readFileSync(source)).digest('hex')
const outputFor = (platform, arch) => join(root, 'resources/native/ipad-bridge', `${platform}-${arch}`)

export function buildIPadBridge(arch = process.arch) {
  if (!['darwin', 'win32'].includes(process.platform) || arch !== process.arch) {
    throw new Error('Build the iPad companion on the matching operating system and architecture.')
  }
  const output = outputFor(process.platform, arch)
  mkdirSync(output, { recursive: true })
  const python = process.env.BANDAL_PYTHON ?? (process.platform === 'win32' ? 'python' : 'python3')
  execFileSync(python, ['-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile', '--name', 'bandal-ipad-bridge',
    '--distpath', output, '--workpath', join(root, '.cache/ipad-bridge', arch),
    '--specpath', join(root, '.cache/ipad-bridge', arch), source], { stdio: 'inherit' })
  const binary = join(output, `bandal-ipad-bridge${process.platform === 'win32' ? '.exe' : ''}`)
  execFileSync(binary, ['--help'], { stdio: 'pipe' })
  writeFileSync(join(output, 'manifest.json'), JSON.stringify({ platform: process.platform, arch,
    sourceHash: sourceHash(), binaryHash: createHash('sha256').update(readFileSync(binary)).digest('hex') }))
}

export default async function beforePack(context) {
  const platform = context.electronPlatformName
  const arch = context.arch === 3 ? 'arm64' : 'x64'
  const output = outputFor(platform, arch)
  const manifestPath = join(output, 'manifest.json')
  if (!existsSync(manifestPath)) throw new Error(`Missing iPad companion ${platform}-${arch}; run node scripts/build-ipad-bridge.mjs on its native build runner first.`)
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  const binary = join(output, `bandal-ipad-bridge${platform === 'win32' ? '.exe' : ''}`)
  if (manifest.platform !== platform || manifest.arch !== arch || manifest.sourceHash !== sourceHash() ||
      manifest.binaryHash !== createHash('sha256').update(readFileSync(binary)).digest('hex')) {
    throw new Error('Stale or corrupt iPad companion; rebuild before packaging.')
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) buildIPadBridge(process.argv[2])
