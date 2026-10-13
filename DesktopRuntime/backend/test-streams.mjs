import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import * as os from 'node:os'
import crypto from 'node:crypto'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import { dependencies } from '../scripts/dependencies.mjs'
const {require}=dependencies(),esbuild=createRequire(require.resolve('vite'))('esbuild'),directory=fs.mkdtempSync(path.join(os.tmpdir(),'bandal-stream-'))
const fds=new Set(),hashes=new Map();let maxRead=0,maxHash=0
const stats=s=>({size:s.size,mtimeMs:s.mtimeMs,isFile:s.isFile(),isDirectory:s.isDirectory(),isSymbolicLink:s.isSymbolicLink()})
const native=(op,a)=>{switch(op){
  case'environment':return{fsConstants:{O_RDONLY:fs.constants.O_RDONLY,O_NOFOLLOW:fs.constants.O_NOFOLLOW}}
  case'fs.open':{const fd=fs.openSync(a.path,a.flags,a.mode);fds.add(fd);return fd}
  case'fs.close':assert.ok(fds.delete(a.fd));fs.closeSync(a.fd);return null
  case'fs.fstat':return stats(fs.fstatSync(a.fd))
  case'fs.stat':return stats((a.followSymlinks?fs.statSync:fs.lstatSync)(a.path))
  case'fs.read':{assert.ok(fds.has(a.fd));maxRead=Math.max(maxRead,a.length);const b=Buffer.alloc(a.length);return b.subarray(0,fs.readSync(a.fd,b,0,b.length,a.position)).toString('base64')}
  case'fs.write':{const b=Buffer.from(a.data,'base64');return fs.writeSync(a.fd,b,0,b.length,a.position)}
  case'fs.fsync':fs.fsyncSync(a.fd);return null
  case'crypto.hashCreate':{const id=crypto.randomUUID();hashes.set(id,crypto.createHash(a.algorithm));return id}
  case'crypto.hashUpdate':{const b=Buffer.from(a.data,'base64');maxHash=Math.max(maxHash,b.length);hashes.get(a.id).update(b);return null}
  case'crypto.hashDigest':{const h=hashes.get(a.id);hashes.delete(a.id);return h.digest('hex')}
  default:throw new Error('Unmocked stream primitive '+op)
}}
try {
  const built=await esbuild.build({stdin:{contents:"export * as fs from './shims/fs';export * as promises from './shims/fs-promises';export * as crypto from './shims/crypto';export {Buffer} from './shims/buffer'",resolveDir:fileURLToPath(new URL('.',import.meta.url)),loader:'ts'},bundle:true,format:'iife',globalName:'Shims',platform:'neutral',target:'es2020',write:false})
  const perform=json=>{
    try{const{op,args}=JSON.parse(json);return JSON.stringify({ok:true,value:native(op,args)})}
    catch(error){return JSON.stringify({ok:false,error:{message:error.message,code:error.code}})}
  }
  const context=vm.createContext({__bandalNative:{perform}})
  vm.runInContext(built.outputFiles[0].text,context)
  const {fs:s,promises:p,crypto:c,Buffer:B}=context.Shims,source=path.join(directory,'source'),destination=path.join(directory,'copy'),bytes=crypto.randomBytes(9*1024*1024+17)
  fs.writeFileSync(source,bytes)
  const input=await p.open(source,s.constants.O_RDONLY|s.constants.O_NOFOLLOW),output=await p.open(destination,'wx',0o600)
  const before=await input.stat();assert.equal(before.size,bytes.length);assert.equal(before.isFile(),true)
  for await(const chunk of input.createReadStream({autoClose:false}))await output.writeFile(chunk)
  assert.equal((await input.stat()).size,bytes.length);await input.close();await output.sync();await output.close()
  assert.deepEqual(fs.readFileSync(destination),bytes);assert.equal(fds.size,0);assert.ok(maxRead<=256*1024)
  const h=c.createHash('sha256');for await(const chunk of s.createReadStream(source))h.update(chunk)
  assert.equal(h.digest('hex'),crypto.createHash('sha256').update(bytes).digest('hex'));assert.equal(hashes.size,0)
  assert.throws(()=>h.update('late'),/finalized/)
  assert.equal(c.createHash('sha256').update(bytes).digest('hex'),crypto.createHash('sha256').update(bytes).digest('hex'));assert.ok(maxHash<=256*1024)
  for await(const chunk of s.createReadStream(source)){assert.equal(chunk.length,65536);break}assert.equal(fds.size,0)
  const ranged=[];for await(const chunk of s.createReadStream(source,{start:11,end:27}))ranged.push(Buffer.from(chunk));assert.deepEqual(Buffer.concat(ranged),bytes.subarray(11,28))
  const held=await p.open(source,'r'),replacement=path.join(directory,'original');fs.renameSync(source,replacement);fs.writeFileSync(source,'new')
  assert.equal((await held.stat()).size,bytes.length,'fstat must describe held inode rather than replacement path')
  const buffer=B.alloc(5),read=await held.read(buffer,0,5,3);assert.equal(read.bytesRead,5);assert.deepEqual(Buffer.from(buffer),bytes.subarray(3,8));await held.close()
  const symlink=path.join(directory,'link');fs.symlinkSync(source,symlink);assert.equal((await p.lstat(symlink)).isSymbolicLink(),true)
  await assert.rejects(p.open(symlink,s.constants.O_RDONLY|s.constants.O_NOFOLLOW),error=>['ELOOP','EMLINK'].includes(error.code))
  assert.equal(B.from([1,2,3,4]).readUInt32BE(0),0x01020304);assert.equal(fds.size,0)
  console.log('PASS: bounded file/hash streams, original descriptor stat, no-follow symlink rejection, positional reads, append writes, early-break closure')
}finally{for(const fd of fds)try{fs.closeSync(fd)}catch{}fs.rmSync(directory,{recursive:true,force:true})}
