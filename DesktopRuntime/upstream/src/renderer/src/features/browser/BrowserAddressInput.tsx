import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { BrowserIcon } from './browserIcons'
import { addressDisplayParts, resolveAddressInput, type AddressSuggestion } from './urlInput'
import { searchEngine, useAddressSuggestions } from './useAddressSuggestions'

const SOURCE_LABELS: Record<AddressSuggestion['kind'], string> = {
  url: '이동', search: '검색', history: '방문 기록', favorite: '즐겨찾기', tab: '열린 탭'
}

export function BrowserAddressInput({ value, onNavigate, focusSeq, favicon, isPrivate, profileId, courseId }: {
  value: string
  onNavigate: (url: string) => void
  focusSeq: number
  favicon: string | undefined
  profileId?: string
  courseId?: string | null
  isPrivate: boolean
}): JSX.Element {
  const [draft, setDraft] = useState<string | null>(null)
  const [focused, setFocused] = useState(false)
  const [edited, setEdited] = useState(false)
  // Keep the selected URL stable when a pending history query adds more rows.
  const [selectedUrl, setSelectedUrl] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const formRef = useRef<HTMLFormElement>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const composing = useRef(false)
  const listId = useId()
  const suggestions = useAddressSuggestions(focused ? (edited ? draft : '') : null, !isPrivate, profileId, courseId)
  const open = focused && suggestions.length > 0
  const highlighted = selectedUrl === null
    ? (edited && draft?.trim() ? 0 : -1)
    : suggestions.findIndex((item) => item.url === selectedUrl)
  const parts = addressDisplayParts(value)

  useEffect(() => {
    if (focusSeq === 0) return
    inputRef.current?.focus()
    inputRef.current?.select()
  }, [focusSeq])

  useLayoutEffect(() => {
    if (!open) return
    const form = formRef.current
    const list = listRef.current
    if (!form || !list) return
    const place = (): void => {
      const rect = form.getBoundingClientRect()
      const below = window.innerHeight - rect.bottom - 12
      const above = rect.top - 12
      const flipped = below < 180 && above > below
      const width = Math.min(Math.max(rect.width, 320), window.innerWidth - 16)
      Object.assign(list.style, {
        width: `${width}px`,
        left: `${Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))}px`,
        top: flipped ? 'auto' : `${rect.bottom + 4}px`,
        bottom: flipped ? `${window.innerHeight - rect.top + 4}px` : 'auto',
        maxHeight: `${Math.max(0, Math.min(480, flipped ? above : below))}px`
      })
    }
    place()
    const observer = new ResizeObserver(place)
    observer.observe(form)
    window.addEventListener('resize', place)
    window.addEventListener('scroll', place, true)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', place)
      window.removeEventListener('scroll', place, true)
    }
  }, [open])

  useEffect(() => {
    if (!open || highlighted < 0) return
    document.getElementById(`${listId}-${highlighted}`)?.scrollIntoView({ block: 'nearest' })
  }, [open, highlighted, listId])

  const dismiss = (): void => {
    composing.current = false
    setFocused(false)
    setDraft(null)
    setSelectedUrl(null)
    setEdited(false)
  }

  useEffect(() => {
    if (!focused) return
    const outside = (event: PointerEvent): void => {
      if (event.target instanceof Node &&
          (formRef.current?.contains(event.target) || listRef.current?.contains(event.target))) return
      inputRef.current?.blur()
      dismiss()
    }
    const blur = (): void => { inputRef.current?.blur(); dismiss() }
    window.addEventListener('pointerdown', outside, true)
    window.addEventListener('blur', blur)
    return () => {
      window.removeEventListener('pointerdown', outside, true)
      window.removeEventListener('blur', blur)
    }
  }, [focused])

  const go = (url: string): void => {
    dismiss()
    inputRef.current?.blur()
    onNavigate(url)
  }
  const submit = (): void => {
    if (composing.current) return
    const picked = open && highlighted >= 0 ? suggestions[highlighted] : undefined
    const url = picked?.url ?? resolveAddressInput(draft ?? value, searchEngine())
    if (url !== null) go(url)
  }

  return (
    <form ref={formRef} className="browser-address" role="search"
      data-display-url={!focused && value.length > 0 ? 'true' : undefined}
      onSubmit={(event) => { event.preventDefault(); submit() }}>
      <span className={`browser-address__security${parts.secure ? '' : ' browser-address__security--insecure'}`}
        title={parts.secure ? '이 연결은 암호화돼 있어요' : '암호화되지 않은 연결이에요. 비밀번호를 입력하지 마세요.'}
        aria-label={parts.secure ? '보안 연결' : '보안되지 않은 연결'}>
        <BrowserIcon name={parts.secure ? 'lock' : 'insecure'} />
      </span>
      {favicon !== undefined && <img className="browser-address__favicon" src={favicon} alt="" />}
      <span className="browser-address__field">
        <input ref={inputRef} type="text" spellCheck={false} autoComplete="off" autoCapitalize="off"
          aria-label="주소 또는 검색어" placeholder="검색어 또는 주소를 입력하세요"
          value={draft ?? value}
          onChange={(event) => {
            setDraft(event.target.value)
            setEdited(true)
            setSelectedUrl(null)
          }}
          onFocus={(event) => {
            setDraft(value)
            setFocused(true)
            setEdited(false)
            setSelectedUrl(null)
            event.currentTarget.select()
          }}
          onBlur={dismiss}
          onCompositionStart={() => { composing.current = true }}
          onCompositionEnd={() => { composing.current = false }}
          role="combobox" aria-expanded={open} aria-controls={open ? listId : undefined}
          aria-activedescendant={open && highlighted >= 0 ? `${listId}-${highlighted}` : undefined}
          aria-autocomplete="list"
          onKeyDown={(event) => {
            if (event.key === 'Enter') {
              event.preventDefault()
              if (!event.nativeEvent.isComposing && event.nativeEvent.keyCode !== 229) submit()
              return
            }
            if (event.nativeEvent.isComposing || composing.current) return
            if (event.key === 'Escape') {
              event.preventDefault()
              event.stopPropagation()
              event.currentTarget.blur()
              dismiss()
              return
            }
            if (open && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
              event.preventDefault()
              const next = event.key === 'ArrowDown'
                ? (highlighted + 1) % suggestions.length
                : (highlighted <= 0 ? suggestions.length - 1 : highlighted - 1)
              setSelectedUrl(suggestions[next]!.url)
            }
          }} />
        {!focused && value.length > 0 && (
          <span className="browser-address__display" aria-hidden="true">
            <span>{parts.prefix}</span><strong>{parts.domain}</strong>
          </span>
        )}
      </span>
      {open && createPortal(
        <div ref={listRef} id={listId} className="browser-suggestions" role="listbox" aria-label="주소 및 검색 제안">
          {suggestions.map((suggestion, index) => {
            const isAction = suggestion.kind === 'search' || suggestion.kind === 'url'
            const firstShortcut = !isAction && (index === 0 || ['search', 'url'].includes(suggestions[index - 1]!.kind))
            const detail = isAction ? suggestion.detail : addressDisplayParts(suggestion.url)
            return (
              <div key={suggestion.url} role="presentation">
                {firstShortcut && <div className="browser-suggestions__heading" role="presentation">바로가기</div>}
                <button type="button" role="option" tabIndex={-1} id={`${listId}-${index}`}
                  aria-selected={index === highlighted} data-kind={suggestion.kind}
                  data-highlighted={index === highlighted ? 'true' : undefined}
                  className="browser-suggestion"
                  onMouseEnter={() => setSelectedUrl(suggestion.url)}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => go(suggestion.url)}>
                  <span className="browser-suggestion__text">
                    <span className="browser-suggestion__label">{suggestion.label}</span>
                    <span className="browser-suggestion__detail">{typeof detail === 'string'
                      ? detail : `${detail.prefix}${detail.domain}${detail.suffix}`}</span>
                  </span>
                  <span className="browser-suggestion__source">{SOURCE_LABELS[suggestion.kind]}</span>
                </button>
              </div>
            )
          })}
        </div>, document.body
      )}
    </form>
  )
}
