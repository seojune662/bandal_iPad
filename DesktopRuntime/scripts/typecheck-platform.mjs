import nativePDFPlugin from '../renderer/nativePDF/index.mjs'
import { dependencies, runtime } from './dependencies.mjs'
import { adaptPlatformSource } from '../renderer/platform/index.mjs'
import { adaptBrowserSource } from '../renderer/browser/index.mjs'
import pencilInputPlugin from '../renderer/pencil/index.mjs'
import nativeRecordingPlugin from '../renderer/recording/index.mjs'
import { adaptNativeSurfacesSource } from '../renderer/ipad/nativeSurfacesPlugin.mjs'
import { adaptLayoutSource } from '../renderer/ipad/layout/index.mjs'
import { adaptInputSource } from '../renderer/ipad/input/index.mjs'
import { adaptStabilitySource } from '../renderer/ipad/stability/index.mjs'
import { adaptTouchSource } from '../renderer/ipad/touch/index.mjs'
import { adaptIpadUISource } from '../renderer/ipad/ui/index.mjs'

// Type-check the actually adapted platform API, not just the pristine snapshot.
// Source-preserving adapters deliberately leave desktop-only declarations for
// tree-shaking; unused declaration diagnostics remain covered by raw tsc.
const ts = dependencies().require('typescript')
const parsed = ts.getParsedCommandLineOfConfigFile(runtime + '/tsconfig.json', {
  noUnusedLocals: false, noUnusedParameters: false, allowImportingTsExtensions: true
}, { ...ts.sys, onUnRecoverableConfigFileDiagnostic: diagnostic => { throw new Error(ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')) } })
const host = ts.createCompilerHost(parsed.options), originalRead = host.readFile
const transforms = [pencilInputPlugin().transform, adaptPlatformSource, nativeRecordingPlugin().transform, adaptBrowserSource, nativePDFPlugin().transform, adaptNativeSurfacesSource, adaptLayoutSource, adaptInputSource, adaptStabilitySource, adaptTouchSource, adaptIpadUISource]
host.readFile = file => {
  let source = originalRead(file)
  if (source && (file.startsWith(runtime + '/upstream/') || file.startsWith(runtime + '/renderer/'))) for (const transform of transforms) source = transform(source, file)?.code ?? source
  return source
}
const program = ts.createProgram(parsed.fileNames, parsed.options, host)
const diagnostics = ts.getPreEmitDiagnostics(program)
if (diagnostics.length) {
  console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics, { getCurrentDirectory: () => runtime, getCanonicalFileName: path => path, getNewLine: () => '\n' }))
  process.exitCode = 1
} else console.log('Original renderer with iPad platform transforms: strict TypeScript passed')
