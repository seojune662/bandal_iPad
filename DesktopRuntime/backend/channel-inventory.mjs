import { readFileSync, writeFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import { dependencies } from '../scripts/dependencies.mjs'
const { require } = dependencies(), ts = require('typescript'), here = dirname(fileURLToPath(import.meta.url))
const contract = resolve(here, '../upstream/src/shared/ipc/contract.ts')
const program = ts.createProgram([contract], { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, skipLibCheck: true })
const source = program.getSourceFile(contract), checker = program.getTypeChecker()
const declaration = source.statements.find(node => ts.isInterfaceDeclaration(node) && node.name.text === 'IpcContract')
if (!declaration) throw new Error('Original IPC contract interface is missing')
const channels = checker.getTypeAtLocation(declaration).getProperties().map(symbol => symbol.name).sort()
const supported = JSON.parse(readFileSync(resolve(here, 'dist/supported-channels.json'), 'utf8'))
const native = new Map()
// Only concrete case labels in services actually dispatched by DesktopShell.
// Prefix canHandle declarations and private primitives are not capabilities.
for (const file of ['DesktopRecordingService.swift', 'DesktopFileServices.swift', 'DesktopAccountService.swift', 'DesktopSystemServices.swift', 'DesktopBrowserHost.swift', 'DesktopCredentialsService.swift', 'DesktopMiniPlayer.swift', 'DesktopCaptureService.swift', 'DesktopShell.swift']) {
  const source = readFileSync(resolve(here, '../../App/Desktop', file), 'utf8')
  const matches = [...source.matchAll(/^\s*case ((?:"[^"]+"(?:,\s*)?)+):/gm)]
  for (const [index, match] of matches.entries()) {
    const body = source.slice(match.index + match[0].length, matches[index + 1]?.index ?? source.length)
    for (const value of match[1].matchAll(/"([^"]+)"/g)) {
      const channel = value[1]
      if (!channels.includes(channel)) continue
      const line = source.slice(0, match.index).split('\n').length
      native.set(channel, { file: 'App/Desktop/' + file, line, ...(body.includes('throw DesktopBrowserError.unsupported') || body.includes('"phase": "unsupported"') ? { unavailable: true } : {}) })
    }
  }
}
// Concrete guards that dispatch outside switch statements, reviewed separately.
// These anchors include the executable call/operation, not a canHandle promise.
for (const [channel, file, anchor] of [
  ['credentials:capture', 'DesktopCredentialsService.swift', 'if channel == "credentials:capture" || channel == "credentials:fill" { return try await pageRequest'],
  ['credentials:fill', 'DesktopCredentialsService.swift', 'if channel == "credentials:capture" || channel == "credentials:fill" { return try await pageRequest'],
  ['assistant:capture', 'DesktopCaptureService.swift', 'let captured = try await snapshot(container)'],
  ['assistant:selection', 'DesktopCaptureService.swift', 'body["channel"] as? String == "assistant:selection"']
]) {
  const source = readFileSync(resolve(here, '../../App/Desktop', file), 'utf8'), position = source.indexOf(anchor)
  if (position < 0) throw new Error(`Reviewed native dispatch anchor changed: ${channel}`)
  native.set(channel, { file: 'App/Desktop/' + file, line: source.slice(0, position).split('\n').length })
}
const overrides = new Map()
function classify(list, state, reason) { for (const name of list) overrides.set(name, { state, reason }) }
classify(['agent:install', 'agent:login', 'agent:reopenLogin', 'agent:submitLoginCode', 'agent:cancelLogin', 'agent:installCommand'], 'unavailable', 'iPad has no local CLI process. Handler reports unsupported/ok:false; API-key controls replace CLI setup in the original provider card.')
classify(['agent:skills'], 'unavailable', 'Executable local skills are not connected; enumeration returns an empty list, not a functioning runtime.')
classify(['desktopAgent:permissionStatus', 'desktopAgent:openPermissionSettings'], 'unavailable', 'iPad has no cross-app screen/accessibility automation grant. Status is explicitly unsupported; opening a nonexistent OS permission throws. App-local capture uses a separate concrete service.')
classify(['browser:extensions', 'browser:importSources'], 'unavailable', 'Enumeration is empty because Chromium extension and other-app browser import runtimes are unavailable.')
classify(['browser:pageAction'], 'partial', 'Concrete WK actions exist; Chromium DevTools and undocumented page actions reject explicitly.')
classify(['agent:availability', 'agent:models', 'chat:open', 'chat:send', 'chat:context', 'chat:setConfiguration', 'chat:setModel'], 'partial', 'Native API transport uses original sessions/tools; local CLI skills and arbitrary executable work are unavailable. WK browser tools enforce original grants/policies; semantic keys, approved submission/file attachment and original Canvas LMS recipes are connected. Trusted OS key injection and cross-origin frames are unavailable. Real keys/provider access remain external validation gates.')
classify(['mcp:list', 'mcp:save', 'mcp:delete', 'mcp:test'], 'partial', 'Original encrypted registry and original screen-assistant-only scope plus real HTTPS Streamable HTTP initialize/list/call are connected; native Keychain encryption and once approvals protect secrets/actions. Local stdio servers reject explicitly; real user server interoperability remains unverified.')
classify(['assistant:capture', 'assistant:selection'], 'partial', 'Original region selection UI returns a bounded PNG of the current app only. Other applications and protected video content cannot be captured. Native capture regression tests and physical-device validation are tracked separately.')
classify(['presentation:runtime', 'presentation:prepare', 'presentation:installRuntime'], 'partial', 'Native OOXML preparation and authenticated legacy PPT conversion client are implemented. User confirmed no deployed PPT conversion server yet; real legacy PPT conversion remains blocked on that external service.')
classify(['mail:connect', 'mail:list', 'mail:read', 'mail:modify', 'mail:reply'], 'partial', 'Native Gmail OAuth/REST operations and original inbox/thread/send contracts are implemented. User confirmed no Google iOS OAuth client is configured yet; real mailbox access remains blocked on that external configuration.')
classify(['learning:addArticle'], 'partial', 'Public article extraction, original Readability validation and durable snapshots are connected. Course-owned source-tab extraction is wired to the native browser with URL/generation validation; real authenticated sites remain an external validation gate.')
classify(['learning:run', 'learning:runRetry', 'study:generate'], 'partial', 'Original grounded quiz/card/summary runtime and cancellation are connected. Browser-assisted find-articles now uses the native WK bridge; real web/provider access and all learning-pack combinations require further end-to-end validation.')
classify(['plugins:list', 'plugins:installFromFolder', 'plugins:getSettings', 'plugins:setSetting', 'plugins:resetSettings'], 'partial', 'Original validated plugin registry/settings persist. Installed code is disabled until approval; executable extension host is not ported.')
classify(['plugins:catalog', 'plugins:installFromCatalog'], 'partial', 'Original catalog service and verified archive installer are connected through a bounded tokenless transport. Installing a workflow pack is supported; executable extension host approval/enabling/execution is not ported. Real user catalogs remain an external validation gate.')
classify(['settings:get', 'settings:set', 'settings:reset'], 'partial', 'Original settings schema/persistence works; a stored preference alone does not prove that every native effect is implemented. See settings audit.')
classify(['permissions:status', 'permissions:request', 'permissions:openSettings'], 'partial', 'iPad notifications permission/settings work; macOS screen/accessibility permissions correctly report not-applicable.')
classify(['window:getState'], 'partial', 'Reports the iPad host state, not desktop native-window controls.')
const rows = channels.map(channel => {
  const swift = native.get(channel), registry = supported.includes(channel), override = overrides.get(channel)
  let state = swift?.unavailable ? 'unavailable' : swift || registry ? 'connected' : 'unregistered'
  let reason = swift?.unavailable ? 'Concrete Swift branch rejects this unsupported operation.' : swift ? 'Concrete Swift dispatch case exists.' : registry ? 'Observed in initialized backend registry using temporary fixture storage.' : 'No concrete public backend or Swift handler. Requests reject; this feature is not complete.'
  if (override) ({ state, reason } = override)
  return { channel, state, route: swift ? 'swift' : registry ? 'typescript' : null, ...(swift ? { evidence: `${swift.file}:${swift.line}` } : {}), reason }
})
const counts = Object.fromEntries(['connected', 'partial', 'unavailable', 'unregistered'].map(state => [state, rows.filter(row => row.state === state).length]))
const report = { source: 'Byte-preserved original desktop IpcContract including inherited contracts', total: channels.length,
  definitions: { connected: 'Concrete dispatch exists; not an end-to-end or physical-device completeness claim.', partial: 'Working subset plus listed gap.', unavailable: 'Explicit unsupported response or unavailable empty enumeration.', unregistered: 'No concrete public handler found.' },
  method: 'Backend fixture registry + exact Swift case labels. canHandle prefix declarations never count as implementation. Private native service channels excluded.',
  backendBundleSha256: createHash('sha256').update(readFileSync(resolve(here, 'dist/backend.js'))).digest('hex'),
  counts, registeredBackendChannels: supported.length, extraBackendChannels: supported.filter(c => !channels.includes(c)), rows,
  groups: Object.fromEntries([...new Set(rows.filter(row => row.state !== 'connected').map(row => row.channel.split(':')[0]))].map(group => [group, rows.filter(row => row.state !== 'connected' && row.channel.startsWith(group + ':')).map(row => row.channel)])) }
writeFileSync(resolve(here, 'channel-coverage.json'), JSON.stringify(report, null, 2) + '\n')
console.log(`Original IPC ${report.total}; ${JSON.stringify(counts)}. Concrete handlers are not a completion claim.`)
