import { fileURLToPath } from 'node:url'
const panel = fileURLToPath(new URL('./SyncPanel.tsx', import.meta.url))
export function adaptSyncSource(code, id) {
  if (!id.endsWith('/features/settings/AccountPanel.tsx')) return null
  const anchor = '<section className="settings-card account-sign-out-card">'
  if (code.split(anchor).length !== 2) throw new Error('Account sync integration anchor changed')
  return { code: `import { SyncPanel } from ${JSON.stringify(panel)}\n` + code.replace(anchor, '<SyncPanel />\n      ' + anchor), map: null }
}
export default function syncPlugin() { return { name: 'bandal-account-sync', enforce: 'pre', transform: adaptSyncSource } }
