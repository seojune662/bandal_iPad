import { native } from '../native'
import { existsSync, readFileSync, readdirSync, statSync } from '../shims/fs'
import { basename, join } from '../shims/path'
import { resolveInsideReal, resolveInside, assertRealInside } from '../../upstream/src/main/db/validate'
import { validateLearningState } from '../../upstream/src/main/features/learning/validation'
import { canonical, digest, type SharedAsset, type SharedRecord } from './format'
import type { FileChange } from './journal'

const directory='.bandal/learning'
function allowed(path:string) { return /^(?:manifest|state)\.json$/.test(path)||/^(?:articles|artifacts|results)\/[a-zA-Z0-9_-]+\.json$/.test(path) }
export function createLearningProjection(deps:any) {
  const snapshot=async()=>{
    const records:SharedRecord[]=[],assets:SharedAsset[]=[],sources=new Map<string,any>()
    if (!deps.learning) return {records,assets,sources}
    for (const course of deps.db.prepare('SELECT id FROM courses WHERE deleted_at IS NULL').all()) {
      const projects=await deps.learning.repo.discover(course.id,{includeDeleted:true})
      for (const summary of projects) {
        const project=await deps.learning.repo.readDeleted(summary.binding), binding=project.binding, courseFolder=deps.courses.getFolder(course.id),root=assertRealInside(courseFolder,resolveInside(courseFolder,binding.rootRelPath,{allowRoot:true}))
        const folder=resolveInsideReal(root,directory), files:any[]=[]
        const scan=(relative:string)=>{for(const entry of readdirSync(join(folder,relative),{withFileTypes:true})) {
          const name=relative?`${relative}/${entry.name}`:entry.name
          if(entry.isDirectory()&&['articles','artifacts','results'].includes(name))scan(name)
          else if(entry.isFile()&&allowed(name)) {
            const path=resolveInsideReal(folder,name),size=statSync(path).size
            if(size>64*1024*1024)throw new Error('Learning source exceeds original supported size')
            const hash=native<string>('fs.sha256',{path}),id=`artifact:learning-file:${project.projectId}:${digest(name)}`
            const payload={recordType:'desktop-learning-file',courseID:course.id,projectID:project.projectId,relPath:name,assetRevision:hash,byteCount:size,fileName:basename(name),contentType:'application/json'}
            records.push({id,kind:'artifact',payload,deleted:false,formatVersion:1});sources.set(id,{path,hash,courseID:course.id})
            files.push({recordID:id,relPath:name,assetRevision:hash,byteCount:size})
            assets.push({materialID:id,sha256:hash,path,originalName:basename(name),contentType:'application/json',byteCount:size})
          }
        }}
        scan('');files.sort((a,b)=>a.relPath.localeCompare(b.relPath))
        const id=`artifact:learning-project:${project.projectId}`
        records.push({id,kind:'artifact',payload:{recordType:'desktop-learning-project',id:project.projectId,courseID:course.id,rootRelPath:binding.rootRelPath,stateRevision:project.revision,files},deleted:false,formatVersion:1})
        sources.set(id,{courseID:course.id,root})
      }
    }
    return{records,assets,sources}
  }
  const apply=async(record:SharedRecord,assets:Map<string,string>,local:SharedRecord|undefined,commit:(files:FileChange[],source:any)=>void)=>{
    const p=record.payload,binding={courseId:p.courseID,rootRelPath:p.rootRelPath}
    if (!deps.learning||record.deleted||!Array.isArray(p.files)||p.files.length>100000||typeof p.id!=='string')throw new Error('Unsupported learning project sync format')
    const folder=deps.courses.getFolder(p.courseID),root=assertRealInside(folder,resolveInside(folder,p.rootRelPath,{allowRoot:true}))
    const run=async()=>{
      const files:FileChange[]=[],seen=new Set<string>();let state:any,manifest:any
      for(const item of p.files) {
        if(typeof item.relPath!=='string'||!allowed(item.relPath)||seen.has(item.relPath)||!Number.isInteger(item.byteCount)||item.byteCount<0||item.byteCount>64*1024*1024)throw new Error('Invalid learning project file')
        seen.add(item.relPath)
        const source=assets.get(item.assetRevision)
        if(!source||statSync(source).size!==item.byteCount||native('fs.sha256',{path:source})!==item.assetRevision)throw new Error('Learning project asset is unavailable')
        if(item.relPath==='state.json')state=validateLearningState(JSON.parse(readFileSync(source,'utf8') as string))
        if(item.relPath==='manifest.json')manifest=JSON.parse(readFileSync(source,'utf8') as string)
        const target=assertRealInside(folder,resolveInside(root,`${directory}/${item.relPath}`))
        const prior=local?.payload.files?.find((f:any)=>f.relPath===item.relPath)
        if(prior&&existsSync(target)&&native('fs.sha256',{path:target})!==prior.assetRevision)throw new Error('Learning source changed while pausing its active run')
        if(!existsSync(target)||native('fs.sha256',{path:target})!==item.assetRevision)files.push({source,target})
      }
      if(!state||!manifest||manifest.format!=='bandal-learning'||manifest.formatVersion!==1||manifest.projectId!==p.id||state.projectId!==p.id)throw new Error('Learning manifest and state identity mismatch')
      // Supporting immutable sources publish first; state is the commit point
      // used by the original repository. Recovery journal retains all originals.
      files.sort((a,b)=>(a.target.endsWith('/state.json')?1:0)-(b.target.endsWith('/state.json')?1:0))
      commit(files,{courseID:p.courseID,root})
    }
    if(existsSync(join(root,directory,'state.json'))&&deps.learning.pauseProject)await deps.learning.pauseProject(binding,run)
    else if(existsSync(join(root,directory,'state.json'))&&deps.learning.runtime?.withProjectPaused)await deps.learning.runtime.withProjectPaused(binding,run)
    else await run()
  }
  return{snapshot,apply}
}
