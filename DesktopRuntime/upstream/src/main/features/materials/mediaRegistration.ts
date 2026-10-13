import { protocol } from 'electron'
import { MEDIA_SCHEME } from './mediaProtocol'

type Handler = (request: Request) => Promise<Response>
let registered = false
let resolveHandler: (handler: Handler) => void
const handlerReady = new Promise<Handler>(resolve => { resolveHandler = resolve })

/** Chromium captures custom protocol availability when a renderer is created.
 * Register before the early shell; only actual reads wait for DB readiness. */
export function registerEarlyMediaProtocol(): void {
  if (registered) return
  registered = true
  protocol.handle(MEDIA_SCHEME, async request => (await handlerReady)(request))
}
export function setMaterialMediaHandler(handler: Handler): void {
  registerEarlyMediaProtocol()
  resolveHandler(handler)
}
