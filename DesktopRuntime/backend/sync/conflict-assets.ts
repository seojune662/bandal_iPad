import { env,native } from '../native'
import { copyFileSync,existsSync,mkdirSync,openSync,closeSync,fsyncSync,renameSync,rmSync } from '../shims/fs'
import { randomUUID } from '../shims/crypto'
import { join } from '../shims/path'
import { resolveInsideReal } from '../../upstream/src/main/db/validate'
import type { SharedRecord } from './format'

export function preserveConflictAssets(db:any,record:SharedRecord|undefined,provided:Map<string,string>) {
  if(!record||record.deleted)return[]
  const p=record.payload,refs:{sha256:string,path?:string}[]=[],mapped=db.prepare('SELECT source_json FROM ipad_sync_projection WHERE id=?').get(record.id)
  const source=mapped?JSON.parse(mapped.source_json):{}
  if(record.kind==='material'&&p.kind!=='whiteboard') {
    const m=db.prepare('SELECT m.*,c.folder_path FROM materials_index m JOIN courses c ON c.id=m.course_id WHERE m.id=?').get(p.id)
    refs.push({sha256:p.revision,path:m?resolveInsideReal(m.folder_path,m.rel_path):source.path})
  }else if(record.kind==='recording')refs.push({sha256:p.assetRevision,path:source.path})
  else if(record.kind==='artifact'&&p.recordType==='desktop-learning-file')refs.push({sha256:p.assetRevision,path:source.path})
  else if(record.kind==='artifact'&&p.recordType==='desktop-learning-project') {
    const c=db.prepare('SELECT folder_path FROM courses WHERE id=?').get(p.courseID)
    for(const file of p.files??[])refs.push({sha256:file.assetRevision,path:c?resolveInsideReal(c.folder_path,join(p.rootRelPath,'.bandal/learning',file.relPath)):undefined})
  }
  const root=join(env().userDataPath,'SyncConflictAssets');mkdirSync(root,{recursive:true})
  const result=[]
  for(const ref of refs) {
    if(typeof ref.sha256!=='string'||!/^[0-9a-f]{64}$/.test(ref.sha256))continue
    const target=join(root,ref.sha256)
    if(!existsSync(target)||native('fs.sha256',{path:target})!==ref.sha256) {
      const path=[provided.get(ref.sha256),ref.path].find(path=>path&&existsSync(path)&&native('fs.sha256',{path})===ref.sha256)
      if(!path)continue // A missing remote asset is still a reviewable conflict.
      const temporary=join(root,`${ref.sha256}.${randomUUID()}.tmp`)
      try {
        copyFileSync(path,temporary,1)
        const fd=openSync(temporary,'r');try{fsyncSync(fd)}finally{closeSync(fd)}
        if(native('fs.sha256',{path:temporary})!==ref.sha256)throw new Error('Source changed while preserving conflict asset')
        renameSync(temporary,target)
      }finally{rmSync(temporary,{force:true})}
    }
    if(native('fs.sha256',{path:target})!==ref.sha256)throw new Error('Conflict recovery asset integrity failed')
    result.push({sha256:ref.sha256,path:target})
  }
  return result
}
