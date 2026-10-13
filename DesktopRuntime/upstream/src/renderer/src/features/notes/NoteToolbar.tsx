import { editorViewCtx, type Editor } from '@milkdown/core'
import { PluginMenuItems } from '../plugins/PluginMenuItems'
import {
  createCodeBlockCommand,
  insertHrCommand,
  toggleEmphasisCommand,
  toggleInlineCodeCommand,
  toggleLinkCommand,
  toggleStrongCommand,
  turnIntoTextCommand,
  updateCodeBlockLanguageCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInHeadingCommand,
  wrapInOrderedListCommand
} from '@milkdown/preset-commonmark'
import {
  insertTableCommand,
  toggleStrikethroughCommand
} from '@milkdown/preset-gfm'
import { useInstance } from '@milkdown/react'
import {
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type ChangeEvent,
  type FormEvent,
  type MouseEvent as ReactMouseEvent
} from 'react'
import { callCommand } from '@milkdown/utils'
import { showToast } from '../../app/toast'
import { useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { insertNoteImageFiles } from './noteImagePlugin'
import { openMaterialLink } from './materialLinkNavigation'
import type { NoteFormatState } from './noteFormatting'
import { toggleTaskListItems } from './noteFormatting'
import {
  NOTE_FONT_SCALES,
  type NoteFontScale
} from './noteZoom'
import {
  NOTE_SLASH_TOOLBAR_ACTION_EVENT,
  type NoteSlashToolbarAction
} from './slashMenuPlugin'

interface FormatButtonProps {
  active: boolean
  disabled?: boolean
  label: string
  text: string
  onClick: () => void
  className?: string | undefined
}

function keepEditorFocused(event: ReactMouseEvent<HTMLButtonElement>): void {
  event.preventDefault()
}

function FormatButton({
  active,
  disabled = false,
  label,
  text,
  onClick,
  className = ''
}: FormatButtonProps): JSX.Element {
  return (
    <button
      type="button"
      className={`note-format-button ${className}`.trim()}
      aria-label={label}
      aria-pressed={active}
      title={label}
      disabled={disabled}
      onMouseDown={keepEditorFocused}
      onClick={onClick}
    >
      {text}
    </button>
  )
}

export interface NoteToolbarProps {
  courseId: string
  relPath: string
  formatState: NoteFormatState
  fontScale: NoteFontScale
  onFontScaleChange: (scale: NoteFontScale) => void
}

export function NoteToolbar({
  courseId,
  relPath,
  formatState,
  fontScale,
  onFontScaleChange
}: NoteToolbarProps): JSX.Element {
  const [loading, getEditor] = useInstance()
  const t = useT()
  const [moreOpen, setMoreOpen] = useState(false)
  const [linkOpen, setLinkOpen] = useState(false)
  const [linkHref, setLinkHref] = useState('https://')
  const linkInputId = useId()
  const moreRef = useRef<HTMLDivElement>(null)
  const linkRef = useRef<HTMLDivElement>(null)
  const linkPopoverRef = useRef<HTMLFormElement>(null)
  const imageInputRef = useRef<HTMLInputElement>(null)

  const run = useCallback(
    (action: (editor: Editor) => unknown, actionName: string): void => {
      const editor = getEditor()
      if (editor === undefined) {
        console.error(
          '[Bandal] Note toolbar action skipped because the editor is unavailable.',
          { action: actionName }
        )
        showToast(t('notes.editor.unavailable'), 'danger')
        return
      }
      const handled = action(editor)
      if (handled === false) {
        console.warn('[Bandal] Note toolbar command returned false.', {
          action: actionName
        })
      }
      editor.action((context) => context.get(editorViewCtx).focus())
    },
    [getEditor, t]
  )

  useEffect(() => {
    if (!moreOpen && !linkOpen) return
    const closeOutside = (event: MouseEvent): void => {
      if (
        event.target instanceof Node &&
        (moreRef.current?.contains(event.target) === true ||
          linkRef.current?.contains(event.target) === true ||
          linkPopoverRef.current?.contains(event.target) === true)
      ) {
        return
      }
      setMoreOpen(false)
      setLinkOpen(false)
    }
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      setMoreOpen(false)
      setLinkOpen(false)
    }
    document.addEventListener('mousedown', closeOutside)
    document.addEventListener('keydown', closeOnEscape)
    return () => {
      document.removeEventListener('mousedown', closeOutside)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [linkOpen, moreOpen])

  useEffect(() => {
    if (loading) return
    const editor = getEditor()
    if (editor === undefined) {
      console.error(
        '[Bandal] Note slash toolbar bridge was not attached because the editor is unavailable.'
      )
      return
    }

    let editorDom: HTMLElement | undefined
    const handleSlashAction = (event: Event): void => {
      if (!(event instanceof CustomEvent)) return
      const action = event.detail as NoteSlashToolbarAction
      if (action === 'link') {
        setMoreOpen(false)
        setLinkHref('https://')
        setLinkOpen(true)
      } else if (action === 'image') {
        imageInputRef.current?.click()
      } else if (action === 'page') {
        const slashEditor = editor
        void (async () => {
          try {
            const slash = relPath.lastIndexOf('/')
            const dirRelPath = slash === -1 ? '' : relPath.slice(0, slash)
            const created = await invoke('notes:create', {
              courseId,
              dirRelPath,
              title: '새 페이지'
            })
            slashEditor.action((context) => {
              const view = context.get(editorViewCtx)
              const wikilink = view.state.schema.nodes['wikilink']
              if (wikilink === undefined) return
              const fileName = created.relPath.split('/').at(-1) ?? created.relPath
              const target = fileName.replace(/\.(?:md|markdown)$/iu, '')
              const node = wikilink.create({
                target,
                heading: null,
                alias: null,
                embed: false
              })
              view.dispatch(view.state.tr.replaceSelectionWith(node).scrollIntoView())
            })
            openMaterialLink(courseId, { relPath: created.relPath, page: null })
          } catch (error) {
            console.error('[Bandal] 새 페이지를 만들지 못했습니다.', error)
            showToast('새 페이지를 만들지 못했습니다.', 'danger')
          }
        })()
      }
    }
    editor.action((context) => {
      editorDom = context.get(editorViewCtx).dom
      editorDom.addEventListener(
        NOTE_SLASH_TOOLBAR_ACTION_EVENT,
        handleSlashAction
      )
    })
    return () => {
      editorDom?.removeEventListener(
        NOTE_SLASH_TOOLBAR_ACTION_EVENT,
        handleSlashAction
      )
    }
  }, [courseId, getEditor, loading, relPath])

  const toggleTaskList = (): void => {
    run(
      (editor) =>
        editor.action((context) => {
          const view = context.get(editorViewCtx)
          if (toggleTaskListItems(view)) return true
          if (!callCommand(wrapInBulletListCommand.key)(context)) return false
          return toggleTaskListItems(context.get(editorViewCtx))
        }),
      'task-list'
    )
  }

  const toggleLink = (): void => {
    if (formatState.link) {
      run(
        (editor) => editor.action(callCommand(toggleLinkCommand.key)),
        'toggle-link'
      )
      setLinkOpen(false)
      return
    }
    setMoreOpen(false)
    setLinkHref(formatState.linkHref ?? 'https://')
    setLinkOpen((open) => !open)
  }

  const confirmLink = (event: FormEvent<HTMLFormElement>): void => {
    event.preventDefault()
    const href = linkHref.trim()
    if (href.length === 0) return
    run(
      (editor) => editor.action(callCommand(toggleLinkCommand.key, { href })),
      'set-link'
    )
    setLinkOpen(false)
  }

  const chooseImage = (): void => {
    imageInputRef.current?.click()
  }

  const insertSelectedImages = (event: ChangeEvent<HTMLInputElement>): void => {
    const files = [...(event.currentTarget.files ?? [])]
    event.currentTarget.value = ''
    if (files.length === 0) return
    run(
      (editor) =>
        editor.action((context) => {
          void insertNoteImageFiles(
            context.get(editorViewCtx),
            courseId,
            files
          )
        }),
      'insert-image'
    )
  }

  const updateCodeLanguage = (language: string): void => {
    if (formatState.codeBlockPosition === null) return
    run(
      (editor) =>
        editor.action(
          callCommand(updateCodeBlockLanguageCommand.key, {
            pos: formatState.codeBlockPosition,
            language
          })
        ),
      'update-code-block-language'
    )
  }

  const commandButton = (
    label: string,
    text: string,
    active: boolean,
    action: (editor: Editor) => unknown,
    className?: string
  ): JSX.Element => (
    <FormatButton
      key={label}
      active={active}
      label={label}
      text={text}
      disabled={loading}
      className={className}
      onClick={() => run(action, label)}
    />
  )

  return (
    <div className="note-format-bar" role="toolbar" aria-label="마크다운 서식">
      <div className="note-format-bar__scroll">
        <div className="note-format-group">
          {commandButton('본문', '¶', formatState.paragraph, (editor) =>
            editor.action(callCommand(turnIntoTextCommand.key))
          )}
        </div>
        <div className="note-format-group">
          {[1, 2, 3].map((level) =>
            commandButton(
              `제목 ${level}`,
              `H${level}`,
              formatState.headingLevel === level,
              (editor) =>
                editor.action(callCommand(wrapInHeadingCommand.key, level))
            )
          )}
        </div>
        <div className="note-format-group">
          {commandButton(
            '굵게',
            'B',
            formatState.strong,
            (editor) => editor.action(callCommand(toggleStrongCommand.key)),
            'note-format-button--strong'
          )}
          {commandButton(
            '기울임',
            'I',
            formatState.emphasis,
            (editor) => editor.action(callCommand(toggleEmphasisCommand.key)),
            'note-format-button--emphasis'
          )}
          {commandButton(
            '취소선',
            'S',
            formatState.strikethrough,
            (editor) =>
              editor.action(callCommand(toggleStrikethroughCommand.key)),
            'note-format-button--strike'
          )}
        </div>
        <div className="note-format-group">
          {commandButton('글머리 목록', '•≡', formatState.bulletList, (editor) =>
            editor.action(callCommand(wrapInBulletListCommand.key))
          )}
          {commandButton('번호 목록', '1.', formatState.orderedList, (editor) =>
            editor.action(callCommand(wrapInOrderedListCommand.key))
          )}
          <FormatButton
            active={formatState.taskList}
            label="할 일 목록"
            text="☑"
            disabled={loading}
            onClick={toggleTaskList}
          />
        </div>
        <div className="note-format-group note-format-group--overflowable">
          {commandButton('인용', '❝', formatState.blockquote, (editor) =>
            editor.action(callCommand(wrapInBlockquoteCommand.key))
          )}
          <div className="note-format-link" ref={linkRef}>
            <FormatButton
              active={formatState.link || linkOpen}
              label={formatState.link ? '링크 해제' : '링크'}
              text="↗"
              disabled={loading}
              onClick={toggleLink}
            />
          </div>
          <FormatButton
            active={false}
            label="이미지"
            text="▧"
            disabled={loading}
            onClick={chooseImage}
          />
          <input
            ref={imageInputRef}
            type="file"
            accept="image/*,.avif,.bmp,.gif,.jpeg,.jpg,.png,.svg,.webp"
            multiple
            hidden
            onChange={insertSelectedImages}
          />
          {commandButton(
            '인라인 코드',
            '<>',
            formatState.inlineCode,
            (editor) =>
              editor.action(callCommand(toggleInlineCodeCommand.key)),
            'note-format-button--code'
          )}
          {commandButton(
            '코드 블록',
            '{}',
            formatState.codeBlockPosition !== null,
            (editor) =>
              editor.action(callCommand(createCodeBlockCommand.key)),
            'note-format-button--code'
          )}
        </div>
      </div>

      {linkOpen && (
        <form
          ref={linkPopoverRef}
          className="note-link-popover"
          onSubmit={confirmLink}
        >
          <label htmlFor={linkInputId}>링크 주소</label>
          <div className="note-link-popover__row">
            <input
              id={linkInputId}
              type="url"
              inputMode="url"
              autoFocus
              value={linkHref}
              placeholder="주소 입력"
              onChange={(event) => setLinkHref(event.target.value)}
            />
            <button type="submit" disabled={linkHref.trim().length === 0}>
              확인
            </button>
          </div>
        </form>
      )}

      <div className="note-format-more" ref={moreRef}>
        <FormatButton
          active={moreOpen}
          label="더 많은 서식"
          text="…"
          disabled={loading}
          onClick={() => setMoreOpen((open) => !open)}
        />
        {moreOpen && (
          <div className="note-format-more__menu" role="menu">
            <button
              type="button"
              className="note-format-menu-button note-format-menu-button--compact"
              role="menuitemcheckbox"
              aria-checked={formatState.blockquote}
              onMouseDown={keepEditorFocused}
              onClick={() => {
                run(
                  (editor) =>
                    editor.action(callCommand(wrapInBlockquoteCommand.key)),
                  'blockquote'
                )
                setMoreOpen(false)
              }}
            >
              인용
            </button>
            <button
              type="button"
              className="note-format-menu-button note-format-menu-button--compact"
              role="menuitemcheckbox"
              aria-checked={formatState.link}
              onMouseDown={keepEditorFocused}
              onClick={toggleLink}
            >
              {formatState.link ? '링크 해제' : '링크'}
            </button>
            <button
              type="button"
              className="note-format-menu-button note-format-menu-button--compact"
              role="menuitem"
              onMouseDown={keepEditorFocused}
              onClick={() => {
                chooseImage()
                setMoreOpen(false)
              }}
            >
              이미지
            </button>
            <button
              type="button"
              className="note-format-menu-button note-format-menu-button--compact"
              role="menuitemcheckbox"
              aria-checked={formatState.inlineCode}
              onMouseDown={keepEditorFocused}
              onClick={() => {
                run(
                  (editor) =>
                    editor.action(callCommand(toggleInlineCodeCommand.key)),
                  'inline-code'
                )
                setMoreOpen(false)
              }}
            >
              인라인 코드
            </button>
            <button
              type="button"
              className="note-format-menu-button note-format-menu-button--compact"
              role="menuitemcheckbox"
              aria-checked={formatState.codeBlockPosition !== null}
              onMouseDown={keepEditorFocused}
              onClick={() => {
                run(
                  (editor) =>
                    editor.action(callCommand(createCodeBlockCommand.key)),
                  'code-block'
                )
                setMoreOpen(false)
              }}
            >
              코드 블록
            </button>
            <button
              type="button"
              className="note-format-menu-button"
              role="menuitem"
              onMouseDown={keepEditorFocused}
              onClick={() => {
                run(
                  (editor) => editor.action(callCommand(insertHrCommand.key)),
                  'horizontal-rule'
                )
                setMoreOpen(false)
              }}
            >
              구분선
            </button>
            <button
              type="button"
              className="note-format-menu-button"
              role="menuitem"
              onMouseDown={keepEditorFocused}
              onClick={() => {
                run(
                  (editor) =>
                    editor.action(
                      callCommand(insertTableCommand.key, { row: 3, col: 3 })
                    ),
                  'table'
                )
                setMoreOpen(false)
              }}
            >
              표 삽입
            </button>

            <label className="note-format-menu-field">
              <span>코드 블록 언어</span>
              <select
                disabled={formatState.codeBlockPosition === null}
                value={
                  formatState.codeBlockPosition === null
                    ? '__none__'
                    : formatState.codeBlockLanguage
                }
                onChange={(event) => updateCodeLanguage(event.target.value)}
              >
                <option value="__none__" disabled>
                  코드 블록 안에서 선택
                </option>
                <option value="">언어 없음</option>
                <option value="typescript">TypeScript</option>
                <option value="javascript">JavaScript</option>
                <option value="python">Python</option>
                <option value="bash">Bash</option>
                <option value="json">JSON</option>
              </select>
            </label>

            <PluginMenuItems location="editor" courseId={courseId} relPath={relPath} onClose={() => setMoreOpen(false)} />
            <fieldset className="note-format-scale">
              <legend>에디터 글자 크기</legend>
              <div className="note-format-scale__options">
                {NOTE_FONT_SCALES.map((scale) => (
                  <button
                    type="button"
                    className="note-format-scale__option"
                    data-active={scale === fontScale}
                    aria-pressed={scale === fontScale}
                    key={scale}
                    onMouseDown={keepEditorFocused}
                    onClick={() => onFontScaleChange(scale)}
                  >
                    {Math.round(scale * 100)}%
                  </button>
                ))}
              </div>
              <span className="note-format-scale__hint">⌘+ / ⌘−</span>
            </fieldset>
          </div>
        )}
      </div>
    </div>
  )
}
