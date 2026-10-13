const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function encodeUTF8(text: string): number[] {
  const bytes: number[] = []
  for (const symbol of text) {
    let c = symbol.codePointAt(0)!
    if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd
    if (c < 128) bytes.push(c)
    else if (c < 2048) bytes.push(192 | c >> 6, 128 | c & 63)
    else if (c < 65536) bytes.push(224 | c >> 12, 128 | c >> 6 & 63, 128 | c & 63)
    else bytes.push(240 | c >> 18, 128 | c >> 12 & 63, 128 | c >> 6 & 63, 128 | c & 63)
  }
  return bytes
}
export class Buffer extends Uint8Array {
  static from(value: string | ArrayBuffer | ArrayLike<number>, encodingOrOffset: any = 'utf8', length?: number): Buffer {
    if (typeof value !== 'string') {
      if (value instanceof ArrayBuffer) return new Buffer(value.slice(typeof encodingOrOffset === 'number' ? encodingOrOffset : 0,
        length === undefined ? undefined : encodingOrOffset + length))
      return new Buffer(Array.from(value))
    }
    if (encodingOrOffset === 'base64') {
      const clean = value.replace(/\s/g, '').replace(/-/g, '+').replace(/_/g, '/')
      const bytes: number[] = []; let bits = 0, count = 0
      for (const c of clean) { if (c === '=') break; const n = alphabet.indexOf(c); if (n < 0) throw new Error('Invalid base64'); bits = bits << 6 | n; count += 6; if (count >= 8) { count -= 8; bytes.push(bits >> count & 255) } }
      return new Buffer(bytes)
    }
    if (encodingOrOffset === 'hex') return new Buffer((value.match(/../g) ?? []).map(x => parseInt(x, 16)))
    if (encodingOrOffset !== 'utf8' && encodingOrOffset !== 'utf-8') throw new Error(`Unsupported encoding: ${encodingOrOffset}`)
    return new Buffer(encodeUTF8(value))
  }
  static alloc(size: number): Buffer { return new Buffer(size) }
  static byteLength(value: string | Uint8Array, encoding = 'utf8'): number { return typeof value === 'string' ? Buffer.from(value, encoding).length : value.byteLength }
  static isBuffer(value: unknown): value is Buffer { return value instanceof Buffer }
  equals(other: Uint8Array): boolean { return this.length === other.length && this.every((value, index) => value === other[index]) }
  static concat(values: Uint8Array[]): Buffer { const output = new Buffer(values.reduce((n, v) => n + v.length, 0)); let at = 0; for (const value of values) { output.set(value, at); at += value.length } return output }
  toString(encoding = 'utf8', start = 0, end = this.length): string {
    const bytes = this.subarray(start, end)
    if (encoding === 'base64') {
      let result = ''
      for (let i = 0; i < bytes.length; i += 3) { const a = bytes[i]!, b = bytes[i + 1] ?? 0, c = bytes[i + 2] ?? 0; result += alphabet[a >> 2]! + alphabet[(a & 3) << 4 | b >> 4]! + (i + 1 < bytes.length ? alphabet[(b & 15) << 2 | c >> 6] : '=') + (i + 2 < bytes.length ? alphabet[c & 63] : '=') }
      return result
    }
    if (encoding === 'hex') return Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('')
    let result = ''
    for (let i = 0; i < bytes.length;) {
      const first = bytes[i++]!; if (first < 128) { result += String.fromCharCode(first); continue }
      const n = first >= 0xf0 ? 3 : first >= 0xe0 ? 2 : first >= 0xc2 ? 1 : 0
      if (!n || i + n > bytes.length) { result += '\uFFFD'; continue }
      let value = first & (n === 3 ? 7 : n === 2 ? 15 : 31), valid = true
      for (let j = 0; j < n; j++) { const byte = bytes[i + j]!; if ((byte & 192) !== 128) { valid = false; break } value = value << 6 | byte & 63 }
      if (!valid || value > 0x10ffff || value >= 0xd800 && value <= 0xdfff || value < (n === 1 ? 128 : n === 2 ? 2048 : 65536)) { result += '\uFFFD'; continue }
      i += n; result += String.fromCodePoint(value)
    }
    return result
  }
  write(value: string, offset = 0, encoding = 'utf8'): number { const bytes = Buffer.from(value, encoding).subarray(0, this.length - offset); this.set(bytes, offset); return bytes.length }
  writeUInt16LE(value: number, offset: number): number { new DataView(this.buffer, this.byteOffset, this.byteLength).setUint16(offset, value, true); return offset + 2 }
  writeUInt32LE(value: number, offset: number): number { new DataView(this.buffer, this.byteOffset, this.byteLength).setUint32(offset, value, true); return offset + 4 }
  readUInt16LE(offset: number): number { return new DataView(this.buffer, this.byteOffset, this.byteLength).getUint16(offset, true) }
  readInt16LE(offset: number): number { return new DataView(this.buffer, this.byteOffset, this.byteLength).getInt16(offset, true) }
  readUInt32LE(offset: number): number { return new DataView(this.buffer, this.byteOffset, this.byteLength).getUint32(offset, true) }
  readUInt32BE(offset: number): number { return new DataView(this.buffer, this.byteOffset, this.byteLength).getUint32(offset, false) }
}
