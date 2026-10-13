/**
 * The one place OS differences live for the agent runtime.
 *
 * Everything here exists because the Claude Code CLI is installed and executed
 * differently on Windows than on macOS/Linux:
 *
 * - **No login shell.** `zsh -lic 'echo $PATH'` is how we find a CLI the user
 *   installed via a shell rc file. Windows has no equivalent — the process
 *   environment already carries the machine + user PATH.
 * - **The binary is a shim, not an ELF/Mach-O.** npm installs `claude.cmd`;
 *   `CreateProcess` cannot execute a `.cmd`, so it needs `cmd.exe /c`. We use
 *   `cross-spawn` for this rather than `shell: true`, see `spawnClaude` below.
 * - **No process groups.** `process.kill(-pid)` is POSIX-only and throws
 *   `EINVAL` on Windows; killing the CLI's helper processes needs `taskkill /T`.
 *
 * Every function takes an injectable `platform` so both branches are testable
 * from a single OS.
 */

import { spawn as nodeSpawn, spawnSync, type ChildProcess } from 'node:child_process'
import { readdirSync } from 'node:fs'
import crossSpawn from 'cross-spawn'
import { homedir } from 'node:os'
import { posix as posixPath, win32 as win32Path } from 'node:path'

export type Platform = NodeJS.Platform

export function isWindows(platform: Platform = process.platform): boolean {
  return platform === 'win32'
}

/**
 * Joins path segments using the *requested* platform's separator.
 *
 * Plain `path.join` uses the host's separator, which would produce
 * `C:\tools/claude.cmd` when the Windows branch is exercised from macOS. Every
 * path this module builds goes through here so the branches stay honest under
 * test — and so a future Linux CI job tests the same code the students run.
 */
export function joinPath(platform: Platform, ...parts: string[]): string {
  return isWindows(platform)
    ? win32Path.join(...parts)
    : posixPath.join(...parts)
}

/**
 * File names to try for the CLI in each PATH directory.
 *
 * On Windows the executable extension is mandatory — `spawn('claude')` fails
 * even when `claude.cmd` sits right there, because `CreateProcess` does not
 * consult `PATHEXT`. `.cmd` comes first: that is what npm's global install
 * writes, and it is what `where claude` resolves to on a normal setup.
 */
export function claudeFileNames(platform: Platform = process.platform): string[] {
  return isWindows(platform)
    ? ['claude.cmd', 'claude.exe', 'claude.bat']
    : ['claude']
}

/**
 * Well-known install locations to probe before falling back to PATH.
 *
 * POSIX: the CLI's own installer writes `~/.local/bin/claude`.
 * Windows: the native installer writes `%USERPROFILE%\.local\bin\claude.exe`.
 * Prefer that target before older Programs/npm installs, so an in-app update
 * takes effect immediately even when the Start-menu process has a stale PATH.
 */
export function wellKnownClaudeDirs(
  platform: Platform = process.platform,
  env: NodeJS.ProcessEnv = process.env
): string[] {
  if (!isWindows(platform)) {
    return [joinPath(platform, homedir(), '.local', 'bin')]
  }
  const dirs: string[] = []
  const userProfile = env['USERPROFILE']
  if (userProfile !== undefined && userProfile !== '') {
    dirs.push(joinPath(platform, userProfile, '.local', 'bin'))
  }
  const localAppData = env['LOCALAPPDATA']
  if (localAppData !== undefined && localAppData !== '') {
    dirs.push(joinPath(platform, localAppData, 'Programs', 'claude'))
    dirs.push(joinPath(platform, localAppData, 'Programs', 'claude', 'bin'))
  }
  const appData = env['APPDATA']
  if (appData !== undefined && appData !== '') {
    dirs.push(joinPath(platform, appData, 'npm'))
  }
  dirs.push(...windowsCliInstallDirs(platform, env))
  return [...new Set(dirs)]
}

/**
 * User-level Windows dirs where CLI tools commonly land but which a
 * GUI-launched process's PATH often misses:
 *
 * - `%USERPROFILE%\.local\bin` — the claude native installer's target
 * - `%USERPROFILE%\scoop\shims` — Scoop's shim directory
 * - `%LOCALAPPDATA%\Volta\bin` — Volta-managed node/npm shims
 * - `%LOCALAPPDATA%\pnpm` — pnpm's global bin dir
 *
 * Derived from env (not `homedir()`) so tests can exercise this branch from
 * any OS and an empty env yields no phantom `undefined\...` paths.
 */
export function windowsCliInstallDirs(
  platform: Platform,
  env: NodeJS.ProcessEnv
): string[] {
  const dirs: string[] = []
  const userProfile = env['USERPROFILE']
  if (userProfile !== undefined && userProfile !== '') {
    dirs.push(joinPath(platform, userProfile, '.local', 'bin'))
    dirs.push(joinPath(platform, userProfile, 'scoop', 'shims'))
  }
  const localAppData = env['LOCALAPPDATA']
  if (localAppData !== undefined && localAppData !== '') {
    dirs.push(joinPath(platform, localAppData, 'Volta', 'bin'))
    dirs.push(joinPath(platform, localAppData, 'pnpm'))
  }
  return dirs
}

/**
 * Login-shell PATH capture, banner-proof.
 *
 * `-i` is required: nvm/homebrew PATH setup commonly lives in `.zshrc`, which
 * only interactive shells read. But interactive rc files may also print to
 * stdout before our output (a `cat` banner on line 1 of `.zshrc` shipped a
 * real bug: the banner's first line was taken as the npm path → spawn ENOENT).
 * A NUL sentinel marks where the real value starts — nothing else in shell
 * output contains NUL, so everything before the LAST NUL is rc noise.
 */
export const LOGIN_SHELL_PATH_ARGS: readonly string[] = [
  '-lic',
  'printf "\\0%s" "$PATH"'
]

/** Drops any rc-file banner noise printed before the NUL sentinel. */
export function stripShellBanner(stdout: string): string {
  const idx = stdout.lastIndexOf('\u0000')
  return (idx === -1 ? stdout : stdout.slice(idx + 1)).trim()
}

/**
 * nvm keeps node installs (and their npm/npx/codex shims) out of well-known
 * prefixes entirely — `~/.nvm/versions/node/<v>/bin` only reaches PATH via
 * `.zshrc`. Probe those dirs directly so a corrupted login-shell PATH can't
 * hide an installed CLI. Newest version first.
 */
export function nvmBinDirs(
  platform: Platform = process.platform,
  env: NodeJS.ProcessEnv = process.env
): string[] {
  if (isWindows(platform)) return []
  const nvmDir =
    env['NVM_DIR'] !== undefined && env['NVM_DIR'] !== ''
      ? env['NVM_DIR']
      : joinPath(platform, homedir(), '.nvm')
  const versionsDir = joinPath(platform, nvmDir, 'versions', 'node')
  const numeric = (version: string): number[] =>
    version
      .replace(/^v/u, '')
      .split('.')
      .map((part) => Number.parseInt(part, 10) || 0)
  try {
    return readdirSync(versionsDir)
      .sort((a, b) => {
        const [aMaj = 0, aMin = 0, aPat = 0] = numeric(a)
        const [bMaj = 0, bMin = 0, bPat = 0] = numeric(b)
        return bMaj - aMaj || bMin - aMin || bPat - aPat
      })
      .map((version) => joinPath(platform, versionsDir, version, 'bin'))
  } catch {
    return []
  }
}

/**
 * Environment for probing or spawning a CLI candidate.
 *
 * Node-shim CLIs (`#!/usr/bin/env node` — every nvm/npm global install) need
 * `node` reachable from the CHILD's own PATH; a Finder-launched Electron only
 * carries launchd's minimal one, so probing such a shim dies at the shebang
 * with exit 127 and looks exactly like "not installed". Order matters: the
 * candidate's own dir first (its sibling `node`), then the login-shell PATH,
 * then whatever the process already had.
 */
export function augmentedPathEnv(
  candidatePath: string,
  loginShellPath: string | null,
  baseEnv: NodeJS.ProcessEnv = process.env,
  platform: Platform = process.platform
): NodeJS.ProcessEnv {
  const pathModule = isWindows(platform) ? win32Path : posixPath
  const dirs = [
    pathModule.dirname(candidatePath),
    ...(loginShellPath === null ? [] : splitPath(loginShellPath, platform)),
    ...splitPath(baseEnv['PATH'] ?? baseEnv['Path'] ?? '', platform)
  ]
  const result: NodeJS.ProcessEnv = {
    ...baseEnv,
    PATH: [...new Set(dirs)].join(pathModule.delimiter)
  }
  if (isWindows(platform)) {
    // Windows env var names are case-insensitive, but a JS env object is not:
    // if the base env spelled it `Path`, the child would receive BOTH `Path`
    // (stale) and `PATH` (augmented) and which one wins is undefined. Keep a
    // single canonical `PATH` key.
    delete result['Path']
  }
  return result
}

/**
 * Splits a PATH-like string into directories.
 *
 * `path.delimiter` is `;` on Windows and `:` elsewhere — but this module may be
 * asked about the *other* platform in tests, so the separator is derived from
 * the requested platform rather than the host.
 */
export function splitPath(
  value: string,
  platform: Platform = process.platform
): string[] {
  const sep = isWindows(platform) ? win32Path.delimiter : posixPath.delimiter
  return value.split(sep).filter((dir) => dir !== '')
}

/**
 * Spawns the CLI.
 *
 * `cross-spawn` rather than `{ shell: true }` on purpose. `shell: true` hands
 * the joined argv to `cmd.exe` **unescaped**, and our argv is not all
 * constants: `--append-system-prompt` carries `buildStudyPrompt(...)`, which
 * interpolates the course name the student typed. A course named
 * `물리학 & calc.exe` would then execute `calc.exe`. cross-spawn instead
 * escapes each argument for `cmd.exe` and passes
 * `windowsVerbatimArguments`, which is the same approach npm's own CLI uses.
 *
 * On non-Windows cross-spawn delegates straight to `child_process.spawn`, so
 * the POSIX path is unchanged.
 */
export interface SpawnClaudeOptions {
  cwd: string
  env: NodeJS.ProcessEnv
  /** Defaults to `['pipe', 'pipe', 'pipe']`. */
  stdio?: Array<'pipe' | 'ignore' | 'inherit'>
  /**
   * POSIX only: put the child in its own process group so teardown can signal
   * the CLI's helper processes too. Defaults to `true`. Forced off on Windows,
   * where `detached` pops a console window instead and `taskkill /T` handles
   * the tree.
   */
  detached?: boolean
  platform?: Platform
}

export function spawnClaude(
  file: string,
  args: string[],
  opts: SpawnClaudeOptions
): ChildProcess {
  const platform = opts.platform ?? process.platform
  const windows = isWindows(platform)
  const spawnFn = windows ? crossSpawn : nodeSpawn
  return spawnFn(file, args, {
    cwd: opts.cwd,
    env: opts.env,
    detached: windows ? false : (opts.detached ?? true),
    // Suppresses the console window that `.cmd` shims flash on Windows.
    windowsHide: true,
    stdio: opts.stdio ?? ['pipe', 'pipe', 'pipe']
  })
}

/**
 * Kills a spawned CLI **and its descendants**.
 *
 * The CLI spawns helper processes, so killing only the direct child leaves
 * orphans holding the course folder open — on Windows that also blocks the
 * NSIS updater from replacing files.
 *
 * Returns nothing and never throws: every caller is teardown code (including
 * `process.on('exit')`), where an already-dead process is the normal case.
 */
export function killProcessTree(
  pid: number,
  signal: NodeJS.Signals,
  platform: Platform = process.platform
): void {
  try {
    if (isWindows(platform)) {
      // No signals on Windows. /T = tree, /F = force. Synchronous so it is
      // usable from an exit handler, where async work never runs.
      spawnSync('taskkill', ['/pid', String(pid), '/T', '/F'], {
        windowsHide: true,
        stdio: 'ignore'
      })
      return
    }
    // Negative pid = "the whole process group", POSIX only.
    process.kill(-pid, signal)
  } catch {
    // Already gone, or the group vanished between check and signal.
  }
}

/**
 * Windows-safe probe runner for `--version` / auth-status checks.
 *
 * The binary locators used to probe with `promisify(execFile)`, which since
 * Node's CVE-2024-27980 fix throws EINVAL for `.cmd`/`.bat` shims spawned
 * without a shell — and npm's Windows install of claude/codex is EXACTLY such
 * a shim. Sessions already went through cross-spawn (`spawnClaude`); the
 * probes were the asymmetric gap that made an installed CLI read as
 * "not installed" on Windows.
 *
 * cross-spawn routes `.cmd`/`.bat` through `cmd.exe` with proper argument
 * escaping on Windows and delegates to plain `child_process.spawn` elsewhere,
 * so the POSIX behavior is unchanged.
 *
 * Contract matches `execFile`: resolves with `{ stdout, stderr }` on exit 0,
 * rejects on spawn failure (string `code` like 'ENOENT') and on non-zero exit
 * (numeric `code`, stdout/stderr attached) so existing parse/catch logic in
 * the locators keeps working. Timeouts kill the whole process tree — a hung
 * `.cmd` shim leaves a `cmd.exe` + `node` pair behind otherwise.
 */
export interface ProbeExecOptions {
  env?: NodeJS.ProcessEnv
  /** Defaults to PROBE_EXEC_TIMEOUT_MS. */
  timeoutMs?: number
  /** Injectable for tests — defaults to cross-spawn. */
  spawnFn?: typeof crossSpawn
}

export const PROBE_EXEC_TIMEOUT_MS = 10_000

export interface ProbeExecError extends Error {
  code?: number | string | null
  signal?: NodeJS.Signals | null
  stdout?: string
  stderr?: string
}

export function probeExec(
  file: string,
  args: string[],
  opts: ProbeExecOptions = {}
): Promise<{ stdout: string; stderr: string }> {
  const spawnFn = opts.spawnFn ?? crossSpawn
  const timeoutMs = opts.timeoutMs ?? PROBE_EXEC_TIMEOUT_MS
  return new Promise((resolve, reject) => {
    let child: ChildProcess
    try {
      child = spawnFn(file, args, {
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        // Own process group on POSIX so the timeout's group-kill reaches a
        // node-shim's children too. Forced off on Windows (console popup);
        // taskkill /T walks the tree there instead. Host platform on purpose —
        // this is a real child of THIS process even under injected-platform
        // tests. Same reasoning as spawnClaude above.
        detached: !isWindows(),
        ...(opts.env === undefined ? {} : { env: opts.env })
      })
    } catch (error) {
      reject(error instanceof Error ? error : new Error(String(error)))
      return
    }

    let stdout = ''
    let stderr = ''
    let settled = false
    let timedOut = false

    const finish = (fn: () => void): void => {
      if (settled) {
        return
      }
      settled = true
      clearTimeout(timer)
      fn()
    }

    const timer = setTimeout(() => {
      timedOut = true
      if (child.pid !== undefined) {
        killProcessTree(child.pid, 'SIGKILL')
      }
      // Belt and braces: if the group kill found nothing (e.g. an injected
      // spawnFn ignored `detached`), take out the direct child at least.
      child.kill('SIGKILL')
    }, timeoutMs)
    timer.unref()

    child.stdout?.on('data', (chunk: Buffer) => {
      stdout += chunk.toString('utf8')
    })
    child.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8')
    })
    child.once('error', (error) => finish(() => reject(error)))
    child.once('close', (code, signal) =>
      finish(() => {
        if (timedOut) {
          const err: ProbeExecError = new Error(
            `probe timed out after ${timeoutMs}ms: ${file}`
          )
          err.code = 'ETIMEDOUT'
          err.stdout = stdout
          err.stderr = stderr
          reject(err)
          return
        }
        if (code === 0) {
          resolve({ stdout, stderr })
          return
        }
        // execFile semantics: non-zero exit rejects, exit code on `code`.
        const err: ProbeExecError = new Error(
          `Command failed: ${file} ${args.join(' ')}\n${stderr}`
        )
        err.code = code ?? signal ?? null
        err.signal = signal
        err.stdout = stdout
        err.stderr = stderr
        reject(err)
      })
    )
  })
}
