/**
 * Locates the user's own Claude Code CLI binary and answers
 * `agent:availability`. Resolution order: configured path → well-known install
 * dirs → PATH. Results are cached.
 *
 * On macOS/Linux the PATH comes from a *login shell* (`zsh -lic`), because a
 * GUI-launched app inherits launchd's minimal PATH rather than the one the
 * user's `.zshrc` builds. Windows has no such split — the process environment
 * already carries the machine + user PATH — so that step is skipped there.
 * See ./platform.ts for the rest of the OS differences.
 */

import { existsSync } from 'node:fs'
import type { AgentAvailability, AgentErrorCode } from '../../../shared/types/agent-events'
import {
  augmentedPathEnv,
  claudeFileNames,
  isWindows,
  joinPath,
  LOGIN_SHELL_PATH_ARGS,
  probeExec,
  splitPath,
  stripShellBanner,
  wellKnownClaudeDirs,
  type Platform
} from './platform'

const EXEC_TIMEOUT_MS = 10_000
export const MIN_CLI_VERSION = { major: 2, minor: 1 }

export class AgentUnavailableError extends Error {
  readonly code: AgentErrorCode
  /** The version actually found, when `code` is 'version-too-old'. */
  readonly version?: string

  constructor(code: AgentErrorCode, message: string, version?: string) {
    super(message)
    this.name = 'AgentUnavailableError'
    this.code = code
    if (version !== undefined) {
      this.version = version
    }
  }
}

/** One candidate that existed on disk but failed to run, for diagnostics. */
export interface ProbeFailure {
  path: string
  code: string
}

/** Concise once-per-locate log line so field reports carry the real cause. */
export function logProbeFailures(tag: string, failures: ProbeFailure[]): void {
  if (failures.length === 0) {
    return
  }
  console.error(
    `[${tag}] candidate probe failures: ${failures
      .map((failure) => `${failure.path} (${failure.code})`)
      .join(', ')}`
  )
}

/**
 * Maps a locate() failure to an AgentAvailability the renderer can act on.
 * Used by both locators so `availability()` never collapses distinct causes
 * ("version too old" vs "not installed" vs "exists but won't run") into one
 * bare `{ installed: false }`.
 */
export function unavailableSummary(error: unknown): AgentAvailability {
  if (error instanceof AgentUnavailableError) {
    if (error.code === 'version-too-old') {
      // The CLI IS installed — the UI should offer an update, not an install.
      const result: AgentAvailability = {
        installed: true,
        loggedIn: false,
        code: error.code,
        reason: error.message
      }
      if (error.version !== undefined) {
        result.version = error.version
      }
      return result
    }
    return {
      installed: false,
      loggedIn: false,
      code: error.code,
      reason: error.message
    }
  }
  return {
    installed: false,
    loggedIn: false,
    code: 'unknown',
    reason: error instanceof Error ? error.message : String(error)
  }
}

export interface LocatedBinary {
  path: string
  version: string
}

export interface BinaryLocator {
  /** Resolved CLI binary (cached). Throws AgentUnavailableError. */
  locate(): Promise<LocatedBinary>
  /** Availability summary for the renderer; never throws. */
  availability(): Promise<AgentAvailability>
  /** PATH from a login shell (cached), for child process env. */
  loginShellPath(): Promise<string | null>
  /** Drops caches (e.g. after the user installs the CLI). */
  reset(): void
}

export interface BinaryLocatorDeps {
  /** Optional user-configured absolute path to the claude binary. */
  configuredPath?: () => string | undefined
  /** Injectable exec for tests. */
  exec?: (
    file: string,
    args: string[],
    opts?: { env?: NodeJS.ProcessEnv }
  ) => Promise<{ stdout: string; stderr: string }>
  /** Injectable for tests — lets one OS exercise both platform branches. */
  platform?: Platform
  /** Injectable for tests (reads PATH / APPDATA / LOCALAPPDATA). */
  env?: NodeJS.ProcessEnv
  /**
   * Candidate prefilter, defaults to `existsSync`. Skips the expensive spawn
   * probe for paths with no file behind them (PATH sweeps produce dozens).
   * Tests that fabricate paths inject `() => true`.
   */
  fileExists?: (path: string) => boolean
}

function parseVersion(stdout: string): string | null {
  const match = /(\d+)\.(\d+)\.(\d+)/.exec(stdout)
  return match === null ? null : match[0]
}

export function isVersionSupported(version: string): boolean {
  const match = /^(\d+)\.(\d+)/.exec(version)
  if (match === null) {
    return false
  }
  const major = Number(match[1])
  const minor = Number(match[2])
  if (major !== MIN_CLI_VERSION.major) {
    return major > MIN_CLI_VERSION.major
  }
  return minor >= MIN_CLI_VERSION.minor
}

interface AuthStatus {
  loggedIn: boolean
  subscriptionType?: string
}

function parseAuthStatus(stdout: string): AuthStatus {
  try {
    const start = stdout.indexOf('{')
    if (start < 0) {
      return { loggedIn: false }
    }
    const parsed: unknown = JSON.parse(stdout.slice(start))
    if (typeof parsed !== 'object' || parsed === null) {
      return { loggedIn: false }
    }
    const record = parsed as Record<string, unknown>
    const status: AuthStatus = { loggedIn: record['loggedIn'] === true }
    if (typeof record['subscriptionType'] === 'string') {
      status.subscriptionType = record['subscriptionType']
    }
    return status
  } catch {
    return { loggedIn: false }
  }
}

export function createBinaryLocator(deps: BinaryLocatorDeps = {}): BinaryLocator {
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
  const fileNames = claudeFileNames(platform)

  let cachedBinary: LocatedBinary | null = null
  let cachedShellPath: string | null | undefined

  async function tryVersion(
    path: string,
    failures: ProbeFailure[]
  ): Promise<string | null> {
    try {
      // An npm-installed claude is a node shim: `node` must be reachable on
      // the CHILD's PATH or the probe dies at the shebang (see codex locator).
      const { stdout } = await exec(path, ['--version'], {
        env: augmentedPathEnv(path, cachedShellPath ?? null, env, platform)
      })
      return parseVersion(stdout)
    } catch (error) {
      failures.push({
        path,
        code: String((error as NodeJS.ErrnoException).code ?? 'unknown')
      })
      return null
    }
  }

  async function loginShellPath(): Promise<string | null> {
    if (cachedShellPath !== undefined) {
      return cachedShellPath
    }
    // Windows: no login-shell concept. The inherited PATH is already the full
    // machine + user PATH, so hand that back instead of shelling out.
    if (isWindows(platform)) {
      const inherited = env['PATH'] ?? env['Path'] ?? null
      cachedShellPath = inherited === null || inherited === '' ? null : inherited
      return cachedShellPath
    }
    try {
      const { stdout } = await exec('/bin/zsh', [...LOGIN_SHELL_PATH_ARGS])
      const path = stripShellBanner(stdout)
      cachedShellPath = path === '' ? null : path
    } catch {
      cachedShellPath = null
    }
    return cachedShellPath
  }

  async function candidates(): Promise<string[]> {
    const list: string[] = []
    const push = (path: string): void => {
      if (!list.includes(path)) {
        list.push(path)
      }
    }

    const configured = deps.configuredPath?.()
    if (configured !== undefined && configured !== '') {
      push(configured)
    }
    for (const dir of wellKnownClaudeDirs(platform, env)) {
      for (const name of fileNames) {
        push(joinPath(platform, dir, name))
      }
    }
    const shellPath = await loginShellPath()
    if (shellPath !== null) {
      for (const dir of splitPath(shellPath, platform)) {
        for (const name of fileNames) {
          push(joinPath(platform, dir, name))
        }
      }
    }
    return list
  }

  async function locate(): Promise<LocatedBinary> {
    if (cachedBinary !== null) {
      return cachedBinary
    }
    const failures: ProbeFailure[] = []
    try {
      let sawBinary = false
      let badVersion: string | null = null
      for (const path of await candidates()) {
        // A PATH sweep yields dozens of candidates; only spawn what exists.
        if (!fileExists(path)) {
          continue
        }
        const version = await tryVersion(path, failures)
        if (version === null) {
          continue
        }
        sawBinary = true
        if (isVersionSupported(version)) {
          cachedBinary = { path, version }
          return cachedBinary
        }
        badVersion = version
      }
      if (sawBinary) {
        throw new AgentUnavailableError(
          'version-too-old',
          `Claude Code ${badVersion ?? '?'} found, but ${MIN_CLI_VERSION.major}.${MIN_CLI_VERSION.minor}+ is required`,
          badVersion ?? undefined
        )
      }
      throw new AgentUnavailableError(
        'not-installed',
        isWindows(platform)
          ? 'Claude Code CLI not found (checked configured path, %APPDATA%\\npm, %LOCALAPPDATA%\\Programs\\claude, common tool dirs and PATH)'
          : 'Claude Code CLI not found (checked configured path, ~/.local/bin and the login-shell PATH)'
      )
    } finally {
      logProbeFailures('claude-locator', failures)
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
      const { stdout } = await exec(binary.path, ['auth', 'status', '--json'], {
        env: augmentedPathEnv(binary.path, cachedShellPath ?? null, env, platform)
      })
      const auth = parseAuthStatus(stdout)
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
    reset: () => {
      cachedBinary = null
      cachedShellPath = undefined
    }
  }
}
