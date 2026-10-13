/** Plugin execution uses Chromium's OS sandbox, never Node's vm. */
import { EventEmitter } from 'node:events'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { session, WebContentsView } from 'electron'
import { createHostRuntime } from '../../pluginHost/runtime'
import { PLUGIN_RPC_LIMITS, PLUGIN_RPC_PROTOCOL_VERSION, type MainToHost } from '../../../shared/types/pluginRpc'

const CHANNEL = 'bandal-plugin-host:message'
const DOCUMENT = 'data:text/html,' + encodeURIComponent(`<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-eval'; connect-src 'none'; worker-src blob:; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><title>Bandal Plugin Host</title>`)

export interface PluginHostProcess extends EventEmitter {
  postMessage(message: MainToHost): void
  kill(): boolean
}

export function createSandboxHost(preloadPath: string): PluginHostProcess {
  const host = new EventEmitter() as PluginHostProcess
  // A fresh nonpersistent session prevents access to app cookies, storage,
  // protocols and other plugins, and gives this host its own renderer process.
  const isolatedSession = session.fromPartition(`plugin-host:${randomUUID()}`, { cache: false })
  isolatedSession.setPermissionCheckHandler(() => false)
  isolatedSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false))
  isolatedSession.setDevicePermissionHandler(() => false)
  isolatedSession.webRequest.onBeforeRequest((details, callback) => callback({
    cancel: !(details.url === DOCUMENT || details.url.startsWith('blob:'))
  }))
  isolatedSession.on('will-download', event => event.preventDefault())
  let view: WebContentsView | null = new WebContentsView({ webPreferences: {
    session: isolatedSession,
    preload: preloadPath,
    sandbox: true,
    contextIsolation: true,
    nodeIntegration: false,
    nodeIntegrationInSubFrames: false,
    nodeIntegrationInWorker: false,
    webSecurity: true,
    allowRunningInsecureContent: false,
    webviewTag: false,
    plugins: false,
    backgroundThrottling: false,
    devTools: false,
    safeDialogs: true,
    disableDialogs: true
  } })
  const contents = view.webContents
  contents.setWebRTCIPHandlingPolicy('disable_non_proxied_udp')
  let stopped = false
  let heartbeat: ReturnType<typeof setInterval> | null = null
  let outstandingHeartbeat: { nonce: string; sentAt: number } | null = null
  let lastHeartbeatCheck = Date.now()
  const finish = (code: number): void => {
    if (stopped) return
    stopped = true
    if (heartbeat !== null) clearInterval(heartbeat)
    host.emit('exit', code)
    // Keep the unattached native view alive until explicit shutdown. Retaining
    // just its WebContents does not prevent the view wrapper's GC finalizer.
    const closingView = view
    view = null
    if (closingView !== null && !closingView.webContents.isDestroyed()) {
      closingView.webContents.close({ waitForBeforeUnload: false })
    }
  }
  contents.on('will-navigate', event => event.preventDefault())
  contents.on('will-redirect', event => event.preventDefault())
  contents.on('will-frame-navigate', event => event.preventDefault())
  contents.on('will-attach-webview', event => event.preventDefault())
  contents.setWindowOpenHandler(() => ({ action: 'deny' }))
  contents.on('render-process-gone', (_event, details) => finish(details.exitCode || 1))
  contents.on('destroyed', () => finish(0))
  contents.on('ipc-message', (event, channel, json: unknown) => {
    if (stopped || channel !== CHANNEL || event.senderFrame !== contents.mainFrame || typeof json !== 'string' || Buffer.byteLength(json, 'utf8') > PLUGIN_RPC_LIMITS.messageBytes) return
    try {
      const message: unknown = JSON.parse(json)
      if (typeof message === 'object' && message !== null && 't' in message && message.t === 'sandboxPong') {
        if ('nonce' in message && message.nonce === outstandingHeartbeat?.nonce) outstandingHeartbeat = null
        return
      }
      if (typeof message === 'object' && message !== null && 't' in message && message.t === 'sandboxError') {
        host.emit('error', 'sandbox-worker', 'Plugin execution sandbox stopped unexpectedly')
        finish(1)
        return
      }
      host.emit('message', message)
    } catch { /* Invalid messages have no authority. */ }
  })
  host.postMessage = (message) => {
    if (stopped) throw new Error('Plugin sandbox is closed')
    const payload = message.t === 'load'
      ? { ...message, source: readFileSync(join(message.dir, message.manifest.main), 'utf8') }
      : message
    contents.send(CHANNEL, JSON.stringify(payload))
  }
  host.kill = () => {
    if (stopped) return false
    // A command may have blocked the renderer event loop. Terminate it before
    // closing the unattached view; never wait for plugin beforeunload handlers.
    if (!contents.isDestroyed()) contents.forcefullyCrashRenderer()
    finish(0)
    return true
  }
  void contents.loadURL(DOCUMENT).then(async () => {
    if (stopped) return
    // A dedicated worker has no DOM, frame creation or WebRTC. The enclosing
    // renderer is trusted and exposes only fixed-channel primitive JSON IPC.
    // Blob workers inherit this document's CSP, including connect-src 'none'.
    const workerSource = `(() => {
      const parse = JSON.parse, stringify = JSON.stringify;
      const send = self.postMessage.bind(self);
      self.addEventListener('message', event => {
        const message = parse(event.data);
        if (message.t === 'sandboxHeartbeat') send(stringify({ t: 'sandboxPong', nonce: message.nonce }));
      });
      const transport = {
        post: message => send(stringify(message)),
        onMessage: callback => self.addEventListener('message', event => callback(parse(event.data)))
      };
      (${createHostRuntime.toString()})(transport, {}, ${JSON.stringify(PLUGIN_RPC_LIMITS)}, ${PLUGIN_RPC_PROTOCOL_VERSION});
    })()`
    await contents.executeJavaScript(`(() => {
      const bridge = globalThis.__bandalHost;
      const url = URL.createObjectURL(new Blob([${JSON.stringify(workerSource)}], { type: 'text/javascript' }));
      const worker = new Worker(url);
      URL.revokeObjectURL(url);
      worker.addEventListener('message', event => { if (typeof event.data === 'string') bridge.post(event.data) });
      worker.addEventListener('error', () => bridge.post(JSON.stringify({ t: 'sandboxError', error: 'Plugin worker failed to start or stopped unexpectedly' })));
      bridge.subscribe(json => worker.postMessage(json));
    })()`)
    if (stopped) return
    heartbeat = setInterval(() => {
      if (stopped || contents.isDestroyed()) return
      const now = Date.now()
      // Main and renderer both pause during OS sleep. Give a resumed worker a
      // fresh challenge instead of treating the old deadline as a plugin hang.
      if (now - lastHeartbeatCheck > 4_000) outstandingHeartbeat = null
      lastHeartbeatCheck = now
      if (outstandingHeartbeat !== null) {
        if (now - outstandingHeartbeat.sentAt < 6_000) return
        host.emit('error', 'sandbox-timeout', 'Plugin stopped responding; disable or reload it to recover')
        contents.forcefullyCrashRenderer()
        finish(1)
        return
      }
      outstandingHeartbeat = { nonce: randomUUID(), sentAt: now }
      contents.send(CHANNEL, JSON.stringify({ t: 'sandboxHeartbeat', nonce: outstandingHeartbeat.nonce }))
    }, 2_000)
  }).catch(error => {
    if (stopped) return
    host.emit('error', 'sandbox-start', error instanceof Error ? error.message : String(error))
    finish(1)
  })
  return host
}
