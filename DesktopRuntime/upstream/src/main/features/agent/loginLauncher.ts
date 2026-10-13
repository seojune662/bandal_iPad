/** Managed provider login: credentials stay with the CLI, browser UI stays in Bandal. */
import { spawn as nodeSpawn, type ChildProcess } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { homedir } from 'node:os'
import type { AgentLoginProgress, AgentProvider } from '../../../shared/types/agent-events'
import type { BinaryLocator } from './binaryLocator'
import { augmentedPathEnv, killProcessTree, spawnClaude, type Platform } from './platform'
import { createJsonRpc, RpcResponseError, type RpcMessage } from './jsonRpc'
import { createLoginBrowserBridge, isProviderLoginUrl, type LoginBrowserBridge } from './loginBrowserBridge'

export const LOGIN_TIMEOUT_MS = 10 * 60 * 1000
const URL_WAIT_MS = 25_000
interface LoginResult { ok: boolean; message: string; requiresUpdate?: boolean }
export interface LoginLauncherDeps {
  locators: Record<AgentProvider, BinaryLocator>
  broadcast?: (progress: AgentLoginProgress) => void
  openBrowser?: (url: string, context: { provider: AgentProvider; requestId: string }) => void | Promise<void>
  openExternal?: (url: string) => Promise<void>
  platform?: Platform
  env?: NodeJS.ProcessEnv
  spawnFn?: typeof nodeSpawn
  spawnCli?: typeof spawnClaude
  createBrowserBridge?: typeof createLoginBrowserBridge
  killTree?: typeof killProcessTree
  timeoutMs?: number
}
export interface LoginLauncher {
  /** Resolves only when credentials are verified, or the attempt ends. */
  login(provider: AgentProvider, requestId?: string): Promise<LoginResult>
  cancel(provider: AgentProvider, requestId?: string): { ok: boolean }
  reopen(provider: AgentProvider, external?: boolean, requestId?: string): Promise<LoginResult>
  submitCode(provider: AgentProvider, code: string, requestId?: string): LoginResult
  dispose(): void
}
interface Attempt {
  provider: AgentProvider
  requestId: string
  promise: Promise<LoginResult>
  finish: (result: LoginResult, stage?: 'done' | 'error' | 'cancelled') => void
  child?: ChildProcess
  rpc?: ReturnType<typeof createJsonRpc>
  bridge?: LoginBrowserBridge
  loginId?: string
  url?: string
  timer?: ReturnType<typeof setTimeout>
  urlTimer?: ReturnType<typeof setTimeout>
  pollTimer?: ReturnType<typeof setTimeout>
  settled: boolean
  verifying: boolean
  manualUrl?: string
}

/** Retained only for Gemini's interactive CLI, which has no standalone login command. */
export function loginShellCommand(provider: AgentProvider, binaryPath: string): string {
  return provider === 'codex' ? `"${binaryPath}" login` : `"${binaryPath}"`
}

export function createLoginLauncher(deps: LoginLauncherDeps): LoginLauncher {
  const platform = deps.platform ?? process.platform
  const spawn = deps.spawnCli ?? spawnClaude
  const active = new Map<AgentProvider, Attempt>()
  const kill = deps.killTree ?? killProcessTree
  const emit = (attempt: Attempt, stage: AgentLoginProgress['stage'], message: string): void => {
    deps.broadcast?.({ provider: attempt.provider, requestId: attempt.requestId, stage, message,
      ...(attempt.url && stage === 'waiting-browser' ? { url: attempt.url, requiresCode: attempt.provider === 'claude-code' } : {}) })
  }
  const current = (attempt: Attempt): boolean => !attempt.settled && active.get(attempt.provider) === attempt
  const terminate = (attempt: Attempt): void => {
    const child = attempt.child
    if (attempt.rpc && attempt.loginId && !attempt.rpc.closed) {
      // Write cancellation before closing stdin so the provider can release its callback.
      void attempt.rpc.request('account/login/cancel', { loginId: attempt.loginId }, 1000).catch(() => undefined)
    }
    attempt.rpc?.dispose()
    const pid = child?.pid
    if (pid) kill(pid, 'SIGTERM', platform)
    if (child) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM')
      const force = setTimeout(() => {
        // A POSIX CLI may exit first while a descendant keeps the process group alive.
        if (pid && platform !== 'win32') kill(pid, 'SIGKILL', platform)
        if (child.exitCode === null && child.signalCode === null) {
          if (pid && platform === 'win32') kill(pid, 'SIGKILL', platform)
          child.kill('SIGKILL')
        }
      }, 2000)
      force.unref()
    }
    void attempt.bridge?.dispose().catch(() => undefined)
  }
  const fail = (attempt: Attempt, message = '로그인을 완료하지 못했어요. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.'): void => {
    attempt.finish({ ok: false, message })
  }
  const verify = async (attempt: Attempt): Promise<void> => {
    if (!current(attempt) || attempt.verifying) return
    attempt.verifying = true
    emit(attempt, 'verifying', '로그인을 확인하고 있어요.')
    try {
      deps.locators[attempt.provider].reset()
      const availability = await deps.locators[attempt.provider].availability()
      if (!current(attempt)) return
      if (availability.installed && availability.loggedIn) attempt.finish({ ok: true, message: '연결됐어요. 이제 반달에서 바로 사용할 수 있어요.' })
      else fail(attempt, '로그인 정보를 아직 확인하지 못했어요. 다시 연결해 주세요.')
    } catch { fail(attempt, '로그인 확인에 실패했어요. 다시 연결해 주세요.') }
  }
  const open = async (attempt: Attempt, url: string): Promise<void> => {
    if (!current(attempt) || !isProviderLoginUrl(attempt.provider, url) || attempt.url === url) return
    attempt.url = url
    clearTimeout(attempt.urlTimer)
    emit(attempt, 'waiting-browser', '반달 브라우저에서 로그인해 주세요. 완료되면 자동으로 연결돼요.')
    try { await deps.openBrowser?.(url, { provider: attempt.provider, requestId: attempt.requestId }) } catch { fail(attempt, '로그인 페이지를 열지 못했어요. 다시 연결해 주세요.') }
  }
  const runCodex = async (attempt: Attempt, path: string, env: NodeJS.ProcessEnv): Promise<void> => {
    const child = spawn(path, ['app-server'], { cwd: homedir(), env, platform })
    attempt.child = child
    child.stderr?.on('data', () => undefined) // Provider diagnostics can contain OAuth URLs; never persist them.
    const earlyNotifications: RpcMessage[] = []
    const receive = (message: RpcMessage): void => {
      if (!current(attempt)) return
      if (message.id !== undefined) { attempt.rpc?.reject(message.id, '로그인 중에는 이 요청을 처리하지 않아요.'); return }
      if (message.method !== 'account/login/completed') return
      if (!attempt.loginId) { earlyNotifications.push(message); return }
      if (message.params?.loginId !== attempt.loginId) return
      if (message.params.success === true) void verify(attempt)
      else fail(attempt, '로그인이 완료되지 않았어요. 다시 연결해 주세요.')
    }
    const rpc = createJsonRpc(child, receive, () => {
      if (current(attempt) && !attempt.verifying) fail(attempt, '로그인 연결이 종료됐어요. 다시 연결해 주세요.')
    })
    attempt.rpc = rpc
    await rpc.request('initialize', { clientInfo: { name: 'bandal', title: 'Bandal', version: '1.0.0' }, capabilities: {} })
    if (!current(attempt)) return
    rpc.notify('initialized')
    const result = await rpc.request('account/login/start', { type: 'chatgpt' })
    if (!current(attempt)) return
    if (typeof result?.loginId !== 'string' || typeof result?.authUrl !== 'string' || !isProviderLoginUrl('codex', result.authUrl)) {
      fail(attempt, 'ChatGPT 로그인 페이지를 준비하지 못했어요. Codex를 업데이트한 뒤 다시 연결해 주세요.'); return
    }
    attempt.loginId = result.loginId
    await open(attempt, result.authUrl)
    for (const message of earlyNotifications) receive(message)
  }
  const runClaude = async (attempt: Attempt, path: string, env: NodeJS.ProcessEnv): Promise<void> => {
    const bridge = await (deps.createBrowserBridge ?? createLoginBrowserBridge)(url => { void open(attempt, url) }, { platform })
    if (!current(attempt)) { await bridge.dispose(); return }
    attempt.bridge = bridge
    const child = spawn(path, ['auth', 'login', '--claudeai'], {
      cwd: homedir(), env: { ...env, BROWSER: bridge.browserPath, FORCE_HYPERLINK: '0', NO_COLOR: '1' }, platform
    })
    attempt.child = child
    // Keep stdin open for the provider's official manual-code fallback.
    child.stdin?.on('error', () => { if (current(attempt)) fail(attempt) })
    let output = ''
    const consume = (chunk: Buffer | string): void => {
      if (!current(attempt)) return
      output = (output + chunk.toString()).slice(-32_768)
      // Buffer across chunks and wait for a terminator, avoiding a truncated OAuth URL.
      for (const match of output.matchAll(/https:\/\/[^\s<>"'\u001b]+(?=[\s<>"'\u001b])/gu)) {
        if (isProviderLoginUrl('claude-code', match[0])) attempt.manualUrl = match[0]
      }
      if (/Invalid code/iu.test(output) && attempt.url) {
        emit(attempt, 'waiting-browser', '코드를 확인해 주세요. 브라우저에 표시된 전체 코드를 다시 붙여 넣어 주세요.')
        output = ''
      }
    }
    child.stdout?.on('data', consume)
    child.stderr?.on('data', consume)
    child.once('error', () => { if (current(attempt)) fail(attempt, 'Claude 로그인 실행에 실패했어요. 업데이트한 뒤 다시 연결해 주세요.') })
    child.once('close', code => {
      output = ''
      if (!current(attempt)) return
      if (code === 0) void verify(attempt)
      else fail(attempt, 'Claude 로그인이 완료되지 않았어요. 다시 연결해 주세요.')
    })
    attempt.urlTimer = setTimeout(() => {
      if (!current(attempt) || attempt.url) return
      if (attempt.manualUrl) void open(attempt, attempt.manualUrl)
      else fail(attempt, '로그인 페이지 준비 시간이 초과됐어요. 인터넷 연결을 확인하고 다시 연결해 주세요.')
    }, URL_WAIT_MS)
    attempt.urlTimer.unref()
  }
  const runGemini = async (attempt: Attempt, path: string): Promise<void> => {
    const spawnTerminal = deps.spawnFn ?? nodeSpawn
    const command = loginShellCommand('gemini', path)
    const escaped = command.replace(/\\/gu, '\\\\').replace(/"/gu, '\\"')
    const child = platform === 'darwin'
      ? spawnTerminal('osascript', ['-e', `tell application "Terminal" to do script "${escaped}"`, '-e', 'tell application "Terminal" to activate'], { detached: true, stdio: 'ignore' })
      : platform === 'win32'
        ? spawnTerminal(`start "" cmd /k ${command}`, { shell: true, detached: true, stdio: 'ignore' })
        : spawnTerminal('x-terminal-emulator', ['-e', 'sh', '-c', `${command}; exec sh`], { detached: true, stdio: 'ignore' })
    child.once('error', () => fail(attempt, '로그인 창을 열지 못했어요. Gemini API 키로 연결할 수도 있어요.'))
    child.once('spawn', () => {
      child.unref()
      if (!current(attempt)) return
      emit(attempt, 'waiting-browser', '열린 터미널에서 Gemini 로그인을 완료해 주세요. 완료되면 자동으로 연결돼요.')
      const poll = async (): Promise<void> => {
        if (!current(attempt)) return
        const availability = await deps.locators.gemini.availability().catch(() => null)
        if (!current(attempt)) return
        if (availability?.loggedIn) { await verify(attempt); return }
        attempt.pollTimer = setTimeout(() => { void poll() }, 2000)
        attempt.pollTimer.unref()
      }
      void poll()
    })
  }
  const login = (provider: AgentProvider, requestedId?: string): Promise<LoginResult> => {
    const existing = active.get(provider)
    if (existing) return existing.promise
    let resolve!: (result: LoginResult) => void
    const promise = new Promise<LoginResult>(done => { resolve = done })
    const attempt: Attempt = {
      provider, requestId: requestedId ?? randomUUID(), promise, settled: false, verifying: false,
      finish(result, stage = result.ok ? 'done' : 'error') {
        if (!current(attempt)) return
        attempt.settled = true
        clearTimeout(attempt.timer); clearTimeout(attempt.urlTimer); clearTimeout(attempt.pollTimer)
        active.delete(provider)
        emit(attempt, stage, result.message)
        delete attempt.url; delete attempt.manualUrl
        terminate(attempt)
        resolve(result)
      }
    }
    active.set(provider, attempt)
    emit(attempt, 'starting', '로그인 페이지를 준비하고 있어요.')
    attempt.timer = setTimeout(() => fail(attempt, '로그인 시간이 초과됐어요. 다시 연결하면 새 로그인 페이지가 열려요.'), deps.timeoutMs ?? LOGIN_TIMEOUT_MS)
    attempt.timer.unref()
    void (async () => {
      try {
        const locator = deps.locators[provider]
        const binary = await locator.locate()
        if (!current(attempt)) return
        // 2.1.41 introduced auth subcommands; 2.1.126 added the manual-code
        // fallback needed when a browser callback is unavailable. Older CLIs
        // keep working for chat, but connection repairs upgrade before login.
        const version = /^(\d+)\.(\d+)\.(\d+)/u.exec(binary.version)
        if (provider === 'claude-code' && (!version || Number(version[1]) < 2 ||
          (Number(version[1]) === 2 && (Number(version[2]) < 1 || (Number(version[2]) === 1 && Number(version[3]) < 126))))) {
          attempt.finish({ ok: false, requiresUpdate: true, message: '반달 안에서 로그인하려면 Claude를 업데이트해야 해요.' })
          return
        }
        const shellPath = await locator.loginShellPath()
        if (!current(attempt)) return
        const env = augmentedPathEnv(binary.path, shellPath, deps.env ?? process.env, platform)
        if (provider === 'codex') await runCodex(attempt, binary.path, env)
        else if (provider === 'claude-code') await runClaude(attempt, binary.path, env)
        else await runGemini(attempt, binary.path)
      } catch (error) {
        if (!current(attempt)) return
        if (error instanceof RpcResponseError && error.rpcCode === -32601) {
          attempt.finish({ ok: false, requiresUpdate: true, message: '반달 안에서 로그인하려면 Codex를 업데이트해야 해요.' })
        } else fail(attempt, '로그인을 시작하지 못했어요. 설치 상태와 인터넷 연결을 확인하고 다시 연결해 주세요.')
      }
    })()
    return promise
  }
  const find = (provider: AgentProvider, requestId?: string): Attempt | undefined => {
    const attempt = active.get(provider)
    return attempt && (requestId === undefined || attempt.requestId === requestId) ? attempt : undefined
  }
  return {
    login,
    cancel(provider, requestId) {
      const attempt = find(provider, requestId)
      if (!attempt) return { ok: false }
      attempt.finish({ ok: false, message: '연결을 취소했어요. 언제든 다시 연결할 수 있어요.' }, 'cancelled')
      return { ok: true }
    },
    async reopen(provider, external = false, requestId) {
      const attempt = find(provider, requestId)
      if (!attempt?.url) return { ok: false, message: '로그인 페이지가 만료됐어요. 다시 연결해 주세요.' }
      try {
        if (external) {
          if (!deps.openExternal) throw new Error('unavailable')
          await deps.openExternal(attempt.url)
        } else await deps.openBrowser?.(attempt.url, { provider, requestId: attempt.requestId })
        return { ok: true, message: external ? '기본 브라우저에서 로그인해 주세요. 완료되면 자동으로 연결돼요.' : '반달 브라우저에서 로그인을 이어가 주세요.' }
      } catch { return { ok: false, message: '로그인 페이지를 열지 못했어요. 다시 시도해 주세요.' } }
    },
    submitCode(provider, code, requestId) {
      const attempt = find(provider, requestId)
      if (provider !== 'claude-code' || !attempt?.url || !attempt.child?.stdin?.writable) return { ok: false, message: '진행 중인 Claude 로그인이 없어요. 다시 연결해 주세요.' }
      const value = code.trim()
      if (!/^[A-Za-z0-9_-]+#[A-Za-z0-9_-]+$/u.test(value) || value.length > 4096) return { ok: false, message: '브라우저에 표시된 전체 로그인 코드를 붙여 넣어 주세요.' }
      attempt.child.stdin.write(value + '\n')
      emit(attempt, 'verifying', '로그인 코드를 확인하고 있어요.')
      return { ok: true, message: '로그인 코드를 확인하고 있어요.' }
    },
    dispose() {
      for (const attempt of [...active.values()]) attempt.finish({ ok: false, message: '앱을 종료해 로그인을 취소했어요.' }, 'cancelled')
    }
  }
}
