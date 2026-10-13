/** For editor plugins that own DOM menus instead of React components. */
export function placeFixedMenu(menu: HTMLElement, x: number, y: number): void {
  const { width, height } = menu.getBoundingClientRect()
  menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - width - 8))}px`
  menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - height - 8))}px`
  menu.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
}
