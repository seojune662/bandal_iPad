export type TabDensity = 'regular' | 'compact' | 'icon'

export interface AdaptiveTabLayout {
  width: number
  density: TabDensity
  visible: number[]
}

/** Keep complete, usable targets on screen. Surplus tabs stay in the full list. */
export function adaptiveTabLayout(available: number, count: number, activeIndex: number): AdaptiveTabLayout {
  if (count <= 0 || !Number.isFinite(available) || available < 32)
    return { width: 0, density: 'icon', visible: [] }
  const capacity = Math.min(count, Math.max(1, Math.floor(available / 32)))
  const visible = Array.from({ length: capacity }, (_, index) => index)
  if (activeIndex >= capacity && activeIndex < count) visible[capacity - 1] = activeIndex
  const width = Math.min(208, available / capacity)
  return { width, density: width >= 104 ? 'regular' : width >= 56 ? 'compact' : 'icon', visible }
}

function setStyle(element: HTMLElement, name: string, value: string): void {
  if (element.style.getPropertyValue(name) !== value) element.style.setProperty(name, value)
}

/** macOS leading clearance and Windows caption inset are never compressible. */
export function headerChromeInset(header: HTMLElement): number {
  const prefix = header.querySelector<HTMLElement>(':scope > .dv-pre-actions-container')?.getBoundingClientRect().width ?? 0
  const actions = header.querySelector<HTMLElement>('.workspace-group-actions')
  if (!actions) return prefix
  const style = getComputedStyle(actions)
  return prefix + (parseFloat(style.marginLeft) || 0) + (parseFloat(style.marginRight) || 0)
}

export function minimumHeaderWidth(chromeInset: number, workspaceWidth: number): number {
  // Full-list button (32), selected icon (32), action padding (4), and <8px
  // removed by Dockview's gap allocation after enforcing its size constraint.
  return Math.max(100, Math.min(Math.ceil(chromeInset + 76), Math.max(100, workspaceWidth)))
}

/** Layout restoration can replace headers while preserving their live contents. */
export function focusWorkspaceHeader(group: HTMLElement | null | undefined): boolean {
  if (!group?.isConnected || group.closest('[hidden], [inert]')) return false
  const target = group.querySelector<HTMLElement>('.dv-tab.dv-active-tab:not([data-tab-overflow]), .workspace-open-tabs-button')
  target?.focus({ preventScroll: true })
  return !!target && document.activeElement === target
}

/** Also called synchronously before keyboard focus enters a formerly hidden tab. */
export function layoutAdaptiveTabs(root: ParentNode): void {
  for (const strip of root.querySelectorAll<HTMLElement>('.dv-tabs-container.dv-horizontal')) {
    const header = strip.parentElement
    if (!header || header.closest('.workspace-course[hidden]')) continue
    const headerWidth = header.getBoundingClientRect().width
    if (headerWidth <= 0) continue
    const compact = headerWidth - headerChromeInset(header) < 200
    if (header.hasAttribute('data-tab-header-compact') !== compact) header.toggleAttribute('data-tab-header-compact', compact)
    const style = getComputedStyle(header)
    const inset = (parseFloat(style.paddingLeft) || 0) + (parseFloat(style.paddingRight) || 0) +
      (parseFloat(style.borderLeftWidth) || 0) + (parseFloat(style.borderRightWidth) || 0)
    const reserved = [...header.children].reduce((width, node) => {
      if (!(node instanceof HTMLElement) || node === strip || node.classList.contains('dv-void-container')) return width
      const computed = getComputedStyle(node)
      return width + node.getBoundingClientRect().width + (parseFloat(computed.marginLeft) || 0) + (parseFloat(computed.marginRight) || 0)
    }, inset)
    const tabs = [...strip.children].filter((node): node is HTMLElement => node instanceof HTMLElement && node.classList.contains('dv-tab'))
    const layout = adaptiveTabLayout(Math.max(0, headerWidth - reserved), tabs.length, tabs.findIndex(tab => tab.classList.contains('dv-active-tab')))
    const visible = new Set(layout.visible)
    strip.dataset.tabDensity = layout.density
    strip.setAttribute('role', 'tablist')
    strip.setAttribute('aria-label', '이 분할의 열린 탭')
    setStyle(strip, '--workspace-adaptive-tab-width', `${layout.width}px`)
    setStyle(strip, 'width', `${layout.width * layout.visible.length}px`)
    for (const [index, tab] of tabs.entries()) {
      const hidden = !visible.has(index)
      if (tab.hasAttribute('data-tab-overflow') !== hidden) tab.toggleAttribute('data-tab-overflow', hidden)
      if (hidden) tab.setAttribute('aria-hidden', 'true')
      else tab.removeAttribute('aria-hidden')
    }
    if (strip.scrollLeft !== 0) strip.scrollLeft = 0
  }
}

/** One observer per workspace, independent of live panel/editor lifetimes. */
export function installAdaptiveTabs(root: HTMLElement): () => void {
  let frame = 0
  const observed = new Set<Element>()
  const schedule = (): void => {
    if (!frame) frame = requestAnimationFrame(update)
  }
  const resize = new ResizeObserver(schedule)
  const update = (): void => {
    frame = 0
    const current = new Set<Element>([root, ...root.querySelectorAll('.dv-tabs-and-actions-container, .dv-pre-actions-container, .dv-left-actions-container, .dv-right-actions-container')])
    for (const element of observed) if (!current.has(element)) { resize.unobserve(element); observed.delete(element) }
    for (const element of current) if (!observed.has(element)) { resize.observe(element); observed.add(element) }
    layoutAdaptiveTabs(root)
  }
  const mutations = new MutationObserver(schedule)
  mutations.observe(root, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'hidden'] })
  window.addEventListener('resize', schedule)
  update()
  return () => {
    cancelAnimationFrame(frame)
    mutations.disconnect()
    resize.disconnect()
    window.removeEventListener('resize', schedule)
  }
}
