import { invoke } from '../../lib/ipc'
import { updateComposerDraft } from './composerDraftStore'
export type QuickAction = 'region' | 'current' | 'screen' | 'file'
export async function prepareQuickAction(action: QuickAction, id: string): Promise<boolean> {
  if (action === 'region' || action === 'screen') {
    const image = await invoke('assistant:capture', { region: action === 'region' })
    if (!image) return false
    updateComposerDraft(id, current => ({ images: [...current.images, image].slice(-5) }))
  } else if (action === 'file') {
    const { paths } = await invoke('chat:pickAttachments', {})
    if (!paths.length) return false
    updateComposerDraft(id, current => ({ files: [...current.files, ...paths.map(path => ({ path, name: path.split(/[\\/]/).pop() ?? path }))].slice(0, 20) }))
  }
  return true
}
