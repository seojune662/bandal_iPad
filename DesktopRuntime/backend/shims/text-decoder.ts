/** Text encodings used by the reused document parsers, with streaming IO. */
export class TextDecoder {
  readonly encoding: string
  readonly fatal: boolean
  readonly ignoreBOM: boolean
  private pending: number[] = []
  private sawCodePoint = false
  constructor(label = 'utf-8', options: { fatal?: boolean; ignoreBOM?: boolean } = {}) {
    const name=label.trim().toLowerCase()
    this.encoding=['utf-8','utf8','unicode-1-1-utf-8'].includes(name)?'utf-8':['utf-16','utf-16le','utf16le'].includes(name)?'utf-16le':['utf-16be','utf16be'].includes(name)?'utf-16be':['latin1','iso-8859-1','windows-1252','ascii'].includes(name)?'windows-1252':''
    if (!this.encoding) throw new RangeError('Unsupported encoding')
    this.fatal = options.fatal ?? false; this.ignoreBOM = options.ignoreBOM ?? false
  }
  decode(input?: ArrayBuffer | ArrayBufferView, options: { stream?: boolean } = {}): string {
    const incoming = input === undefined ? [] : Array.from(input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength))
    const bytes = this.pending.concat(incoming); this.pending = []
    let result = '', offset = 0
    const emit = (point: number) => { if (this.sawCodePoint || this.ignoreBOM || point !== 0xfeff) result += String.fromCodePoint(point); this.sawCodePoint = true }
    const invalid = () => { if (this.fatal) throw new TypeError('Invalid encoded text'); emit(0xfffd) }
    if(this.encoding==='windows-1252'){
      const special=[0x20ac,0x81,0x201a,0x192,0x201e,0x2026,0x2020,0x2021,0x2c6,0x2030,0x160,0x2039,0x152,0x8d,0x17d,0x8f,0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x2dc,0x2122,0x161,0x203a,0x153,0x9d,0x17e,0x178]
      for(const byte of bytes)emit(byte>=0x80&&byte<=0x9f?special[byte-0x80]!:byte)
    }else if(this.encoding==='utf-16le'||this.encoding==='utf-16be'){
      const unit=(at:number)=>this.encoding==='utf-16le'?bytes[at]!|bytes[at+1]!<<8:bytes[at]!<<8|bytes[at+1]!
      while(offset<bytes.length){
        const start=offset
        if(offset+1===bytes.length){if(options.stream)this.pending=bytes.slice(start);else invalid();break}
        const point=unit(offset);offset+=2
        if(point>=0xd800&&point<=0xdbff){
          if(offset+1>=bytes.length){if(options.stream)this.pending=bytes.slice(start);else invalid();break}
          const low=unit(offset)
          if(low<0xdc00||low>0xdfff){invalid();continue}
          emit(0x10000+((point-0xd800)<<10)+low-0xdc00);offset+=2
        }else if(point>=0xdc00&&point<=0xdfff)invalid()
        else emit(point)
      }
    }else{
    while (offset < bytes.length) {
      const start = offset, first = bytes[offset++]!
      if (first < 0x80) { emit(first); continue }
      const length = first >= 0xc2 && first <= 0xdf ? 2 : first >= 0xe0 && first <= 0xef ? 3 : first >= 0xf0 && first <= 0xf4 ? 4 : 0
      if (!length) { invalid(); continue }
      let point = first & (length === 2 ? 31 : length === 3 ? 15 : 7), complete = true
      for (let index = 1; index < length; index++) {
        if (offset === bytes.length) {
          if (options.stream) this.pending = bytes.slice(start)
          else invalid()
          complete = false; break
        }
        const byte = bytes[offset]!, minimum = index === 1 && first === 0xe0 ? 0xa0 : index === 1 && first === 0xf0 ? 0x90 : 0x80
        const maximum = index === 1 && first === 0xed ? 0x9f : index === 1 && first === 0xf4 ? 0x8f : 0xbf
        if (byte < minimum || byte > maximum) { invalid(); complete = false; break }
        point = point << 6 | byte & 63; offset++
      }
      if (complete) emit(point)
    }
    }
    if (!options.stream) this.sawCodePoint = false
    return result
  }
}
