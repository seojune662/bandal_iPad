import './ai/abort'
import { Buffer } from './shims/buffer'
import { randomUUID } from './shims/crypto'

const host = globalThis as any
host.AbortSignal ??= new host.AbortController().signal.constructor
host.AbortSignal.timeout ??= (milliseconds: number) => {
  const controller = new host.AbortController()
  const timer = setTimeout(() => controller.abort(Object.assign(new Error('Request timed out'), { name: 'TimeoutError' })), milliseconds)
  ;(timer as any).unref?.()
  return controller.signal
}
host.AbortSignal.any ??= (signals: AbortSignal[]) => {
  const controller = new host.AbortController()
  const registrations: Array<[AbortSignal, () => void]> = []
  for (const signal of signals) {
    const abort = () => {
      controller.abort(signal.reason)
      for (const [source, action] of registrations) source.removeEventListener('abort', action)
    }
    registrations.push([signal, abort])
    if (signal.aborted) { abort(); break }
    signal.addEventListener('abort', abort, { once: true })
  }
  return controller.signal
}

export const cloudInvoke = <T = any>(channel: string, request: any = {}): Promise<T> => host.__bandalPlatform.invoke(channel, request)
export type CloudState = { supabase: { url: string; publishableKey: string } | null; marketplaceURL: string | null; signedIn: boolean; accountID: string | null }
export type NativeFetchTransport = { request: (input:any)=>Promise<{status:number;headers:Record<string,string>;bodyID:string;byteCount:number}>;read:(bodyID:string)=>Promise<{data:string;done:boolean}>;cancel:(id:string)=>Promise<unknown> }
export const boundCloudFetch = (state: CloudState): typeof fetch => (input, options) => cloudFetch(input, options, state.accountID)

/** Only an opaque authorization marker enters the original clients. Native
 * substitutes its current Keychain token after checking the exact origin. */
export function cloudSession(state: CloudState) {
  return { auth: { getSession: async () => ({ error: null, data: { session: state.signedIn ? { access_token: 'native-keychain' } : null } }) } } as any
}

/** The desktop consumers need fetch's status/headers/json and stream reader
 * semantics. Large native responses are chunked without buffering whole files
 * in JavaScriptCore; unused small JSON responses are released immediately. */
export async function cloudFetch(input: RequestInfo | URL, options: RequestInit = {}, accountID: string | null = null, transport?: NativeFetchTransport): Promise<Response> {
  const id = randomUUID(), signal = options.signal
  signal?.throwIfAborted()
  if (options.redirect && options.redirect !== 'error') throw new Error('Cloud redirects are not allowed')
  const headers: Record<string, string> = {}
  if (Array.isArray(options.headers)) for (const [key, value] of options.headers) headers[key] = value
  else if (options.headers && typeof (options.headers as Headers).forEach === 'function') (options.headers as Headers).forEach((value, key) => { headers[key] = value })
  else Object.assign(headers, options.headers ?? {})
  let bodyBase64: string | undefined
  if (options.body != null) {
    if (typeof options.body === 'string') bodyBase64 = Buffer.from(options.body).toString('base64')
    else if (options.body instanceof Uint8Array || options.body instanceof ArrayBuffer) bodyBase64 = Buffer.from(options.body as Uint8Array).toString('base64')
    else throw new Error('Unsupported cloud request body')
  }
  let closed = false, cancelled = false
  const release = () => { signal?.removeEventListener('abort', abort) }
  const cancel = async () => { cancelled = true; if (!closed) { closed = true; release(); await (transport?transport.cancel(id):cloudInvoke('native:cloudCancel', { id })) } }
  const abort = () => { void cancel().catch(() => undefined) }
  signal?.addEventListener('abort', abort, { once: true })
  let response: { status: number; headers: Record<string, string>; bodyID: string; byteCount: number }
  try {
    const request={ id, url: String(input), method: options.method ?? 'GET', headers, accountID, ...(bodyBase64 === undefined ? {} : { bodyBase64 }) }
    response = await (transport?transport.request(request):cloudInvoke('native:cloudRequest',request))
    signal?.throwIfAborted()
  } catch (error) { await cancel().catch(() => undefined); throw error }
  const responseHeaders = new Map(Object.entries(response.headers).map(([name, value]) => [name.toLowerCase(), value]))
  let cached: Uint8Array | undefined, offset = 0, locked = false, bodyUsed = false, received = 0
  const readNative = async () => {
    signal?.throwIfAborted()
    if (closed) return { done: true as const, value: undefined }
    try {
      const part = await (transport?transport.read(response.bodyID):cloudInvoke<{ data: string; done: boolean }>('native:cloudRead', { bodyID: response.bodyID }))
      signal?.throwIfAborted()
      if (part.done) {
        closed = true; release()
        if (received !== response.byteCount) throw new Error('Cloud response was truncated')
        return { done: true as const, value: undefined }
      }
      const value = Buffer.from(part.data, 'base64'); received += value.length
      if (received > response.byteCount || value.length > 512 * 1024) throw new Error('Cloud response exceeds its declared size')
      return { done: false as const, value }
    } catch (error) { await cancel().catch(() => undefined); throw error }
  }
  const collect = async (read: typeof readNative) => {
    const chunks: Uint8Array[] = []; let total = 0
    for (;;) {
      const value = await read(); if (value.done) break
      total += value.value.byteLength
      if (total > response.byteCount || total > 50 * 1024 * 1024) { await cancel(); throw new Error('Cloud response exceeds its declared size') }
      chunks.push(value.value)
    }
    if (total !== response.byteCount) throw new Error('Cloud response was truncated')
    return Buffer.concat(chunks)
  }
  if (response.byteCount <= 1024 * 1024) {
    try { cached = await collect(readNative) } catch (error) { await cancel().catch(() => undefined); throw error }
  }
  const read = async () => {
    bodyUsed = true
    if (cancelled) return { done: true as const, value: undefined }
    if (!cached) return readNative()
    if (offset >= cached.length) return { done: true as const, value: undefined }
    const value = cached.subarray(offset, offset + 512 * 1024); offset += value.length
    return { done: false as const, value }
  }
  const consume = async () => {
    if (locked || bodyUsed) throw new TypeError('Body is already used')
    locked = true
    try { return await collect(read) } catch (error) { await cancel().catch(() => undefined); throw error }
  }
  return {
    status: response.status, ok: response.status >= 200 && response.status < 300,
    url: String(input), redirected: false,
    get bodyUsed() { return bodyUsed },
    headers: { get: (name: string) => responseHeaders.get(name.toLowerCase()) ?? null, has: (name: string) => responseHeaders.has(name.toLowerCase()), forEach: (action: (value: string, name: string) => void) => responseHeaders.forEach(action) },
    body: {
      getReader() {
        if (locked) throw new TypeError('Body stream is locked')
        locked = true
        let released = false, reading = false
        return { async read() {
          if (released || reading) throw new TypeError('Body reader is unavailable')
          reading = true
          try { return await read() } finally { reading = false }
        }, cancel, releaseLock() { if (reading) throw new TypeError('Read is pending'); released = true; locked = false } }
      }, cancel, get locked() { return locked }
    },
    async json() { return JSON.parse((await consume()).toString('utf8')) },
    async text() { return (await consume()).toString('utf8') },
    async arrayBuffer() { const value = await consume(); return value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength) }
  } as unknown as Response
}
