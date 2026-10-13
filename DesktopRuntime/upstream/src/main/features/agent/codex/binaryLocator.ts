/** Locates the Codex CLI for GUI-launched Electron processes. */

import { existsSync } from 'node:fs'
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

export interface CodexBinaryLocatorDeps {
  configuredPath?: () => string | undefined
  exec?: (
    file: string,
    args: string[],
    opts?: { env?: NodeJS.ProcessEnv }
  ) => Promise<{ stdout: string; stderr: string }>
  platform?: Platform
  env?: NodeJS.ProcessEnv
  /** Candidate prefilter, defaults to `existsSync` — see BinaryLocatorDeps. */
  fileExists?: (path: string) => boolean
}

function fileNames(platform: Platform): string[] {
  return isWindows(platform)
    ? ['codex.cmd', 'codex.exe', 'codex.bat']
    : ['codex']
}

function knownDirs(
  platform: Platform,
  env: NodeJS.ProcessEnv
): string[] {
  if (isWindows(platform)) {
    const appData = env['APPDATA']
    const localAppData = env['LOCALAPPDATA']
    return [
      ...(env['CODEX_INSTALL_DIR'] ? [env['CODEX_INSTALL_DIR']] : []),
      // The standalone installer updates the user PATH, but an already-running
      // Bandal process keeps its old PATH until restart. Probe its native target
      // first, ahead of any older npm shim that may require Node.
      ...(localAppData ? [joinPath(platform, localAppData, 'Programs', 'OpenAI', 'Codex', 'bin')] : []),
      ...(appData === undefined || appData === ''
        ? []
        : [joinPath(platform, appData, 'npm')]),
      // Same user-level tool dirs the claude locator sweeps: native-installer
      // target, Scoop shims, Volta, pnpm. GUI-launched PATH misses them all.
      ...windowsCliInstallDirs(platform, env)
    ]
  }
  return [
    ...(env['CODEX_INSTALL_DIR'] ? [env['CODEX_INSTALL_DIR']] : []),
    joinPath(platform, homedir(), '.local', 'bin'),
    joinPath(platform, homedir(), '.npm-global', 'bin'),
    '/opt/homebrew/bin',
    '/usr/local/bin',
    // nvm installs never touch the prefixes above — without this a GUI-launched
    // process whose login-shell PATH capture fails cannot see codex at all.
    ...nvmBinDirs(platform, env)
  ]
}

function parseVersion(output: string): string | null {
  const match = /(?:codex-cli\s+)?(\d+\.\d+\.\d+)/u.exec(output)
  return match?.[1] ?? null
}

function authStatus(output: string): {
  loggedIn: boolean
  subscriptionType?: string
} {
  const line = output
    .split('\n')
    .map((part) => part.trim())
    .find((part) => /^Logged in using /iu.test(part))
  if (line === undefined) {
    return { loggedIn: false }
  }
  const subscriptionType = line.replace(/^Logged in using /iu, '').trim()
  return subscriptionType === ''
    ? { loggedIn: true }
    : { loggedIn: true, subscriptionType }
}

export function createCodexBinaryLocator(
  deps: CodexBinaryLocatorDeps = {}
): BinaryLocator {
  const exec =
    deps.exec ??
    (async (file: string, args: string[], opts?: { env?: NodeJS.ProcessEnv }) =>
      // probeExec, not execFile: `.cmd` shims need cross-spawn on Windows
      // (execFile without a shell throws EINVAL there). See platform.ts.
      probeExec(file, args, {
        timeoutMs: EXEC_TIMEOUT_MS,
        ...(opts?.env === undefined ? {} : { env: opts.env })
      }))
  const fileExists = deps.fileExists ?? existsSync
  const platform = deps.platform ?? process.platform
  const env = deps.env ?? process.env

  let cachedBinary: LocatedBinary | null = null
  let cachedShellPath: string | null | undefined

  async function loginShellPath(): Promise<string | null> {
    if (cachedShellPath !== undefined) {
      return cachedShellPath
    }
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
      if (path !== '' && !result.includes(path)) {
        result.push(path)
      }
    }
    push(deps.configuredPath?.() ?? '')
    for (const dir of knownDirs(platform, env)) {
      for (const name of fileNames(platform)) {
        push(joinPath(platform, dir, name))
      }
    }
    const shellPath = await loginShellPath()
    if (shellPath !== null) {
      for (const dir of splitPath(shellPath, platform)) {
        for (const name of fileNames(platform)) {
          push(joinPath(platform, dir, name))
        }
      }
    }
    return result
  }

  async function locate(): Promise<LocatedBinary> {
    if (cachedBinary !== null) {
      return cachedBinary
    }
    const failures: ProbeFailure[] = []
    try {
      let sawExecFailure = false
      for (const path of await candidates()) {
        // A PATH sweep yields dozens of candidates; only spawn what exists.
        if (!fileExists(path)) {
          continue
        }
        try {
          // Node-shim CLIs need `node` on the CHILD's PATH — probe with an
          // augmented env or every nvm install reads as "not installed".
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
          // ENOENT = no file there, keep quiet. Anything else means the file
          // exists but would not run — worth surfacing to the student.
          if (code !== 'ENOENT') {
            sawExecFailure = true
          }
        }
      }
      throw new AgentUnavailableError(
        'not-installed',
        sawExecFailure
          ? 'Codex CLI 파일은 있지만 실행하지 못했습니다. node 설치 상태를 확인해 주세요.'
          : isWindows(platform)
            ? 'Codex CLI를 찾지 못했습니다. %APPDATA%\\npm과 PATH를 확인했습니다.'
            : 'Codex CLI를 찾지 못했습니다. npm 설치 경로와 로그인 셸 PATH를 확인했습니다.'
      )
    } finally {
      logProbeFailures('codex-locator', failures)
    }
  }

  async function availability(): Promise<AgentAvailability> {
    let binary: LocatedBinary
    try {
      binary = await locate()
    } catch (error) {
      return unavailableSummary(error)
    }
    const result: AgentAvailability = {
      installed: true,
      version: binary.version,
      loggedIn: false
    }
    try {
      // `codex login status` writes its human-readable status to stderr in
      // 0.146.0, so parse both streams and trust its successful exit status.
      const { stdout, stderr } = await exec(binary.path, ['login', 'status'], {
        env: augmentedPathEnv(binary.path, cachedShellPath ?? null, env, platform)
      })
      const auth = authStatus(`${stdout}\n${stderr}`)
      result.loggedIn = auth.loggedIn
      if (auth.subscriptionType !== undefined) {
        result.subscriptionType = auth.subscriptionType
      }
    } catch {
      result.loggedIn = false
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
