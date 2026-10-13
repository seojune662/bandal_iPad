import { native } from '../native'
import { Buffer } from './buffer'
export const randomUUID = (): string => native('crypto.randomUUID')
export const randomBytes = (length: number): Buffer => Buffer.from(native('crypto.randomBytes', { length }), 'base64')
export function randomInt(max: number): number {
  if (!Number.isSafeInteger(max) || max <= 0 || max > 0x100000000) throw new RangeError('Invalid randomInt bound')
  const limit = Math.floor(0x100000000 / max) * max
  let value: number
  do { value = randomBytes(4).readUInt32LE(0) } while (value >= limit)
  return value % max
}
export function createHash(algorithm: string): any {
  if (algorithm !== 'sha256') throw new Error(`Unsupported hash algorithm: ${algorithm}`)
  const id=native<string>('crypto.hashCreate',{algorithm});let finalized=false
  const hash = {
    update(value: string | Uint8Array, encoding = 'utf8') {
      if(finalized)throw new Error('Hash has already been finalized')
      const bytes=typeof value==='string'?Buffer.from(value,encoding):value
      for(let offset=0;offset<bytes.length;offset+=256*1024)native('crypto.hashUpdate',{id,data:Buffer.from(bytes.subarray(offset,offset+256*1024)).toString('base64')})
      return hash
    },
    digest(encoding?: string) { if(finalized)throw new Error('Hash has already been finalized');const hex=native<string>('crypto.hashDigest',{id});finalized=true; const bytes = Buffer.from(hex, 'hex'); return encoding ? bytes.toString(encoding) : bytes }
  }; return hash
}
