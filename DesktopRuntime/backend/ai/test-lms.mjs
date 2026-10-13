import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createRequire } from 'node:module'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'
const { require } = dependencies()
const { build } = createRequire(require.resolve('vite'))('esbuild')
const SQLite = require('better-sqlite3-node')
const directory = await mkdtemp(join(tmpdir(),'bandal-lms-fixture-'))
const responseConstructor = globalThis.Response
try {
  delete globalThis.Response // Match the actual JavaScriptCore environment.
  const output = join(directory,'fixture.cjs')
  await build({entryPoints:[resolve(runtime,'backend/ai/browser-lms.ts')],outfile:output,bundle:true,platform:'node',format:'cjs',target:'node22',plugins:[{
    name:'isolated-settings-fixture',setup(build) { build.onLoad({filter:/\/settingsStore\.ts$/},()=>({contents:'export const getSettings=()=>globalThis.__lmsSettings',loader:'ts'})) }
  }]})
  globalThis.__lmsSettings = {university:{universityId:'snu'}}
  const { createLMSBrowserTools } = require(output), db = new SQLite(':memory:')
  db.exec('CREATE TABLE browser_seen(course_id TEXT,list_key TEXT,item_key TEXT,title TEXT,first_seen TEXT,PRIMARY KEY(course_id,list_key,item_key))')
  let active = true, requested = [], grants = [], payload = [{id:1,title:'공지 1',posted_at:'2026-10-14T00:00:00Z',html_url:'https://myetl.snu.ac.kr/courses/123/discussion_topics/1'}], status = 200
  const tools = createLMSBrowserTools({db,courseId:'course',courseLinks:{list:()=>[{url:'https://myetl.snu.ac.kr/courses/123',lmsCourseId:'123'}]},
    enabled:()=>{if(!active)throw new Error('cancelled')},gate:async(url,capability)=>{grants.push([url,capability])},log:()=>{},
    native:async(tool,input)=>{requested.push([tool,input]);return{httpStatus:status,text:JSON.stringify(payload)}}})
  assert.deepEqual(tools.lms_course_page('course'),{url:'https://myetl.snu.ac.kr/courses/123',platform:'canvas'})
  const list = await tools.lms_list('course','announcements')
  assert.equal(list.status,'ok'); assert.equal(list.items[0].title,'공지 1')
  assert.equal(requested[0][0],'lmsFetch'); assert.equal(requested[0][1].url,'https://myetl.snu.ac.kr/api/v1/courses/123/discussion_topics?only_announcements=true&per_page=20')
  assert.deepEqual(grants[0],['https://myetl.snu.ac.kr','read'])
  const first = await tools.lms_new_items('course','announcements'); assert.equal(first.firstRun,true); assert.equal(first.items.length,0)
  payload.push({id:2,title:'공지 2',posted_at:'2026-10-14T01:00:00Z'})
  const fresh = await tools.lms_new_items('course','announcements'); assert.equal(fresh.firstRun,false); assert.equal(fresh.items.length,1); assert.equal(fresh.items[0].title,'공지 2')
  assert.equal((await tools.lms_new_items('course','announcements')).items.length,0)
  await assert.rejects(tools.lms_list('other-course','files'),/이 대화/)
  status = 401; assert.match((await tools.lms_list('course','files')).message,/로그인/)
  active = false; await assert.rejects(tools.lms_list('course','files'),/cancelled/)
  db.close(); delete globalThis.__lmsSettings
  console.log('PASS original Canvas recipe URLs/parser + exact-origin read gate + real SQLite first/delta seen history + course/login/cancellation boundaries')
} finally {globalThis.Response = responseConstructor;await rm(directory,{recursive:true,force:true})}
