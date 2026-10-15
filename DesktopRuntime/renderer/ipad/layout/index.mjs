import { fileURLToPath } from 'node:url'
const viewport = fileURLToPath(new URL('./viewport.ts', import.meta.url))
const components = fileURLToPath(new URL('./layout.tsx', import.meta.url))
const focusTrap = fileURLToPath(new URL('../../../upstream/src/renderer/src/components/useFocusTrap.ts', import.meta.url))
function replace(source, anchor, value, count = 1) {
  if (source.split(anchor).length - 1 !== count) throw new Error(`iPad layout anchor changed: ${anchor.slice(0, 100)}`)
  return source.split(anchor).join(value)
}
export function adaptLayoutSource(source, id) {
  if (id.endsWith('/lib/useViewportBounds.ts')) {
    replace(source, 'export function useViewportBounds(ref: RefObject<HTMLElement>): void {', '')
    return { code: `export { useViewportBounds } from ${JSON.stringify(viewport)}`, map: null }
  }
  let code = source
  const imports = names => { code = `import { ${names} } from ${JSON.stringify(components)}\n` + code }
  if (id.endsWith('/app/AppShell.tsx')) {
    imports('useIpadShellLayout, IpadRailControls, IpadBackdrop, IpadShellChrome')
    code = replace(code, 'export function AppShell(): JSX.Element {', 'export function AppShell(): JSX.Element {\n  const ipad = useIpadShellLayout()')
    code = replace(code, 'className="app-shell"', 'className="app-shell ipad-shell" data-ipad-side={ipad.side ?? "none"} data-ipad-pinned={ipad.pinned ?? "none"} data-ipad-panel={ipad.presentation} data-ipad-left={ipad.panels.left} data-ipad-materials={ipad.panels.materials} data-ipad-assistant={ipad.panels.assistant}')
    code = replace(code, '      <GlobalNavigation />', `      <GlobalNavigation />
      {ipad.overlay && <IpadBackdrop close={ipad.close} />}
      <section className="ipad-left-surface" aria-owns={ipad.panels.left === 'overlay' ? 'ipad-global-navigation' : undefined} aria-label="내 공간" role={ipad.panels.left === 'overlay' ? 'dialog' : 'complementary'} aria-modal={ipad.panels.left === 'overlay' || undefined} hidden={ipad.panels.left === 'closed' || ipad.panels.left === 'suspended'} {...{ inert: ipad.overlayOwner && ipad.overlayOwner !== 'left' ? '' : undefined }}>
      <IpadRailControls layout={ipad} side="left" />
`)
    code = replace(code, '      {leftRailOpen && courseRailVisible && !settingsPresent && <RailResizer side="left" />}', '      </section>')
    code = replace(code, 'inert: settingsPresent ? \'\' : undefined', 'inert: settingsPresent || ipad.overlay ? \'\' : undefined')
    code = replace(code, '<div className="shell-materials-rail"', '<div className="shell-materials-rail ipad-right-surface" role={ipad.panels.materials === \'overlay\' ? \'dialog\' : \'complementary\'} aria-modal={ipad.panels.materials === \'overlay\' || undefined} aria-label="자료"')
    code = replace(code, 'inert: !materialsRailVisible || settingsPresent ?', 'inert: !materialsRailVisible || settingsPresent || ipad.panels.materials === \'suspended\' || !!ipad.overlayOwner && ipad.overlayOwner !== \'materials\' ?')
    code = replace(code, '        <MaterialsSidebar course={selectedCourse} />', '        <IpadRailControls layout={ipad} side="right" />\n        <MaterialsSidebar course={selectedCourse} />')
    code = replace(code, '      {materialsRailVisible && !settingsPresent && <RailResizer side="right" />}', '')
    code = replace(code, '      <ShellChrome />', '      <IpadShellChrome />')
    code = replace(code, 'className="settings-overlay shell-settings-overlay" data-open={isSettingsOpen}', 'className="settings-overlay shell-settings-overlay" role="dialog" aria-modal="true" aria-label="설정" data-open={isSettingsOpen}')
  }
  if (id.endsWith('/app/shortcuts.ts')) {
    imports('activateIpadAuxiliary, isIpadRailVisible')
    code = replace(code, '      ui.showCourses()', "      ui.showCourses(); activateIpadAuxiliary('left')")
    code = replace(code, 'if (!ui.rightRailOpen) ui.toggleRightRail()', "if (!isIpadRailVisible('materials')) ui.toggleRightRail()")
  }
  if (id.endsWith('/stores/uiStore.ts')) {
    imports('toggleIpadRail')
    code = replace(code, '  leftRailOpen: true,\n  courseRailOpen: true,', '  leftRailOpen: false,\n  courseRailOpen: true,')
    code = replace(code, '  rightRailOpen: true,', '  rightRailOpen: false,')
    code = replace(code, 'leftRailOpen: !state.leftRailOpen,', "leftRailOpen: toggleIpadRail('left', state.leftRailOpen),")
    code = replace(code, 'rightRailOpen: !state.rightRailOpen', "rightRailOpen: toggleIpadRail('materials', state.rightRailOpen)")
  }
  if (id.endsWith('/app/GlobalNavigation.tsx')) {
    // The desktop icon rail is always available, independently of the main sidebar.
    imports('useIpadNavigationBlocked, useIpadRailVisible, activateIpadAuxiliary')
    code = replace(code, '  const phase =', '  const navigationBlocked = useIpadNavigationBlocked()\n  const leftVisible = useIpadRailVisible(\'left\')\n  const phase =')
    code = replace(code, 'className="global-navigation"', 'className="global-navigation" id="ipad-global-navigation"')
    code = replace(code, 'aria-hidden={!leftOpen}', 'aria-hidden={navigationBlocked}')
    code = replace(code, "inert: !leftOpen ? '' : undefined", "inert: navigationBlocked ? '' : undefined")
    code = replace(code, "    if (ui.isSettingsOpen || ui.isBoardOverlayOpen || ui.isLinkGraphOpen || ui.leftRailPanel !== 'courses') ui.showCourses()", "    if (!leftVisible || ui.isSettingsOpen || ui.isBoardOverlayOpen || ui.isLinkGraphOpen || ui.leftRailPanel !== 'courses') { ui.showCourses(); activateIpadAuxiliary('left') }")
    code = replace(code, 'else ui.toggleCourseRail()', 'else ui.toggleLeftRail()')
    code = replace(code, '  const openCourses = (): void => {', "  const openCourses = (): void => {\n    activateIpadAuxiliary('left')")
    code = replace(code, 'onClick={openLearningHome}', "onClick={() => { activateIpadAuxiliary('left'); openLearningHome() }}")
    code = replace(code, 'if (event.button === 0) event.preventDefault()', "if (event.button === 0 && event.pointerType !== 'touch') event.preventDefault()")
    code = replace(code, 'if (event.button === 0) { event.preventDefault(); void captureLauncherContext() }', "if (event.button === 0) { if (event.pointerType !== 'touch') event.preventDefault(); void captureLauncherContext() }")
    code = replace(code, '            useUiStore.getState().togglePluginsPanel()', "            activateIpadAuxiliary('left')\n            if (!leftVisible) useUiStore.setState({ courseRailOpen: false })\n            useUiStore.getState().togglePluginsPanel()")
    code = replace(code, "surface === 'course' && courseOpen", "surface === 'course' && leftVisible && courseOpen", 2)
    code = replace(code, "aria-expanded={courseOpen", "aria-expanded={leftVisible && courseOpen")
    code = replace(code, "surface !== 'study-market' && courseOpen", "surface !== 'study-market' && leftVisible && courseOpen", 2)
  }
  if (id.endsWith('/features/ai/AiShortcuts.tsx')) {
    code = replace(code, '<span>AI</span>', "<span>{ko ? 'AI 웹 서비스' : 'AI websites'}</span>")
    code = replace(code, 'useState(readAiShortcutsCollapsed)', "useState(() => { try { return localStorage.getItem('bandal:ai-shortcuts:collapsed:v1') === null ? true : readAiShortcutsCollapsed() } catch { return true } })")
  }
  if (id.endsWith('/features/settings/SettingsApp.tsx')) {
    imports('useIpadSettingsNavigation, useIpadSettingsModal, IpadSettingsHeader')
    code = replace(code, '  const t = useT();', '  const t = useT();\n  const ipadSettings = useIpadSettingsNavigation(initialCategory);')
    code = replace(code, '  const isSettingsOpen = useUiStore((state) => state.isSettingsOpen);', '  const isSettingsOpen = useUiStore((state) => state.isSettingsOpen);\n  const ipadSettingsRoot = useIpadSettingsModal(!embedded || isSettingsOpen, onClose);')
    code = replace(code, '      className={`settings-app${embedded ? " settings-app--embedded" : ""}`}', '      ref={ipadSettingsRoot} className={`settings-app ipad-settings${embedded ? " settings-app--embedded" : ""}`} data-ipad-settings-detail={ipadSettings.detail} data-ipad-settings-narrow={ipadSettings.narrow}')
    code = replace(code, '      <div className="settings-layout">', '      <IpadSettingsHeader navigation={ipadSettings} title={active.label} close={onClose} />\n      <div className="settings-layout">')
    code = replace(code, 'aria-hidden={embedded && !leftRailOpen}', 'aria-hidden={ipadSettings.narrow && ipadSettings.detail}')
    code = replace(code, "inert: embedded && !leftRailOpen ? '' : undefined", "inert: ipadSettings.narrow && ipadSettings.detail ? '' : undefined")
    code = replace(code, '        <main className="settings-content" tabIndex={-1}>', '        <main className="settings-content" tabIndex={-1} aria-hidden={ipadSettings.narrow && !ipadSettings.detail} {...{ inert: ipadSettings.narrow && !ipadSettings.detail ? \'\' : undefined }}>')
    code = replace(code, 'setActiveCategory(category.id);', 'ipadSettings.showCategory(); setActiveCategory(category.id);', 2)
    code = replace(code, '          searchInputRef.current?.focus();', '          ipadSettings.showList();\n          requestAnimationFrame(() => searchInputRef.current?.focus());')
    code = replace(code, '    if (destination === "settings-university" || destination === "settings-ai") {', '    if (destination === "settings-university" || destination === "settings-ai") {\n      ipadSettings.showCategory();')
  }
  if (id.endsWith('/features/settings/catalog/CatalogPanel.tsx') || id.endsWith('/features/settings/PacksPanel.tsx')) {
    code = `import { focusableElements, useFocusTrap } from ${JSON.stringify(focusTrap)}\n` + code
    const catalog = id.endsWith('/catalog/CatalogPanel.tsx')
    if (!catalog) code = replace(code, 'useEffect, useMemo, useState, useSyncExternalStore', 'useEffect, useMemo, useRef, useState, useSyncExternalStore')
    code = replace(code, '  const [saving, setSaving] = useState(false)', `  const [saving, setSaving] = useState(false)
  const ipadPackDialog = useRef<HTMLElement>(null)
  // Keep Escape owned by this dialog even while its import cannot be cancelled.
  useFocusTrap(ipadPackDialog, { active: true, onEscape: () => { if (!saving) onClose() } })`)
    const escapeHandler = catalog ? 'closeOnEscape' : 'onKeyDown'
    code = replace(code, `  useEffect(() => {
    const ${escapeHandler} = (event: KeyboardEvent): void => {
      if (event.key === 'Escape' && !saving) onClose()
    }
    window.addEventListener('keydown', ${escapeHandler})
    return () => window.removeEventListener('keydown', ${escapeHandler})
  }, [onClose, saving])\n\n`, '')
    // WebKit may skip buttons during native Tab traversal, so cycle the shared
    // focusable inventory inside this dialog before the outer settings handler.
    code = replace(code, 'className="settings-pack-dialog"', `ref={ipadPackDialog} className="settings-pack-dialog" onKeyDown={event => {
          if (event.key !== 'Tab' || event.defaultPrevented) return
          const targets = focusableElements(event.currentTarget)
          if (!targets.length) return
          event.preventDefault()
          const index = targets.indexOf(document.activeElement as HTMLElement)
          const next = index < 0 ? (event.shiftKey ? targets.length - 1 : 0) : (index + (event.shiftKey ? -1 : 1) + targets.length) % targets.length
          targets[next]?.focus({ preventScroll: true })
        }}`)
  }
  if (id.endsWith('/features/board/TaskEditorPopover.tsx') || id.endsWith('/features/board/BoardPanel.tsx')) {
    imports('isIpadSettingsForeground')
    code = replace(code, '    const closeOnPointerDown = (event: PointerEvent): void => {', '    const closeOnPointerDown = (event: PointerEvent): void => {\n      if (isIpadSettingsForeground()) return')
    const escapeType = id.endsWith('/BoardPanel.tsx') ? 'globalThis.KeyboardEvent' : 'KeyboardEvent'
    code = replace(code, `    const closeOnEscape = (event: ${escapeType}): void => {`, `    const closeOnEscape = (event: ${escapeType}): void => {\n      if (isIpadSettingsForeground(event)) return`)
    if (id.endsWith('/TaskEditorPopover.tsx')) {
      code = replace(code, '  const popoverRef = useRef<HTMLDivElement>(null)', '  const popoverRef = useRef<HTMLDivElement>(null)\n  const ipadInitialFocus = useRef(false)')
      code = replace(code, "      popoverRef.current?.querySelector<HTMLInputElement>('#board-task-title')?.focus()", "      if (ipadInitialFocus.current) return\n      ipadInitialFocus.current = true\n      if (!isIpadSettingsForeground()) popoverRef.current?.querySelector<HTMLInputElement>('#board-task-title')?.focus()")
    }
  }
  if (id.endsWith('/features/assistantPanel/TabAssistantPanel.tsx')) {
    imports('useIpadAssistant, activateIpadAuxiliary, isIpadAssistantVisible')
    code = replace(code, 'const show = useCallback(() => { setInitialized(true);', "const show = useCallback(() => { activateIpadAuxiliary('assistant'); setInitialized(true);")
    code = replace(code, 'state.open ? close() : show()', 'state.open && isIpadAssistantVisible(props.api.id) ? close() : show()')
    code = replace(code, 'useState(() => normalizeAssistantPanel(props.params.assistant))', 'useState(() => ({ ...normalizeAssistantPanel(props.params.assistant), open: false }))')
    code = replace(code, '    if (isChat) return', '    const ipadAssistant = useIpadAssistant({ panelId: props.api.id, active, open: !isChat && state.open, width: state.width, availableWidth, close, root })\n    if (isChat) return')
    code = replace(code, '    const overlay = availableWidth < state.width + 360', '    const overlay = ipadAssistant.overlay')
    code = replace(code, '        <div className="tab-document">', '        <div className="tab-document" {...{ inert: overlay && state.open && ipadAssistant.visible ? \'\' : undefined }}>')
    code = replace(code, '        {initialized && <aside', '        {state.open && ipadAssistant.visible && overlay && <button type="button" className="ipad-assistant-backdrop" aria-label="AI 닫기" onClick={close} />}\n        {initialized && <aside')
    code = replace(code, 'hidden={!state.open}', 'hidden={!state.open || !ipadAssistant.visible}')
    code = replace(code, 'data-assistant-open={state.open}', 'data-assistant-open={state.open && ipadAssistant.visible}')
    code = replace(code, 'role={overlay ? \'dialog\' : \'complementary\'} aria-label="탭 보조 사이드바"', 'role={overlay ? \'dialog\' : \'complementary\'} aria-modal={overlay || undefined} aria-label="탭 보조 사이드바"')
    code = replace(code, '            <div className="tab-assistant-header-actions">', '            <div className="tab-assistant-header-actions">\n              {ipadAssistant.canPin && <button type="button" className="ipad-assistant-pin" aria-label={ipadAssistant.automatic ? "AI 고정 해제" : "AI 고정"} aria-pressed={ipadAssistant.automatic} onClick={ipadAssistant.togglePin}>{ipadAssistant.automatic ? "고정 해제" : "고정"}</button>}')
    const start = code.indexOf("          {descriptor?.kind !== 'browser' && <div className=\"tab-assistant-launchbar\">")
    const end = code.indexOf('\n', start)
    if (start < 0 || end < 0) throw new Error('iPad duplicate document heading anchor changed')
    code = code.slice(0, start) + code.slice(end)
  }
  if (id.endsWith('/features/workspace/WorkspaceHost.tsx')) {
    imports('IpadAssistantAction, bindIpadWorkspace, useIpadRailVisible')
    code = replace(code, 'const rightRailOpen = useUiStore((state) => state.rightRailOpen)', "const rightRailOpen = useIpadRailVisible('materials')")
    code = replace(code, 'const rightRailOpen = useUiStore(state => state.rightRailOpen)', "const rightRailOpen = useIpadRailVisible('materials')")
    code = replace(code, '    {corner && <ToggleRightRail />}', '    <IpadAssistantAction activate={() => props.api.setActive()} panelId={props.group.activePanel?.id} />\n    {corner && <ToggleRightRail />}')
    code = replace(code, '    layoutSubscription.current = { dispose: () => { layout.dispose(); overlay.dispose(); drop.dispose() } }', '    const stopIpadLayout = bindIpadWorkspace(event.api, rootRef.current)\n    layoutSubscription.current = { dispose: () => { stopIpadLayout(); layout.dispose(); overlay.dispose(); drop.dispose() } }')
  }
  if (id.endsWith('/features/workspace/NewTabMenu.tsx')) {
    code = replace(code, '      className="new-tab-menu"', '      className="new-tab-menu" data-bandal-native-overlay="true"')
    // These are commands, not selection options. Expose their actual button
    // role and command label to VoiceOver and native accessibility clients.
    code = replace(code, 'role="listbox"', 'role="group"')
    code = replace(code, 'role="option"', 'role="button"', 2)
    code = replace(code, 'aria-selected={index === clampedHighlight}', 'aria-label={item.label}')
    code = replace(code, 'aria-selected={items.length === clampedHighlight}', 'aria-label={linkItem.label}')
  }
  if (id.endsWith('/features/workspace/OpenTabsMenu.tsx')) {
    code = replace(code, 'className="workspace-open-tabs-menu"', 'className="workspace-open-tabs-menu" data-bandal-native-overlay="true"')
    code = replace(code, '  const panels = props.group.panels', '  const panels = props.containerApi.hasMaximizedGroup() ? props.containerApi.panels : props.group.panels')
    code = replace(code, '      layoutAdaptiveTabs(props.group.element)', '      layoutAdaptiveTabs(panel.group.element)')
    code = replace(code, "      props.group.element.querySelector<HTMLElement>('.dv-tab.dv-active-tab')?.focus()", "      panel.group.element.querySelector<HTMLElement>('.dv-tab.dv-active-tab')?.focus()")
  }
  if (id.endsWith('/features/workspace/adaptiveTabs.ts')) {
    code = replace(code, "available < 32)", "available < 44)")
    code = replace(code, '  const capacity = Math.min(count, Math.max(1, Math.floor(available / 32)))', '  const capacity = available < 480 ? 1 : Math.min(count, Math.max(1, Math.floor(available / 120)))')
  }
  if (id.endsWith('/features/materials/MaterialsContextMenu.tsx')) {
    code = replace(code, "if (event.key === 'Escape') onClose()", "if (event.key === 'Escape' && !event.defaultPrevented) { event.preventDefault(); event.stopPropagation(); onClose() }")
    code = replace(code, "window.addEventListener('keydown', dismissOnEscape)", "window.addEventListener('keydown', dismissOnEscape, true)")
    code = replace(code, "window.removeEventListener('keydown', dismissOnEscape)", "window.removeEventListener('keydown', dismissOnEscape, true)")
  }
  if (id.endsWith('/features/materials/MaterialTree.tsx')) {
    imports('IpadRowActions')
    code = replace(code, '<MaterialRowAffordance target={{ courseId, node }}>', '<IpadRowActions label={node.name}><MaterialRowAffordance target={{ courseId, node }}>', 2)
    code = replace(code, '</MaterialRowAffordance>', '</MaterialRowAffordance></IpadRowActions>', 2)
  }
  return code === source ? null : { code, map: null }
}
export default function ipadLayoutPlugin() { return { name: 'bandal-ipad-layout', enforce: 'pre', transform: adaptLayoutSource } }
