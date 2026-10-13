import {readFile,writeFile,unlink} from 'node:fs/promises'
import {randomUUID} from 'node:crypto'
import '../test-text-decoder.mjs'
let source=await readFile(new URL('../test-backend.mjs',import.meta.url),'utf8')
source=source.replace("'../scripts/dependencies.mjs'","'../../scripts/dependencies.mjs'").replaceAll("new URL('./dist/","new URL('../dist/").replaceAll("new URL('../assets/","new URL('../../assets/")
const start=source.indexOf('    __bandalPlatform: { invoke: async (channel, input) =>'),end=source.indexOf('\n    setInterval:',start)
if(start<0||end<0)throw new Error('Native fixture seam changed')
source=source.slice(0,start)+'    __bandalPlatform: { invoke: hoverPlatform },'+source.slice(end)
source=source.replace('  assert.equal(initialized.schemaVersion, 37)','  await runHoverTests({invoke,backend,environment})\n  assert.equal(initialized.schemaVersion, 37)')
source="import {hoverPlatform,runHoverTests} from './tests.mjs'\n"+source
const target=new URL(`./.harness-${randomUUID()}.mjs`,import.meta.url)
await writeFile(target,source)
try{await import(target.href)}finally{await unlink(target)}
