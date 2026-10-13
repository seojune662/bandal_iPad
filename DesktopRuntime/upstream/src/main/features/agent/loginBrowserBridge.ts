import { randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AgentProvider } from '../../../shared/types/agent-events'
import type { Platform } from './platform'

/** Only authorization pages supplied by the provider CLI may open automatically. */
export function isProviderLoginUrl(provider: AgentProvider, value: string): boolean {
  try {
    const url = new URL(value)
    const hosts = provider === 'codex'
      ? ['auth.openai.com', 'chatgpt.com']
      : provider === 'claude-code'
        ? ['claude.com', 'claude.ai', 'platform.claude.com', 'console.anthropic.com']
        : []
    return value.length <= 16_384 && url.protocol === 'https:' && hosts.includes(url.hostname) &&
      !url.username && !url.password && (!url.port || url.port === '443') &&
      /(?:oauth|authorize|auth\/)/iu.test(url.pathname)
  } catch { return false }
}

export interface LoginBrowserBridge {
  browserPath: string
  dispose(): Promise<void>
}

/**
 * Claude's BROWSER hook receives the automatic localhost-callback URL, while
 * stdout deliberately contains a different, manual-code URL. Relay that hook
 * through a one-use local helper. Neither URL nor login code is written to disk;
 * temporary files contain only our helper and a random loopback capability.
 * The app's bundled runtime means a student does not need Node, curl or Python.
 */
export async function createLoginBrowserBridge(
  onUrl: (url: string) => void,
  options: { platform?: Platform; executable?: string } = {}
): Promise<LoginBrowserBridge> {
  const platform = options.platform ?? process.platform
  const executable = options.executable ?? process.execPath
  const directory = await mkdtemp(join(tmpdir(), 'bandal-login-'))
  const token = randomBytes(32).toString('hex')
  let disposed = false
  const server = createServer((request, response) => {
    if (request.method !== 'POST' || request.url !== `/${token}` || request.headers.origin) {
      response.writeHead(403).end(); request.resume(); return
    }
    let body = ''
    request.setEncoding('utf8')
    request.on('data', (chunk: string) => {
      body += chunk
      if (body.length > 16_384) request.destroy()
    })
    request.on('error', () => undefined)
    request.on('end', () => {
      if (disposed || !isProviderLoginUrl('claude-code', body)) { response.writeHead(400).end(); return }
      response.writeHead(204).end()
      onUrl(body)
    })
  })
  const dispose = async (): Promise<void> => {
    if (disposed) return
    disposed = true
    server.closeAllConnections()
    server.close()
    await rm(directory, { recursive: true, force: true })
  }
  try {
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', () => { server.off('error', reject); resolve() })
    })
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('로그인 브라우저 연결을 준비하지 못했어요.')
    const helper = join(directory, 'browser.cjs')
    await writeFile(helper, `const http = require('node:http');
const url = process.argv[2] || '';
const request = http.request({ hostname: '127.0.0.1', port: ${address.port}, path: '/${token}', method: 'POST', headers: { 'content-type': 'text/plain', 'content-length': Buffer.byteLength(url) } }, response => { response.resume(); response.on('end', () => process.exit(response.statusCode === 204 ? 0 : 1)); });
request.on('error', () => process.exit(1));
request.setTimeout(5000, () => { request.destroy(); process.exit(1); });
request.end(url);
`, { mode: 0o600 })
    const browserPath = join(directory, platform === 'win32' ? 'browser.cmd' : 'browser')
    const quote = (value: string): string => `'${value.replace(/'/gu, `'"'"'`)}'`
    await writeFile(browserPath, platform === 'win32'
      ? `@echo off\r\nsetlocal\r\nchcp 65001 >nul\r\nset "ELECTRON_RUN_AS_NODE=1"\r\n"${executable.replace(/%/gu, '%%')}" "${helper.replace(/%/gu, '%%')}" %*\r\n`
      : `#!/bin/sh\nELECTRON_RUN_AS_NODE=1 exec ${quote(executable)} ${quote(helper)} "$@"\n`, { mode: 0o700 })
    return { browserPath, dispose }
  } catch (error) { await dispose(); throw error }
}
