#!/usr/bin/env node
// Run with the application's own Electron binary and ELECTRON_RUN_AS_NODE=1.
// The SQLite module must use that Electron ABI, never a system Node binding.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),vm=require('node:vm'),os=require('node:os'),{createRequire}=require('node:module')
const canonical=value=>JSON.stringify(value,(_k,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v)
const hash=file=>{const h=crypto.createHash('sha256'),fd=fs.openSync(file,'r'),b=Buffer.alloc(1024*1024);try{for(;;){const n=fs.readSync(fd,b,0,b.length,null);if(!n)break;h.update(b.subarray(0,n))}}finally{fs.closeSync(fd)}return h.digest('hex')}
function nearest(file){let cursor=path.resolve(file),suffix=[];while(!fs.existsSync(cursor)){suffix.unshift(path.basename(cursor));const next=path.dirname(cursor);if(next===cursor)throw new Error('No existing path ancestor');cursor=next}return path.join(fs.realpathSync(cursor),...suffix)}
async function run(input){
  if(!input||!['export','import','conflicts','restoreConflict'].includes(input.action))throw new Error('Unknown projector action')
  const moduleRequire=createRequire(path.join(input.moduleRoot,'package.json'))
  const appVersion=moduleRequire('./package.json').version
  if(typeof appVersion!=='string'||!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(appVersion))throw new Error('Desktop package version is unavailable')
  const SQLite=moduleRequire(input.sqliteModule||'better-sqlite3'),database=new SQLite(input.database)
  database.pragma('busy_timeout = 5000')
  const userData=path.dirname(path.resolve(input.database)),exchange=path.resolve(input.exchange),temp=path.join(exchange,'projector-temp')
  fs.mkdirSync(temp,{recursive:true});fs.mkdirSync(input.courseRoot,{recursive:true})
  const roots=[userData,exchange,input.courseRoot,...database.prepare('SELECT folder_path FROM courses').all().map(r=>r.folder_path)].map(nearest)
  const safe=p=>{const actual=nearest(p);if(!roots.some(root=>actual===root||actual.startsWith(root+path.sep)))throw new Error('Projector file path is outside approved course storage');return p}
  const geometry=new Map(),{PDFDocument}=moduleRequire('pdf-lib')
  const prepare=async file=>{
    if(!fs.existsSync(file)||!fs.statSync(file).isFile())return
    const fd=fs.openSync(file,'r'),head=Buffer.alloc(5);try{fs.readSync(fd,head,0,5,0)}finally{fs.closeSync(fd)}
    if(head.toString()!=='%PDF-')return
    const sha=hash(file),cache=path.join(exchange,`geometry-${sha}.json`)
    let pages
    if(fs.existsSync(cache))pages=JSON.parse(fs.readFileSync(cache,'utf8'))
    else{const pdf=await PDFDocument.load(fs.readFileSync(file));pages=pdf.getPages().map(p=>{const b=p.getCropBox();return{cropX:b.x,cropY:b.y,width:b.width,height:b.height,rotation:((p.getRotation().angle%360)+360)%360}});fs.writeFileSync(cache,JSON.stringify(pages))}
    geometry.set(sha,pages.map((p,i)=>({page:i+1,cropBox:{x:p.cropX,y:p.cropY,width:p.width,height:p.height},rotation:p.rotation})))
  }
  try{
    for(const c of database.prepare('SELECT folder_path FROM courses WHERE deleted_at IS NULL').all()){
      const walk=async directory=>{if(!fs.existsSync(directory))return;for(const e of fs.readdirSync(directory,{withFileTypes:true})){if(e.name.startsWith('.')||e.isSymbolicLink())continue;const p=safe(path.join(directory,e.name));if(e.isDirectory())await walk(p);else if(e.isFile()&&e.name.toLowerCase().endsWith('.pdf'))await prepare(p)}}
      await walk(c.folder_path)
    }
    for(const asset of input.request?.assets??[])await prepare(safe(asset.path))
    const environment={userDataPath:userData,dataRoot:input.courseRoot,homePath:userData,tempPath:temp,legacyDataPath:path.join(userData,'unused-native-legacy'),platform:process.platform,version:appVersion,fsConstants:{O_RDONLY:fs.constants.O_RDONLY,O_NOFOLLOW:fs.constants.O_NOFOLLOW}}
    const encode=v=>Buffer.isBuffer(v)?{__buffer:v.toString('base64')}:Array.isArray(v)?v.map(encode):v&&typeof v==='object'?Object.fromEntries(Object.entries(v).map(([k,x])=>[k,encode(x)])):v
    const decode=v=>v?.__buffer?Buffer.from(v.__buffer,'base64'):v
    const fds=new Set(),timers=new Set(),hashes=new Map()
    const native=(op,a)=>{
      for(const key of ['path','from','to'])if(typeof a[key]==='string')safe(a[key])
      switch(op){
        case'environment':return environment
        case'legacy.snapshot':return{records:[],pending:[]}
        case'sqlite.exec':database.exec(a.sql);return null
        case'sqlite.query':{const s=database.prepare(a.sql),args=Array.isArray(a.params)?a.params.map(decode):[a.params];if(s.reader)return encode(s.all(...args));s.run(...args);return[]}
        case'sqlite.run':{const r=database.prepare(a.sql).run(...(Array.isArray(a.params)?a.params.map(decode):[a.params]));return{changes:r.changes,lastInsertRowid:Number(r.lastInsertRowid)}}
        case'fs.exists':return fs.existsSync(a.path)
        case'fs.sha256':return hash(a.path)
        case'fs.realpath':return fs.realpathSync(a.path)
        case'fs.readdir':return fs.readdirSync(a.path,{withFileTypes:true}).map(v=>({name:v.name,isFile:v.isFile(),isDirectory:v.isDirectory(),isSymbolicLink:v.isSymbolicLink()}))
        case'fs.stat':{const s=(a.followSymlinks?fs.statSync:fs.lstatSync)(a.path,{bigint:true});return{size:Number(s.size),mtimeMs:Number(s.mtimeNs)/1e6,mtimeNs:String(s.mtimeNs),ctimeMs:Number(s.ctimeNs)/1e6,birthtimeMs:Number(s.birthtimeNs)/1e6,mode:Number(s.mode),isFile:s.isFile(),isDirectory:s.isDirectory(),isSymbolicLink:s.isSymbolicLink()}}
        case'fs.fstat':{if(!fds.has(a.fd))throw new Error('Unknown file descriptor');const s=fs.fstatSync(a.fd,{bigint:true});return{size:Number(s.size),mtimeMs:Number(s.mtimeNs)/1e6,mtimeNs:String(s.mtimeNs),ctimeMs:Number(s.ctimeNs)/1e6,birthtimeMs:Number(s.birthtimeNs)/1e6,mode:Number(s.mode),isFile:s.isFile(),isDirectory:s.isDirectory(),isSymbolicLink:s.isSymbolicLink()}}
        case'fs.readFile':return fs.readFileSync(a.path).toString(a.encoding)
        case'fs.writeFile':fs.writeFileSync(a.path,Buffer.from(a.data,a.encoding),{flag:a.flag,mode:a.mode});return null
        case'fs.mkdir':fs.mkdirSync(a.path,{recursive:a.recursive,mode:a.mode});return null
        case'fs.rename':fs.renameSync(a.from,a.to);return null
        case'fs.remove':if(fs.existsSync(a.path)&&fs.lstatSync(a.path).isDirectory()&&!a.recursive)fs.rmdirSync(a.path);else fs.rmSync(a.path,{recursive:a.recursive,force:a.force});return null
        case'fs.copy':fs.cpSync(a.from,a.to,{recursive:a.recursive,force:a.overwrite,errorOnExist:!a.overwrite});return null
        case'fs.access':fs.accessSync(a.path,a.mode);return null
        case'fs.chmod':fs.chmodSync(a.path,a.mode);return null
        case'fs.open':{const fd=fs.openSync(a.path,a.flags,a.mode);fds.add(fd);return fd}
        case'fs.close':if(fds.delete(a.fd))fs.closeSync(a.fd);return null
        case'fs.fsync':if(!fds.has(a.fd))throw new Error('Unknown file descriptor');fs.fsyncSync(a.fd);return null
        case'fs.ftruncate':if(!fds.has(a.fd))throw new Error('Unknown file descriptor');fs.ftruncateSync(a.fd,a.length);return null
        case'fs.read':{if(!fds.has(a.fd))throw new Error('Unknown file descriptor');const b=Buffer.alloc(a.length);return b.subarray(0,fs.readSync(a.fd,b,0,b.length,a.position)).toString('base64')}
        case'fs.write':{if(!fds.has(a.fd))throw new Error('Unknown file descriptor');const b=Buffer.from(a.data,'base64');return fs.writeSync(a.fd,b,0,b.length,a.position)}
        case'crypto.randomUUID':return crypto.randomUUID()
        case'crypto.randomBytes':return crypto.randomBytes(a.length).toString('base64')
        case'crypto.sha256':return crypto.createHash('sha256').update(Buffer.from(a.data,a.encoding)).digest('hex')
        case'crypto.hashCreate':{if(a.algorithm!=='sha256'||hashes.size>=1024)throw new Error('Invalid hash context');const id=crypto.randomUUID();hashes.set(id,crypto.createHash('sha256'));return id}
        case'crypto.hashUpdate':{const hash=hashes.get(a.id);if(!hash)throw new Error('Unknown hash context');hash.update(Buffer.from(a.data,'base64'));return null}
        case'crypto.hashDigest':{const hash=hashes.get(a.id);if(!hash)throw new Error('Unknown hash context');hashes.delete(a.id);return hash.digest('hex')}
        case'url.parse':{const u=new URL(a.url,a.base);return Object.fromEntries(['href','protocol','hostname','host','port','pathname','search','hash','username','password','origin'].map(k=>[k,u[k]]))}
        case'pdf.geometry':{const g=geometry.get(hash(a.path));if(!g)throw new Error('PDF geometry was not verified before projection');return g}
        default:throw new Error(`Unsupported desktop projection primitive: ${op}`)
      }
    }
    const context=vm.createContext({console:{log:(...v)=>console.error(...v),warn:(...v)=>console.error(...v),error:(...v)=>console.error(...v)},setTimeout,clearTimeout,AbortController,
      setInterval:(fn,delay)=>{const t=setInterval(fn,delay);timers.add(t);return t},clearInterval:t=>{timers.delete(t);clearInterval(t)},
      __bandalNative:{perform:json=>{try{const{op,args}=JSON.parse(json);return JSON.stringify({ok:true,value:native(op,args)})}catch(e){return JSON.stringify({ok:false,error:{message:e.message,code:e.code}})}},emit:()=>{},log:()=>{}}})
    try{
      vm.runInContext(fs.readFileSync(input.bundle,'utf8'),context,{filename:'bandal-projection-backend.js'})
      context.BandalBackend.initialize()
      for(const entry of input.seed??[]){
        const r=entry.record,s=entry.source??{},source={...s,courseID:s.courseID??s.course_id,relPath:s.relPath??s.rel_path}
        if(source.courseID&&source.relPath){const c=database.prepare('SELECT folder_path FROM courses WHERE id=?').get(source.courseID);if(c)source.path=path.join(c.folder_path,source.relPath)}
        database.prepare('INSERT OR IGNORE INTO ipad_sync_projection(id,kind,payload_json,deleted,source_json,baseline_json) VALUES(?,?,?,?,?,?)').run(r.id,r.kind,canonical(r.payload),r.deleted?1:0,canonical(source),canonical({kind:r.kind,payload:r.payload,deleted:r.deleted}))
      }
      return await context.BandalBackend.invokePrivate(`nativeSync:${input.action}`,input.request??{})
    }finally{for(const timer of timers)clearInterval(timer);for(const fd of fds)try{fs.closeSync(fd)}catch{}}
  }finally{database.close()}
}
module.exports={run}
if(require.main===module){let input='';process.stdin.setEncoding('utf8');process.stdin.on('data',chunk=>{input+=chunk;if(input.length>256*1024*1024)throw new Error('Projection input exceeds limit')});process.stdin.on('end',()=>run(JSON.parse(input)).then(value=>process.stdout.write(JSON.stringify(value)+'\n')).catch(error=>{console.error(error.message);process.exitCode=1}))}
