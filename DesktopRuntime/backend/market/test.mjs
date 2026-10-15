import {readFile,writeFile,unlink} from 'node:fs/promises'
import {randomUUID} from 'node:crypto'
let source=await readFile(new URL('../test-backend.mjs',import.meta.url),'utf8')
source=source.replace("'../scripts/dependencies.mjs'","'../../scripts/dependencies.mjs'").replaceAll("new URL('./dist/","new URL('../dist/").replaceAll("new URL('../assets/","new URL('../../assets/")
const runtimeFactory='function runtime(platform) {'
if(source.split(runtimeFactory).length!==2)throw new Error('Native fixture platform injection seam changed')
source=source.replace(runtimeFactory,'function runtime(platform = { invoke: marketPlatform }) {')
source=source.replace('  assert.equal(initialized.schemaVersion, 37)','  await runMarketTests({invoke,backend,environment,require})\n  assert.equal(initialized.schemaVersion, 37)')
source="import {marketPlatform,runMarketTests} from './tests.mjs'\n"+source
const target=new URL(`./.harness-${randomUUID()}.mjs`,import.meta.url)
await writeFile(target,source)
try{await import(target.href)}finally{await unlink(target)}
