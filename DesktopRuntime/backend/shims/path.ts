export const sep = '/'
export function isAbsolute(value: string): boolean { return value.startsWith('/') }
export function normalize(value: string): string {
  const absolute = isAbsolute(value), parts: string[] = []
  for (const item of value.split('/')) {
    if (!item || item === '.') continue
    if (item === '..') { if (parts.length && parts[parts.length - 1] !== '..') parts.pop(); else if (!absolute) parts.push('..') }
    else parts.push(item)
  }
  const result = (absolute ? '/' : '') + parts.join('/')
  return (result || '.') + (value.endsWith('/') && result && result !== '/' ? '/' : '')
}
export function join(...values: string[]): string { return normalize(values.filter(Boolean).join('/')) }
export function resolve(...values: string[]): string {
  let result = ''
  for (let i = values.length - 1; i >= 0; i--) { const value = values[i]!; if (!value) continue; result = value + '/' + result; if (isAbsolute(value)) break }
  if (!isAbsolute(result)) result = '/' + result
  return normalize(result).replace(/\/$/, '') || '/'
}
export function dirname(value: string): string { const without = value.replace(/\/+$/, ''); const index = without.lastIndexOf('/'); return index < 0 ? '.' : index === 0 ? '/' : without.slice(0, index) }
export function basename(value: string, suffix = ''): string { const name = value.replace(/\/+$/, '').split('/').pop() ?? ''; return suffix && name.endsWith(suffix) ? name.slice(0, -suffix.length) : name }
export function extname(value: string): string { const name = basename(value), index = name.lastIndexOf('.'); return index <= 0 || name === '..' ? '' : name.slice(index) }
export function relative(from: string, to: string): string { const a = resolve(from).split('/').filter(Boolean), b = resolve(to).split('/').filter(Boolean); let i = 0; while (i < a.length && a[i] === b[i]) i++; return [...a.slice(i).map(() => '..'), ...b.slice(i)].join('/') }
export const posix = { sep, isAbsolute, normalize, join, resolve, dirname, basename, extname, relative }
export default posix
