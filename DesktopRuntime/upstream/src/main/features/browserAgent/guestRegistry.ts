/**
 * tabId → the guest WebContents the agent may drive.
 *
 * Every lookup re-validates, rather than trusting what the renderer told us
 * earlier: a WebContents id is reused after destruction, and a stale mapping
 * would hand the agent something that is no longer a browser guest at all.
 * The checks mirror `credentials/loginFiller.resolveGuest`, which already
 * solved this for password filling.
 */

export interface GuestWebContents {
  id: number
  getType: () => string
  getURL: () => string
  getTitle: () => string
  isDestroyed: () => boolean
  session: { storagePath?: string } | unknown
}

export interface GuestRegistryDeps {
  isManagedPage?: (guest: GuestWebContents) => boolean
  fromId: (id: number) => GuestWebContents | null
  /** Confirms the guest is on the hardened browsing partition. */
  isBrowsingPartition: (guest: GuestWebContents) => boolean
}

export function createGuestRegistry(deps: GuestRegistryDeps) {
  const byTab = new Map<string, number>()

  return {
    register(tabId: string, webContentsId: number): void {
      if (typeof tabId !== 'string' || tabId === '') return
      if (!Number.isInteger(webContentsId)) return
      byTab.set(tabId, webContentsId)
    },

    forget(tabId: string): void {
      byTab.delete(tabId)
    },

    /**
     * The live guest for a tab, or null. Never returns something that is not
     * a `webview` on the browsing partition — the agent must not be able to
     * reach the app's own renderer.
     */
    resolve(tabId: string): GuestWebContents | null {
      const id = byTab.get(tabId)
      if (id === undefined) return null
      try {
        const guest = deps.fromId(id)
        if (guest === null || guest.isDestroyed()) {
          byTab.delete(tabId)
          return null
        }
        if (guest.getType() !== 'webview' && !deps.isManagedPage?.(guest)) return null
        if (!deps.isBrowsingPartition(guest)) return null
        return guest
      } catch {
        return null
      }
    }
  }
}
