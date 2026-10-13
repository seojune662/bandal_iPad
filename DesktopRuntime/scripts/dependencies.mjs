import { existsSync, lstatSync, mkdirSync, symlinkSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const runtime = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export function dependencies() {
  const local = resolve(runtime, 'node_modules')
  if (!existsSync(local)) {
    const installed = resolve(process.env.BANDAL_DESKTOP_SOURCE ?? resolve(runtime, '../../bandal'), 'node_modules')
    if (!existsSync(installed)) throw new Error('Install pinned dependencies: pnpm --dir DesktopRuntime install --frozen-lockfile')
    mkdirSync(runtime, { recursive: true })
    symlinkSync(installed, local, 'dir')
  }
  const require = createRequire(resolve(runtime, 'package.json'))
  return { require, source: lstatSync(local).isSymbolicLink() ? 'adjacent desktop installation' : 'local pinned installation' }
}
