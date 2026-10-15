import { fileURLToPath } from 'node:url'

const popover = fileURLToPath(new URL('./IpadComposerPopover.tsx', import.meta.url))
const contextSummary = fileURLToPath(new URL('./IpadChatContextSummary.tsx', import.meta.url))

/** Keep the byte-preserved desktop source and fail when its public contract moves. */
export function adaptSettingsChatSource(source, id) {
  if (id.endsWith('/features/chat/ChatSurface.tsx')) {
    const anchor = '      {state.notice !== null && ('
    if (source.split(anchor).length !== 2) throw new Error('iPad chat context summary anchor changed')
    return { code: `import { IpadChatContextSummary } from ${JSON.stringify(contextSummary)}\n` + source.replace(anchor, '      <IpadChatContextSummary courseId={courseId} conversationId={conversationKey} sourcePanelId={sourcePanelId} />\n' + anchor), map: null }
  }
  if (id.endsWith('/features/chat/Composer.tsx')) {
    const anchor = '    useLayoutEffect(resize, [resize, value])'
    if (source.split(anchor).length !== 2) throw new Error('iPad composer resize anchor changed')
    return { code: source.replace(anchor, `${anchor}
    // Text must reflow when an iPad panel/keyboard changes the writing width.
    useLayoutEffect(() => {
      const input = textareaRef.current
      if (!input) return
      let width = -1
      let frame = 0
      const observer = new ResizeObserver(entries => {
        const next = entries[0]?.contentRect.width ?? input.clientWidth
        if (Math.abs(next - width) < 0.5) return
        width = next
        cancelAnimationFrame(frame)
        frame = requestAnimationFrame(resize)
      })
      observer.observe(input)
      return () => { observer.disconnect(); cancelAnimationFrame(frame) }
    }, [resize])`), map: null }
  }
  if (!id.endsWith('/features/chat/ComposerPopover.tsx')) return null
  for (const anchor of ['export function ComposerPopover(', 'anchor: RefObject<HTMLElement>; label: string; onClose: () => void; children: ReactNode', 'return createPortal(']) {
    if (source.split(anchor).length !== 2) throw new Error(`iPad composer popover anchor changed: ${anchor}`)
  }
  return { code: `export { IpadComposerPopover as ComposerPopover } from ${JSON.stringify(popover)}\n`, map: null }
}

export default function ipadSettingsChatPlugin() {
  return { name: 'bandal-ipad-settings-chat-ui', enforce: 'pre', transform: adaptSettingsChatSource }
}
