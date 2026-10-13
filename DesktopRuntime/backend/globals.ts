import { env } from './native'
import { Buffer } from './shims/buffer'
import { URL, URLSearchParams } from './shims/url'
import { TextDecoder } from './shims/text-decoder'
const runtime = globalThis as any
const hostTimeout=runtime.setTimeout,hostClearTimeout=runtime.clearTimeout
runtime.setTimeout=(callback:any,delay?:number,...args:any[])=>{const timer=hostTimeout(()=>callback(...args),delay);return typeof timer==='object'?timer:{__bandalTimer:timer,unref(){return this}}}
runtime.clearTimeout=(timer:any)=>hostClearTimeout(timer?.__bandalTimer??timer)
runtime.setImmediate??=((callback:any,...args:any[])=>runtime.setTimeout(callback,0,...args))
runtime.clearImmediate??=runtime.clearTimeout
runtime.Buffer = Buffer
runtime.URL = URL
runtime.URLSearchParams = URLSearchParams
runtime.TextEncoder = class { encode(value = '') { return Buffer.from(value) } }
runtime.TextDecoder = TextDecoder
runtime.structuredClone ??= (value: any) => {
  const seen = new Map<any, any>()
  function clone(input: any): any {
    if (typeof input === 'function' || typeof input === 'symbol') throw new Error('Value cannot be cloned')
    if (!input || typeof input !== 'object') return input
    if (seen.has(input)) return seen.get(input)
    if (input instanceof Date) return new Date(input.getTime())
    if (input instanceof ArrayBuffer) return input.slice(0)
    if (ArrayBuffer.isView(input)) return new (input.constructor as any)(input)
    const output: any = Array.isArray(input) ? [] : input instanceof Map ? new Map() : input instanceof Set ? new Set() : {}
    seen.set(input, output)
    if (input instanceof Map) for (const [key, value] of input) output.set(clone(key), clone(value))
    else if (input instanceof Set) for (const value of input) output.add(clone(value))
    else for (const [key, value] of Object.entries(input)) output[key] = clone(value)
    return output
  }
  return clone(value)
}
runtime.process = { platform: env().platform, pid: 1, env: { BANDAL_DATA_ROOT: env().dataRoot } }
runtime.performance ??= { now: () => Date.now() }
runtime.console ??= Object.fromEntries(['debug', 'log', 'info', 'warn', 'error'].map(level => [level, (...values: any[]) => runtime.__bandalNative.log(level, values.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join(' '))]))
