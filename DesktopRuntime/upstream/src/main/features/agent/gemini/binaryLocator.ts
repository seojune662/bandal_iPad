import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import type { AgentAvailability } from '../../../../shared/types/agent-events'
import {
  AgentUnavailableError,
  logProbeFailures,
  unavailableSummary,
  type BinaryLocator,
  type LocatedBinary,
  type ProbeFailure
} from '../binaryLocator'
import {
  augmentedPathEnv,
  isWindows,
  joinPath,
  LOGIN_SHELL_PATH_ARGS,
  nvmBinDirs,
  probeExec,
  splitPath,
  stripShellBanner,
  windowsCliInstallDirs,
  type Platform
} from '../platform'

const EXEC_TIMEOUT_MS = 10_000

export interface GeminiBinaryLocatorDeps {
  configuredPath?: () => string | undefined
  exec?: (
    file: string,
    args: string[],
    opts?: { env?: NodeJS.ProcessEnv }
  ) => Promise<{ stdout: string; stderr: string }>
  platform?: Platform
  env?: NodeJS.ProcessEnv
  fileExists?: (path: string) => boolean
  hasApiKey?: () => boolean
}

function fileNames(platform: Platform): string[] {
  return isWindows(platform)
    ? ['gemini.cmd', 'gemini.exe', 'gemini.bat']
    : ['gemini']
}

function knownDirs(platform: Platform, env: NodeJS.ProcessEnv): string[] {
  if (isWindows(platform)) {
    const appData = env['APPDATA']
    return [
      ...(appData === undefined || appData === ''
        ? []
        : [joinPath(platform, appData, 'npm')]),
      ...windowsCliInstallDirs(platform, env)
    ]
  }
  return [
    joinPath(platform, homedir(), '.local', 'bin'),
    joinPath(platform, homedir(), '.npm-global', 'bin'),
    '/opt/homebrew/bin',
    '/usr/local/bin',
    ...nvmBinDirs(platform, env)
  ]
}

function parseVersion(output: string): string | null {
  return /^(\d+\.\d+\.\d+)\s*$/mu.exec(output)?.[1] ?? null
}

function geminiHome(env: NodeJS.ProcessEnv): string {
  const configured = env['GEMINI_CLI_HOME']
  return configured === undefined || configured === '' ? homedir() : configured
}

function activeAccount(path: string): string | null {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, 'utf8'))
    if (typeof parsed !== 'object' || parsed === null) return null
    const active = (parsed as Record<string, unknown>)['active']
    return typeof active === 'string' && active.trim() !== '' ? active : null
  } catch {
    return null
  }
}

export function createGeminiBinaryLocator(
  deps: GeminiBinaryLocatorDeps = {}
): BinaryLocator {
  const exec = deps.exec ?? (
    async (file: string, args: string[], opts?: { env?: NodeJS.ProcessEnv }) =>
      probeExec(file, args, {
        timeoutMs: EXEC_TIMEOUT_MS,
        ...(opts?.env === undefined ? {} : { env: opts.env })
      })
  )
  const fileExists = deps.fileExists ?? existsSync
  const platform = deps.platform ?? process.platform
  const env = deps.env ?? process.env
  let cachedBinary: LocatedBinary | null = null
  let cachedShellPath: string | null | undefined

  async function loginShellPath(): Promise<string | null> {
    if (cachedShellPath !== undefined) return cachedShellPath
    if (isWindows(platform)) {
      const inherited = env['PATH'] ?? env['Path'] ?? null
      cachedShellPath = inherited === null || inherited === '' ? null : inherited
      return cachedShellPath
    }
    try {
      const { stdout } = await exec('/bin/zsh', [...LOGIN_SHELL_PATH_ARGS])
      cachedShellPath = stripShellBanner(stdout) || null
    } catch {
      cachedShellPath = null
    }
    return cachedShellPath
  }

  async function candidates(): Promise<string[]> {
    const result: string[] = []
    const push = (path: string): void => {
      if (path !== '' && !result.includes(path)) result.push(path)
    }
    push(deps.configuredPath?.() ?? '')
    for (const dir of knownDirs(platform, env)) {
      for (const name of fileNames(platform)) push(joinPath(platform, dir, name))
    }
    const shellPath = await loginShellPath()
    if (shellPath !== null) {
      for (const dir of splitPath(shellPath, platform)) {
        for (const name of fileNames(platform)) push(joinPath(platform, dir, name))
      }
    }
    return result
  }

  async function locate(): Promise<LocatedBinary> {
    if (cachedBinary !== null) return cachedBinary
    const failures: ProbeFailure[] = []
    try {
      let sawExecFailure = false
      for (const path of await candidates()) {
        if (!fileExists(path)) continue
        try {
          const { stdout, stderr } = await exec(path, ['--version'], {
            env: augmentedPathEnv(path, cachedShellPath ?? null, env, platform)
          })
          const version = parseVersion(`${stdout}\n${stderr}`)
          if (version !== null) {
            cachedBinary = { path, version }
            return cachedBinary
          }
        } catch (error) {
          const code = (error as NodeJS.ErrnoException).code
          failures.push({ path, code: String(code ?? 'unknown') })
          if (code !== 'ENOENT') sawExecFailure = true
        }
      }
      throw new AgentUnavailableError(
        'not-installed',
        sawExecFailure
          ? 'Gemini CLI 파일은 있지만 실행하지 못했습니다. node 설치 상태를 확인해 주세요.'
          : isWindows(platform)
            ? 'Gemini CLI를 찾지 못했습니다. %APPDATA%\\npm과 PATH를 확인했습니다.'
            : 'Gemini CLI를 찾지 못했습니다. npm 설치 경로와 로그인 셸 PATH를 확인했습니다.'
      )
    } finally {
      logProbeFailures('gemini-locator', failures)
    }
  }

  async function availability(): Promise<AgentAvailability> {
    let binary: LocatedBinary
    try {
      binary = await locate()
    } catch (error) {
      return unavailableSummary(error)
    }
    const authDir = joinPath(platform, geminiHome(env), '.gemini')
    const hasOauthCredentials = fileExists(
      joinPath(platform, authDir, 'oauth_creds.json')
    )
    let hasApiKey = false
    try {
      hasApiKey = deps.hasApiKey?.() ?? false
    } catch {
      hasApiKey = false
    }
    const result: AgentAvailability = {
      installed: true,
      version: binary.version,
      loggedIn: hasOauthCredentials || hasApiKey
    }
    if (hasOauthCredentials) {
      const account = activeAccount(
        joinPath(platform, authDir, 'google_accounts.json')
      )
      if (account !== null) result.accountEmail = account
    }
    return result
  }

  return {
    locate,
    availability,
    loginShellPath,
    reset() {
      cachedBinary = null
      cachedShellPath = undefined
    }
  }
}
