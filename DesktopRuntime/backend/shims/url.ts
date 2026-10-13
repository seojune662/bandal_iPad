import { native } from '../native'
const decode = (value: string): string => { try { return decodeURIComponent(value.replace(/\+/g, ' ')) } catch { return value } }
const encode = (value: string): string => encodeURIComponent(value).replace(/%20/g, '+')
export class URLSearchParams {
  private values: [string, string][] = []
  constructor(value: string | Record<string, string> = '', private changed?: (value: string) => void) {
    this.values = typeof value === 'string' ? value.replace(/^\?/, '').split('&').filter(Boolean).map(piece => { const i = piece.indexOf('='); return [decode(i < 0 ? piece : piece.slice(0, i)), decode(i < 0 ? '' : piece.slice(i + 1))] }) : Object.entries(value)
  }
  get(key: string): string | null { return this.values.find(x => x[0] === key)?.[1] ?? null }
  getAll(key: string): string[] { return this.values.filter(x => x[0] === key).map(x => x[1]) }
  has(key: string): boolean { return this.values.some(x => x[0] === key) }
  set(key: string, value: string): void { this.values = this.values.filter(x => x[0] !== key); this.values.push([key, String(value)]); this.changed?.(this.toString()) }
  append(key: string, value: string): void { this.values.push([key, String(value)]); this.changed?.(this.toString()) }
  delete(key: string): void { this.values = this.values.filter(x => x[0] !== key); this.changed?.(this.toString()) }
  toString(): string { return this.values.map(([k, v]) => `${encode(k)}=${encode(v)}`).join('&') }
  entries(): IterableIterator<[string, string]> { return this.values[Symbol.iterator]() }
  keys(): IterableIterator<string> { return this.values.map(x => x[0])[Symbol.iterator]() }
  [Symbol.iterator](): IterableIterator<[string, string]> { return this.entries() }
  forEach(callback: (value: string, key: string) => void): void { for (const [key, value] of this.values) callback(value, key) }
}
export class URL {
  private value: any
  constructor(url: string | URL, base?: string | URL) { this.value = native('url.parse', { url: String(url), ...(base ? { base: String(base) } : {}) }) }
  get href(): string { return this.value.href }
  get protocol(): string { return this.value.protocol }
  get hostname(): string { return this.value.hostname }
  get host(): string { return this.value.host }
  get port(): string { return this.value.port }
  get pathname(): string { return this.value.pathname }
  get username(): string { return this.value.username }
  get password(): string { return this.value.password }
  get origin(): string { return this.value.origin }
  get search(): string { return this.value.search }
  set search(value: string) { this.replace(value ? '?' + value.replace(/^\?/, '') : '', this.hash) }
  get hash(): string { return this.value.hash }
  set hash(value: string) { this.replace(this.search, value ? '#' + value.replace(/^#/, '') : '') }
  get searchParams(): URLSearchParams { return new URLSearchParams(this.search, value => { this.search = value }) }
  private replace(search: string, hash: string): void { const base = this.href.split('#')[0]!.split('?')[0]!; this.value = native('url.parse', { url: base + search + hash }) }
  toString(): string { return this.href }
  toJSON(): string { return this.href }
}
