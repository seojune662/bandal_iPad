/** Only pages created by our tab manager qualify for privileged browser bridges. */
const pages = new Set<number>()
export const isManagedBrowserPage = (id: number): boolean => pages.has(id)
export const registerManagedPage = (id: number): void => { pages.add(id) }
export const forgetManagedPage = (id: number): void => { pages.delete(id) }
