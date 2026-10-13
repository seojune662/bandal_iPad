import { dependencies, runtime } from './dependencies.mjs'
import { adaptPlatformSource } from '../renderer/platform/index.mjs'

// Type-check the actually adapted platform API, not just the pristine snapshot.
// Source-preserving adapters deliberately leave desktop-only declarations for
// tree-shaking; unused declaration diagnostics remain covered by raw tsc.
const ts = dependencies().require('typescript')
const parsed = ts.getParsedCommandLineOfConfigFile(runtime + '/tsconfig.json', {
  noUnusedLocals: false, noUnusedParameters: false, allowImportingTsExtensions: true
}, { ...ts.sys, onUnRecoverableConfigFileDiagnostic: diagnostic => { throw new Error(ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')) } })
const host = ts.createCompilerHost(parsed.options), originalRead = host.readFile
host.readFile = file => {
  const source = originalRead(file)
  return source && file.startsWith(runtime + '/upstream/') ? adaptPlatformSource(source, file)?.code ?? source : source
}
const program = ts.createProgram(parsed.fileNames, parsed.options, host)
const diagnostics = ts.getPreEmitDiagnostics(program)
if (diagnostics.length) {
  console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics, { getCurrentDirectory: () => runtime, getCanonicalFileName: path => path, getNewLine: () => '\n' }))
  process.exitCode = 1
} else console.log('Original renderer with iPad platform transforms: strict TypeScript passed')
