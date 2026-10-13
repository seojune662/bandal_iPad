import { native } from './native'
import { Buffer } from './shims/buffer'

function encode(value: any): any {
  if (value instanceof Uint8Array) return { __buffer: Buffer.from(value).toString('base64') }
  if (Array.isArray(value)) return value.map(encode)
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, value]) => [key, encode(value)]))
  return value === undefined ? null : value
}
function decode(value: any): any {
  if (value?.__buffer) return Buffer.from(value.__buffer, 'base64')
  if (Array.isArray(value)) return value.map(decode)
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, value]) => [key, decode(value)]))
  return value
}
function parameters(args: any[]): any { return encode(args.length === 1 && (Array.isArray(args[0]) || args[0] && typeof args[0] === 'object' && !(args[0] instanceof Uint8Array)) ? args[0] : args) }
export function createDatabase(): any {
  let sequence = 0
  let transactionDepth = 0
  return {
    get inTransaction() { return transactionDepth > 0 },
    exec(sql: string) { native('sqlite.exec', { sql }); return this },
    pragma(sql: string, options?: { simple?: boolean }) { const rows = native<any[]>('sqlite.query', { sql: `PRAGMA ${sql}`, params: [] }); return options?.simple ? Object.values(rows[0] ?? {})[0] : rows },
    prepare(sql: string) { return {
      all(...args: any[]) { return decode(native('sqlite.query', { sql, params: parameters(args) })) },
      get(...args: any[]) { return decode(native<any[]>('sqlite.query', { sql, params: parameters(args) })[0]) },
      run(...args: any[]) { return native('sqlite.run', { sql, params: parameters(args) }) }
    } },
    transaction<T extends (...args: any[]) => any>(callback: T): T {
      return ((...args: any[]) => {
        const name = `bandal_tx_${++sequence}`
        native('sqlite.exec', { sql: `SAVEPOINT ${name}` })
        transactionDepth += 1
        try {
          const result = callback(...args)
          if (result && typeof result.then === 'function') throw new Error('SQLite transaction callback must be synchronous')
          native('sqlite.exec', { sql: `RELEASE SAVEPOINT ${name}` }); return result
        } catch (error) {
          try { native('sqlite.exec', { sql: `ROLLBACK TO SAVEPOINT ${name}; RELEASE SAVEPOINT ${name}` }) } catch { /* Preserve original error. */ }
          throw error
        } finally { transactionDepth -= 1 }
      }) as T
    }
  }
}
