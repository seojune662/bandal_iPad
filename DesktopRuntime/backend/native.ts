export interface Environment {
  userDataPath: string
  dataRoot: string
  homePath: string
  tempPath: string
  legacyDataPath: string
  platform: string
  version?: string
  fsConstants?: { O_RDONLY:number; O_NOFOLLOW:number }
  pdfFontPath?: string
  resourcesPath?: string
}
export function native<T = any>(op: string, args: Record<string, unknown> = {}): T {
  const host = (globalThis as any).__bandalNative
  if (!host) throw new Error('Bandal native host is unavailable')
  const response = JSON.parse(host.perform(JSON.stringify({ op, args })))
  if (!response.ok) {
    const error = new Error(response.error?.message ?? `Native operation failed: ${op}`) as Error & { code?: string }
    error.code = response.error?.code
    throw error
  }
  return response.value as T
}
export function emit(channel: string, payload: unknown): void {
  ;(globalThis as any).__bandalNative.emit(channel, JSON.stringify(payload))
}
let environment: Environment | undefined
export function env(): Environment { return environment ??= native<Environment>('environment') }

/** Contract used by the Swift host. Paths must be sandbox-validated there too.
 * sqlite.exec {sql}; sqlite.query/run {sql,params:Array|Object}
 * fs.exists/realpath/readdir {path}; readdir -> typed entry objects.
 * fs.stat {path,followSymlinks} -> {size,mtimeMs,mtimeNs:string,mode,isFile,isDirectory,isSymbolicLink}
 * fs.readFile {path,encoding:'utf8'|'base64'} -> string
 * fs.writeFile {path,data,encoding,flag,mode}; fs.mkdir {path,recursive}
 * fs.rename {from,to}; fs.remove {path,recursive,force}
 * fs.copy {from,to,recursive,overwrite}; fs.access {path,mode}
 * fs.open {path,flags,mode}->fd; fs.close/fs.fsync {fd}; fs.ftruncate {fd,length}
 * fs.fstat {fd}->same stat fields; numeric fs.open flags preserve O_NOFOLLOW.
 * fs.read {fd,length,position}->base64; fs.write {fd,data:base64,position:null|number}->count
 * crypto.randomUUID {}; crypto.randomBytes {length}->base64
 * crypto.sha256 {data,encoding:'base64'}->hex
 * crypto.hashCreate {algorithm:'sha256'}->id; crypto.hashUpdate {id,data:base64}; crypto.hashDigest {id}->hex (releases)
 * timer.schedule {id,delay}; timer.cancel {id}; callback __bandalTimerFired(id).
 */
