import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {createRequire} from 'node:module'
import vm from 'node:vm'
import {dependencies} from '../scripts/dependencies.mjs'
const {require}=dependencies(),{transform}=createRequire(require.resolve('vite'))('esbuild')
const source=await transform(await readFile(new URL('./shims/text-decoder.ts',import.meta.url),'utf8'),{loader:'ts',format:'cjs'})
const module={exports:{}}
vm.runInNewContext(source.code,{module,exports:module.exports,Uint8Array,ArrayBuffer,Array,String,RangeError,TypeError})
const Decoder=module.exports.TextDecoder
const cases=[[0xef,0xbb,0xbf,65],[0xe1,0x80],[0xe1,0x80,0x20],[0xf4,0x90,0x80,0x80],[0xed,0xa0,0x80],[0xc0,0xaf],[0xf0,0x90,0x80,0x80],[0,65,0xe2,0x82,0xac,0xf0,0x9f,0x98,0x80]]
for(const bytes of cases)for(let split=0;split<=bytes.length;split++){
  const a=new Decoder(),b=new TextDecoder(),first=Uint8Array.from(bytes.slice(0,split)),last=Uint8Array.from(bytes.slice(split))
  assert.equal(a.decode(first,{stream:true})+a.decode(last),b.decode(first,{stream:true})+b.decode(last))
}
assert.throws(()=>new Decoder('shift-jis'),RangeError)
assert.throws(()=>new Decoder('utf-8',{fatal:true}).decode(Uint8Array.of(255)),TypeError)
for(const encoding of ['utf-16le','utf-16be','latin1'])for(const bytes of [[0xff,0xfe,65,0],[0,0xd8],[0,0xd8,65],[0,0xd8,0,0xdc],[0,0xdc,65,0],[0xef,0xbb,0xbf,0x80]])for(let split=0;split<=bytes.length;split++){
  const a=new Decoder(encoding),b=new TextDecoder(encoding),first=Uint8Array.from(bytes.slice(0,split)),last=Uint8Array.from(bytes.slice(split))
  assert.equal(a.decode(first,{stream:true})+a.decode(last),b.decode(first,{stream:true})+b.decode(last),encoding+' '+bytes+' '+split)
}
console.log('PASS: UTF8/UTF16/Latin1 decoder streaming valid/invalid splits, BOM/EOF, fatal and unsupported encoding')
