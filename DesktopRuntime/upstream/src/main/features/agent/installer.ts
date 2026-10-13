/** Provider CLI installers, invoked only by the explicit setup-card click. */

import { spawnSync, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { stripVTControlCharacters } from 'node:util'
import type { AgentInstallProgress } from '../../../shared/ipc/events'
import type { AgentProvider } from '../../../shared/types/agent-events'
import { createBinaryLocator, type BinaryLocator } from './binaryLocator'
import { createCodexBinaryLocator } from './codex/binaryLocator'
import { createGeminiBinaryLocator } from './gemini/binaryLocator'
import { requireProtocolVersion } from './protocolAvailability'
import {
  augmentedPathEnv,
  killProcessTree,
  LOGIN_SHELL_PATH_ARGS,
  nvmBinDirs,
  spawnClaude,
  stripShellBanner,
  type Platform
} from './platform'

export const CLAUDE_INSTALL_COMMAND =
  'curl -fsSL https://claude.ai/install.sh | bash'
/** Windows equivalent of the official installer, run via powershell.exe. */
export const CLAUDE_INSTALL_COMMAND_WINDOWS =
  'irm https://claude.ai/install.ps1 | iex'
export const CODEX_INSTALL_COMMAND =
  'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
export const CODEX_INSTALL_COMMAND_WINDOWS =
  'irm https://chatgpt.com/codex/install.ps1 | iex'
export const GEMINI_INSTALL_COMMAND = 'npm install -g @google/gemini-cli'
export const AGENT_INSTALL_TIMEOUT_MS = 5 * 60 * 1000

function loginShellPathSync(): string | null {
  if (process.platform === 'win32') {
    return process.env['PATH'] ?? process.env['Path'] ?? null
  }
  const result = spawnSync('/bin/zsh', [...LOGIN_SHELL_PATH_ARGS], {
    encoding: 'utf8',
    windowsHide: true,
    timeout: 10_000
  })
  const path = result.status === 0 ? stripShellBanner(result.stdout) : ''
  return path !== '' ? path : (process.env['PATH'] ?? null)
}

function resolveNpmSync(): string | null {
  if (process.platform === 'win32') {
    const found = spawnSync('where.exe', ['npm'], {
      encoding: 'utf8',
      windowsHide: true
    })
    return found.status === 0
      ? (found.stdout.split(/\r?\n/u).find((line) => line.trim() !== '')?.trim() ?? null)
      : null
  }

  // Electron launched from Finder has launchd's minimal PATH. Ask the same
  // login shell used by the binary locators so an nvm/homebrew npm is found.
  // NUL sentinel + stripShellBanner: rc-file banners print BEFORE our output,
  // and taking the first line here once turned ASCII art into "the npm path".
  const found = spawnSync(
    '/bin/zsh',
    ['-lic', 'printf "\\0%s" "$(command -v npm)"'],
    {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 10_000
    }
  )
  if (found.status === 0) {
    const npmPath = stripShellBanner(found.stdout)
    if (npmPath.startsWith('/')) return npmPath
  }
  // Login shell failed or npm is not on its PATH — probe nvm installs directly.
  for (const dir of nvmBinDirs()) {
    const candidate = `${dir}/npm`
    if (existsSync(candidate)) return candidate
  }
  const inherited = spawnSync('npm', ['--version'], {
    encoding: 'utf8',
    windowsHide: true,
    timeout: 10_000
  })
  return inherited.status === 0 ? 'npm' : null
}

function forwardLines(
  child: ChildProcess,
  provider: AgentProvider,
  broadcast: (progress: AgentInstallProgress) => void,
  recentLines: string[]
): () => void {
  const carries = new Map<'stdout' | 'stderr', string>([
    ['stdout', ''],
    ['stderr', '']
  ])

  const report = (line: string): void => {
    const clean = stripVTControlCharacters(line).trim()
    if (clean === '') return
    recentLines.push(clean)
    if (recentLines.length > 20) recentLines.shift()
    broadcast({ provider, line: clean, done: false, ok: false })
  }
  const listeners = new Map<'stdout' | 'stderr', (chunk: Buffer) => void>()
  const listen = (kind: 'stdout' | 'stderr'): void => {
    const listener = (chunk: Buffer): void => {
      const combined = `${carries.get(kind) ?? ''}${chunk.toString('utf8')}`
      const lines = combined.split(/\r\n|\r|\n/u)
      carries.set(kind, (lines.pop() ?? '').slice(-8192))
      for (const line of lines) {
        report(line)
      }
    }
    listeners.set(kind, listener)
    child[kind]?.on('data', listener)
  }
  listen('stdout')
  listen('stderr')

  return () => {
    for (const kind of ['stdout', 'stderr'] as const) {
      const tail = carries.get(kind) ?? ''
      if (tail !== '') {
        report(tail)
      }
      carries.set(kind, '')
      const listener = listeners.get(kind)
      if (listener !== undefined) child[kind]?.off('data', listener)
    }
  }
}

async function verifyInstalled(locator: BinaryLocator, provider: AgentProvider): Promise<boolean> {
  locator.reset()
  try {
    const binary = await locator.locate()
    return provider === 'claude-code' || requireProtocolVersion({ installed: true, loggedIn: false, version: binary.version }, provider).code === undefined
  } catch {
    return false
  }
}

/**
 * Creates the installer IPC implementation.
 *
 * The user's connect/install click authorizes the official installer. Codex
 * and Claude use standalone native installers, so no Node, npm, administrator
 * prompt or terminal setup is required. The UI can show commandFor() in its
 * optional details. Concurrent clicks share one run, bounded to five minutes.
 */
export function createAgentInstaller(deps?: {
  broadcast?: (p: AgentInstallProgress) => void
  /**
   * The SAME locator instances registerHandlers serves `agent:availability`
   * from. Install verification calls `reset()` on these, so passing private
   * copies here would leave the served singletons caching "not installed"
   * after a successful install. Defaults exist only for tests.
   */
  locators?: Record<AgentProvider, BinaryLocator>
  /** Injectable process boundaries for clean-machine and cross-platform tests. */
  platform?: Platform
  env?: NodeJS.ProcessEnv
  spawn?: typeof spawnClaude
  kill?: typeof killProcessTree
  resolveNpm?: () => string | null
}): {
  commandFor(provider: AgentProvider): { command: string; supported: boolean }
  install(provider: AgentProvider): Promise<{ ok: boolean; message: string }>
} {
  const broadcast = deps?.broadcast ?? (() => undefined)
  const platform = deps?.platform ?? process.platform
  const baseEnv = deps?.env ?? process.env
  const spawn = deps?.spawn ?? spawnClaude
  const kill = deps?.kill ?? killProcessTree
  const resolveNpm = deps?.resolveNpm ?? resolveNpmSync
  const pending = new Map<AgentProvider, Promise<{ ok: boolean; message: string }>>()
  const locators: Record<AgentProvider, BinaryLocator> = deps?.locators ?? {
    'claude-code': createBinaryLocator(),
    codex: createCodexBinaryLocator(),
    gemini: createGeminiBinaryLocator()
  }

  function commandFor(
    provider: AgentProvider
  ): { command: string; supported: boolean } {
    if (provider !== 'gemini') {
      const command = provider === 'claude-code'
        ? platform === 'win32' ? CLAUDE_INSTALL_COMMAND_WINDOWS : CLAUDE_INSTALL_COMMAND
        : platform === 'win32' ? CODEX_INSTALL_COMMAND_WINDOWS : CODEX_INSTALL_COMMAND
      return { command, supported: ['darwin', 'linux', 'win32'].includes(platform) }
    }
    return {
      command: GEMINI_INSTALL_COMMAND,
      supported: resolveNpm() !== null
    }
  }

  async function runInstall(
    provider: AgentProvider
  ): Promise<{ ok: boolean; message: string }> {
    const announced = commandFor(provider)
    if (!announced.supported) {
      const message = provider === 'gemini'
        ? 'npm을 찾지 못해 Gemini를 자동 설치할 수 없습니다.'
        : '이 운영체제에서는 자동 설치를 지원하지 않습니다.'
      broadcast({ provider, line: message, done: true, ok: false })
      return { ok: false, message }
    }

    let file: string
    let args: string[]
    if (provider !== 'gemini') {
      if (platform === 'win32') {
        // The announced constant command, verbatim — no user input reaches
        // this string. -NoProfile keeps user profiles from hijacking it.
        file = 'powershell.exe'
        args = [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          `$ErrorActionPreference = 'Stop'; ${announced.command}`
        ]
      } else {
        // A failed curl must not become a successful empty shell execution.
        file = '/bin/bash'
        args = ['-o', 'pipefail', '-c', announced.command]
      }
    } else {
      const npmPath = resolveNpm()
      if (npmPath === null) {
        const message = 'npm을 찾지 못해 Gemini를 자동 설치할 수 없습니다.'
        broadcast({ provider, line: message, done: true, ok: false })
        return { ok: false, message }
      }
      file = npmPath
      args = [
        'install',
        '-g',
        '@google/gemini-cli'
      ]
    }

    let child: ChildProcess
    try {
      // npm installed by nvm uses `#!/usr/bin/env node`; the child's PATH
      // must reach both the npm shim's own dir (sibling `node`) and the
      // login-shell PATH, even when the latter could not be captured.
      const loginPath = provider === 'gemini'
        ? loginShellPathSync()
        : platform === 'win32' ? null : '/usr/bin:/bin:/usr/sbin:/sbin'
      const env = file.startsWith('/')
        ? augmentedPathEnv(file, loginPath, baseEnv, platform)
        : (() => {
            const base: NodeJS.ProcessEnv = { ...baseEnv }
            if (loginPath !== null) base['PATH'] = loginPath
            return base
          })()
      // The official Codex installer otherwise offers launch/uninstall prompts.
      // Skip them and preserve any older package-manager installation.
      if (provider === 'codex') env['CODEX_NON_INTERACTIVE'] = '1'
      child = spawn(file, args, {
        cwd: tmpdir(),
        env,
        stdio: ['ignore', 'pipe', 'pipe'],
        platform
      })
    } catch (error) {
      const message = `설치 프로그램을 시작하지 못했습니다: ${error instanceof Error ? error.message : String(error)}`
      broadcast({ provider, line: message, done: true, ok: false })
      return { ok: false, message }
    }

    broadcast({
      provider,
      line: `${provider === 'codex' ? 'ChatGPT' : provider === 'claude-code' ? 'Claude' : 'Gemini'} 연결에 필요한 프로그램을 설치하고 있어요. 잠시만 기다려 주세요.`,
      done: false,
      ok: false
    })
    const recentLines: string[] = []
    const flushLines = forwardLines(child, provider, broadcast, recentLines)

    const processResult = await new Promise<{
      code: number | null
      signal: NodeJS.Signals | null
      error?: Error
      timedOut: boolean
    }>((resolve) => {
      let settled = false
      const finish = (result: {
        code: number | null
        signal: NodeJS.Signals | null
        error?: Error
        timedOut: boolean
      }): void => {
        if (settled) {
          return
        }
        settled = true
        clearTimeout(timer)
        flushLines()
        resolve(result)
      }
      const timer = setTimeout(() => {
        if (child.pid !== undefined) {
          kill(child.pid, 'SIGKILL', platform)
        }
        finish({ code: null, signal: 'SIGKILL', timedOut: true })
      }, AGENT_INSTALL_TIMEOUT_MS)
      timer.unref()

      child.once('error', (error) =>
        finish({ code: null, signal: null, error, timedOut: false })
      )
      child.once('close', (code, signal) =>
        finish({ code, signal, timedOut: false })
      )
    })

    let ok = false
    let message: string
    if (processResult.timedOut) {
      message = '다운로드가 오래 걸려 설치를 중단했어요. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.'
    } else if (processResult.error !== undefined) {
      message = `설치 중 오류가 발생했습니다: ${processResult.error.message}`
    } else if (processResult.code !== 0) {
      const detail = recentLines.slice(-3).join('\n')
      message = `설치를 완료하지 못했어요. 다시 시도해 주세요.${detail === '' ? '' : `\n${detail}`}`
    } else {
      broadcast({ provider, line: '설치가 끝났어요. 연결 준비가 되었는지 확인하고 있어요.', done: false, ok: false })
      ok = await verifyInstalled(locators[provider], provider)
      message = ok
        ? `${provider === 'claude-code' ? 'Claude Code' : provider === 'codex' ? 'Codex' : 'Gemini'} 설치를 확인했습니다.`
        : '설치된 프로그램을 실행하지 못했어요. 다시 시도하면 설치 상태를 다시 확인합니다.'
    }

    broadcast({ provider, line: message, done: true, ok })
    return { ok, message }
  }

  function install(provider: AgentProvider): Promise<{ ok: boolean; message: string }> {
    const existing = pending.get(provider)
    if (existing !== undefined) return existing
    const result = runInstall(provider).finally(() => { pending.delete(provider) })
    pending.set(provider, result)
    return result
  }

  return { commandFor, install }
}
