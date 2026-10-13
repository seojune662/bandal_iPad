import { lookup } from 'node:dns/promises'
import { Agent, createServer, request } from 'node:http'
import type { IncomingHttpHeaders } from 'node:http'
import { createConnection, isIP } from 'node:net'
import type { Socket } from 'node:net'

export type ArticleHostResolver = (hostname: string) => Promise<readonly { address: string }[]>
const resolveHost: ArticleHostResolver = hostname => lookup(hostname, { all: true })
const SOCKET_TIMEOUT_MS = 20_000

function publicIpv4(address: string): boolean {
  const bytes = address.split('.').map(Number)
  const a = bytes[0]!, b = bytes[1]!, c = bytes[2]!
  return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
    (a === 192 && b === 0 && (c === 0 || c === 2)) ||
    (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) ||
    (a === 203 && b === 0 && c === 113))
}

export function isPublicArticleAddress(address: string): boolean {
  const normalized = address.toLowerCase().replace(/^\[|\]$/g, '')
  if (isIP(normalized) === 4) return publicIpv4(normalized)
  if (isIP(normalized) !== 6) return false
  const mapped = normalized.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/)
  if (mapped) return publicIpv4(mapped[1]!)
  return /^[23]/.test(normalized) && !/^2001:db8(?::|$)/.test(normalized) && !/^2001:0(?::|$)/.test(normalized)
}

async function resolvePublicTarget(input: string, resolver: ArticleHostResolver): Promise<{ url: URL; address: string }> {
  let url: URL
  try { url = new URL(input) } catch { throw new Error('기사 주소를 확인해 주세요.') }
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, '')
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
      !host || host === 'localhost' || /\.(localhost|local|internal|lan)$/.test(host) ||
      (!isIP(host) && !host.includes('.')) || (url.port && !['80', '443'].includes(url.port))) {
    throw new Error('공개된 HTTP 또는 HTTPS 기사 주소만 사용할 수 있어요.')
  }
  const addresses = isIP(host) ? [{ address: host }] : await resolver(host)
  if (!addresses.length || addresses.some(({ address }) => !isPublicArticleAddress(address))) {
    throw new Error('로컬 또는 비공개 네트워크의 기사는 자동으로 읽지 않아요.')
  }
  url.hash = ''
  return { url, address: addresses.find(item => isIP(item.address) === 4)?.address ?? addresses[0]!.address }
}

export async function validatePublicArticleUrl(input: string, resolver = resolveHost): Promise<string> {
  return (await resolvePublicTarget(input, resolver)).url.href
}

export interface PinnedArticleProxyDeps {
  resolveHost?: ArticleHostResolver
  /** The socket always receives an already-validated numeric IP, never a hostname. */
  connect?: (target: { host: string; port: number }) => Socket
}
export interface PinnedArticleProxy { proxyRules: string; close(): Promise<void> }

const HOP_HEADERS = new Set(['connection', 'proxy-connection', 'proxy-authorization', 'proxy-authenticate', 'keep-alive', 'transfer-encoding', 'te', 'trailer', 'upgrade'])
function forwardedHeaders(headers: IncomingHttpHeaders): IncomingHttpHeaders {
  const hop = new Set([...HOP_HEADERS, ...(headers.connection ?? '').toLowerCase().split(',').map(value => value.trim())])
  return Object.fromEntries(Object.entries(headers).filter(([key]) => !hop.has(key)))
}

/** A private, short-lived proxy pins each HTTP/CONNECT socket to validated public DNS answers. */
export async function createPinnedArticleProxy(deps: PinnedArticleProxyDeps = {}): Promise<PinnedArticleProxy> {
  const resolver = deps.resolveHost ?? resolveHost
  const connect = deps.connect ?? createConnection
  const sockets = new Set<Socket>()
  let closed = false
  const track = (socket: Socket): Socket => {
    if (closed) { socket.destroy(); return socket }
    sockets.add(socket)
    socket.once('close', () => sockets.delete(socket))
    socket.setTimeout(SOCKET_TIMEOUT_MS, () => socket.destroy())
    return socket
  }
  const server = createServer((incoming, response) => {
    void (async () => {
      if (closed || incoming.headers.authorization || incoming.headers['proxy-authorization']) throw new Error('Credentialed article request')
      const target = await resolvePublicTarget(incoming.url ?? '', resolver)
      if (closed || incoming.destroyed || response.destroyed || target.url.protocol !== 'http:' || (target.url.port && target.url.port !== '80')) throw new Error('Unsupported article proxy request')
      const agent = new Agent({ keepAlive: false })
      agent.createConnection = () => track(connect({ host: target.address, port: 80 }))
      const outgoing = request({ hostname: target.url.hostname, port: 80, path: `${target.url.pathname}${target.url.search}`,
        method: incoming.method, headers: { ...forwardedHeaders(incoming.headers), host: target.url.host }, agent }, upstream => {
        response.writeHead(upstream.statusCode ?? 502, forwardedHeaders(upstream.headers))
        upstream.on('error', () => response.destroy())
        upstream.pipe(response)
      })
      outgoing.on('error', () => { if (!response.headersSent) response.writeHead(502); response.end() })
      incoming.on('aborted', () => outgoing.destroy())
      response.on('close', () => { outgoing.destroy(); agent.destroy() })
      incoming.pipe(outgoing)
    })().catch(() => { if (!response.headersSent) response.writeHead(403); response.end() })
  })
  server.on('connection', track)
  server.on('upgrade', (_incoming, socket) => socket.destroy())
  server.on('connect', (incoming, client, head) => {
    void (async () => {
      if (closed || incoming.headers.authorization || incoming.headers['proxy-authorization']) throw new Error('Credentialed article tunnel')
      const authority = incoming.url ?? ''
      // CONNECT must be an authority, not an alternate URL or a request path.
      if (!authority || /[\s/?#]/u.test(authority)) throw new Error('Invalid article tunnel')
      const target = await resolvePublicTarget(`https://${authority}`, resolver)
      if (closed || client.destroyed || target.url.port && target.url.port !== '443') throw new Error('Unsupported article tunnel port')
      const upstream = track(connect({ host: target.address, port: 443 }))
      upstream.once('connect', () => {
        if (closed || client.destroyed) { upstream.destroy(); return }
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n')
        if (head.length) upstream.write(head)
        upstream.pipe(client)
        client.pipe(upstream)
      })
      upstream.on('error', () => client.destroy())
      client.on('error', () => upstream.destroy())
      client.on('close', () => upstream.destroy())
    })().catch(() => { if (!client.destroyed) client.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n') })
  })
  server.headersTimeout = SOCKET_TIMEOUT_MS
  server.requestTimeout = SOCKET_TIMEOUT_MS
  server.on('clientError', (_error, socket) => socket.destroy())
  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => reject(error)
    server.once('error', onError)
    server.listen(0, '127.0.0.1', () => { server.off('error', onError); resolve() })
  })
  server.unref()
  const address = server.address()
  if (!address || typeof address === 'string') { server.close(); throw new Error('기사 연결을 준비하지 못했어요.') }
  return {
    proxyRules: `http=127.0.0.1:${address.port};https=127.0.0.1:${address.port}`,
    async close() {
      if (closed) return
      closed = true
      for (const socket of sockets) socket.destroy()
      sockets.clear()
      await new Promise<void>(resolve => server.close(() => resolve()))
    }
  }
}
