import { env, native } from '../native'
import { Buffer } from './buffer'
export * as promises from './fs-promises'

export const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, COPYFILE_EXCL: 1, O_RDONLY: 0, O_NOFOLLOW: (env() as any).fsConstants?.O_NOFOLLOW ?? 0x100 }
function entry(value: any): any { return { ...value, isFile: () => value.isFile === true, isDirectory: () => value.isDirectory === true, isSymbolicLink: () => value.isSymbolicLink === true } }
function statValue(value:any, options?: { bigint?: boolean }): any {
  return { ...entry(value), mtime: new Date(value.mtimeMs), ctime: new Date(value.ctimeMs ?? value.mtimeMs), birthtime: new Date(value.birthtimeMs ?? value.mtimeMs),
    ...(options?.bigint ? { size: BigInt(value.size), ...(value.dev !== undefined ? { dev: BigInt(value.dev) } : {}), ...(value.ino !== undefined ? { ino: BigInt(value.ino) } : {}), ...(value.ctimeNs !== undefined ? { ctimeNs: BigInt(value.ctimeNs) } : {}), mtimeNs: BigInt(value.mtimeNs ?? Math.round(value.mtimeMs * 1e6)), mtimeMs: BigInt(Math.floor(value.mtimeMs)) } : {}) }
}
export const statSync = (path: string, options?: any): any => statValue(native('fs.stat', {path, followSymlinks:true}), options)
export const lstatSync = (path: string, options?: any): any => statValue(native('fs.stat', {path, followSymlinks:false}), options)
export const fstatSync = (fd: number, options?: any): any => statValue(native('fs.fstat', {fd}), options)
export const existsSync = (path: string): boolean => native('fs.exists', { path })
export const realpathSync = Object.assign((path: string): string => native('fs.realpath', { path }), { native: (path: string): string => native('fs.realpath', { path }) })
export function readdirSync(path: string, options?: any): any[] { const values = native<any[]>('fs.readdir', { path }); return options?.withFileTypes ? values.map(entry) : values.map(value => value.name) }
export function readFileSync(path: string, encoding?: string | { encoding?: string }): string | Buffer {
  const name = typeof encoding === 'string' ? encoding : encoding?.encoding
  if (name === 'utf8' || name === 'utf-8') return native('fs.readFile', { path, encoding: 'utf8' })
  const bytes = Buffer.from(native<string>('fs.readFile', { path, encoding: 'base64' }), 'base64')
  return name ? bytes.toString(name) : bytes
}
export function writeFileSync(path: string | number, data: string | Uint8Array, options?: any): void {
  const bytes = typeof data === 'string' ? Buffer.from(data, typeof options === 'string' ? options : options?.encoding ?? 'utf8') : Buffer.from(data)
  if (typeof path === 'number') { let offset = 0; while (offset < bytes.length) { const count = writeSync(path, bytes, offset, bytes.length - offset); if (!count) throw new Error('Unable to complete file write'); offset += count } return }
  native('fs.writeFile', { path, data: bytes.toString('base64'), encoding: 'base64', flag: options?.flag ?? 'w', mode: options?.mode ?? 0o666 })
}
export const mkdirSync = (path: string, options?: any): void => { native('fs.mkdir', { path, recursive: options?.recursive === true, mode: options?.mode }) }
export const renameSync = (from: string, to: string): void => { native('fs.rename', { from, to }) }
export const rmSync = (path: string, options?: any): void => { native('fs.remove', { path, recursive: options?.recursive === true, force: options?.force === true }) }
export const rmdirSync = (path: string): void => { native('fs.remove', { path, recursive: false, force: false }) }
export const unlinkSync = (path: string): void => { native('fs.remove', { path, recursive: false, force: false }) }
export const copyFileSync = (from: string, to: string, mode = 0): void => { native('fs.copy', { from, to, recursive: false, overwrite: (mode & constants.COPYFILE_EXCL) === 0 }) }
export const cpSync = (from: string, to: string, options?: any): void => { native('fs.copy', { from, to, recursive: options?.recursive === true, overwrite: options?.force !== false }) }
export const accessSync = (path: string, mode = 0): void => { native('fs.access', { path, mode }) }
export const chmodSync = (path: string, mode: number): void => { native('fs.chmod', { path, mode }) }
export const openSync = (path: string, flags: string | number, mode = 0o666): number => native('fs.open', { path, flags, mode })
export const closeSync = (fd: number): void => { native('fs.close', { fd }) }
export const fsyncSync = (fd: number): void => { native('fs.fsync', { fd }) }
export const ftruncateSync = (fd: number, length = 0): void => { native('fs.ftruncate', { fd, length }) }
export function writeSync(fd: number, buffer: Uint8Array, offset = 0, length = buffer.length - offset, position: number | null = null): number {
  return native('fs.write', { fd, data: Buffer.from(buffer.subarray(offset, offset + length)).toString('base64'), position })
}
export function readSync(fd: number, buffer: Uint8Array, offset = 0, length = buffer.length - offset, position: number | null = null): number {
  if (!Number.isInteger(offset)||!Number.isInteger(length)||offset<0||length<0||offset+length>buffer.length||position!==null&&(!Number.isSafeInteger(position)||position<0)) throw new RangeError('Invalid file read range')
  const bytes = Buffer.from(native<string>('fs.read', { fd, length, position }), 'base64')
  buffer.set(bytes, offset); return bytes.length
}
/** The original bundle code consumes Readable only via async iteration. Each
 * read crosses the native boundary with at most 256 KiB and closes on break. */
export function createReadStream(path:string,options:any={}):any {
  let fd:number|undefined=options.fd,closed=false,started=false,destroyed=false
  const autoClose=options.autoClose!==false,highWaterMark=options.highWaterMark??64*1024
  if(!Number.isInteger(highWaterMark)||highWaterMark<1||highWaterMark>256*1024)throw new RangeError('Invalid stream chunk size')
  if(options.start!==undefined&&(!Number.isSafeInteger(options.start)||options.start<0))throw new RangeError('Invalid stream start')
  if(options.end!==undefined&&(!Number.isSafeInteger(options.end)||options.end<(options.start??0)))throw new RangeError('Invalid stream end')
  const close=()=>{if(!closed&&fd!==undefined&&autoClose){closed=true;closeSync(fd)}}
  return {destroy(){destroyed=true;close()},async *[Symbol.asyncIterator](){
    if(started)throw new Error('File stream has already been consumed');started=true
    if(destroyed)return
    fd??=openSync(path,options.flags??'r');let position=options.start??null,consumed=0
    try{while(!destroyed){
      const remaining=options.end===undefined?Infinity:options.end-(options.start??0)-consumed+1;if(remaining<=0)break
      const buffer=Buffer.alloc(Math.min(highWaterMark,remaining)),read=readSync(fd,buffer,0,buffer.length,position)
      if(!read)break;consumed+=read;if(position!==null)position+=read;yield buffer.subarray(0,read)
    }}finally{close()}
  }}
}
