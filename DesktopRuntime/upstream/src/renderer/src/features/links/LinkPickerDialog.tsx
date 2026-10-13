import { useEffect, useMemo, useRef, useState } from 'react'
import { materialKindForPath } from '../../../../shared/materialKind'
import type { TabDescriptor } from '../../../../shared/tabs'
import type {
  MaterialKind,
  MaterialNode
} from '../../../../shared/types/materials'
import { Icon, type IconName } from '../../app/icons'
import { showToast } from '../../app/toast'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useT } from '../../i18n'
import { invoke, onPush } from '../../lib/ipc'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { requestMaterialConnectionsRefresh } from './useMaterialConnections'
import './links.css'

const KIND_ICONS: Record<MaterialKind, IconName> = {
  pdf: 'filePdf',
  note: 'fileText',
  image: 'fileImage',
  video: 'file',
  other: 'file'
}

export interface LinkPickerFile {
  relPath: string
  name: string
  kind: MaterialKind
}

export interface LinkPickerDialogProps {
  courseId: string
  sourceRelPath: string
  onClose: () => void
}

export function flattenMaterialFiles(
  nodes: readonly MaterialNode[]
): LinkPickerFile[] {
  const files: LinkPickerFile[] = []
  for (const node of nodes) {
    if (node.kind === 'dir') {
      files.push(...flattenMaterialFiles(node.children ?? []))
    } else {
      files.push({ relPath: node.relPath, name: node.name, kind: node.kind })
    }
  }
  return files
}

export function filterLinkPickerFiles(
  files: readonly LinkPickerFile[],
  sourceRelPath: string,
  query: string
): LinkPickerFile[] {
  const normalized = query.trim().toLocaleLowerCase()
  return files.filter((file) => {
    if (file.relPath === sourceRelPath) return false
    if (normalized.length === 0) return true
    return (
      file.name.toLocaleLowerCase().includes(normalized) ||
      file.relPath.toLocaleLowerCase().includes(normalized)
    )
  })
}

/** MaterialKind is the source of truth; non-dedicated viewers use FileTab. */
export function materialLinkDescriptor(
  courseId: string,
  relPath: string
): TabDescriptor {
  const kind = materialKindForPath(relPath)
  if (kind === 'pdf' || kind === 'note' || kind === 'image') {
    return { kind, payload: { courseId, relPath } } as TabDescriptor
  }
  return { kind: 'file', payload: { courseId, relPath } }
}

export function LinkPickerDialog({
  courseId,
  sourceRelPath,
  onClose
}: LinkPickerDialogProps): JSX.Element {
  const t = useT()
  const [files, setFiles] = useState<LinkPickerFile[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const [creatingPath, setCreatingPath] = useState<string | null>(null)
  const [highlighted, setHighlighted] = useState(0)
  const dialogRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const creatingRef = useRef(false)

  useFocusTrap(dialogRef, {
    active: true,
    initialFocus: inputRef,
    onEscape: onClose
  })

  useEffect(() => {
    let disposed = false
    let sequence = 0
    const releasePointer = acquirePointerPassthrough()

    const load = async (): Promise<void> => {
      const current = ++sequence
      setLoading(true)
      setError(null)
      setLoadFailed(false)
      try {
        const tree = await invoke('materials:tree', { courseId })
        if (!disposed && current === sequence) {
          setFiles(flattenMaterialFiles(tree))
        }
      } catch (caught) {
        if (!disposed && current === sequence) {
          console.error('[Bandal] 연결할 자료 목록을 불러오지 못했습니다.', caught)
          setFiles([])
          setLoadFailed(true)
          setError(t('links.picker.loadFailed'))
        }
      } finally {
        if (!disposed && current === sequence) setLoading(false)
      }
    }

    void load()
    const stopMaterials = onPush('materials:changed', (payload) => {
      if (payload.courseId === courseId) void load()
    })
    return () => {
      disposed = true
      sequence += 1
      stopMaterials()
      releasePointer()
    }
  }, [courseId, t, reload])

  const filteredFiles = useMemo(
    () => filterLinkPickerFiles(files, sourceRelPath, query),
    [files, query, sourceRelPath]
  )
  const clampedHighlight = Math.min(
    highlighted,
    Math.max(filteredFiles.length - 1, 0)
  )

  const createLink = async (target: LinkPickerFile): Promise<void> => {
    if (creatingRef.current) return
    creatingRef.current = true
    setCreatingPath(target.relPath)
    setError(null)
    try {
      await invoke('links:create', {
        courseId,
        source: materialLinkDescriptor(courseId, sourceRelPath),
        target: materialLinkDescriptor(courseId, target.relPath),
        kind: 'related'
      })
      requestMaterialConnectionsRefresh(courseId)
      showToast(t('links.picker.connected'))
      onClose()
    } catch (caught) {
      console.error('[Bandal] 자료를 연결하지 못했습니다.', caught)
      setError(t('links.picker.createFailed'))
    } finally {
      creatingRef.current = false
      setCreatingPath(null)
    }
  }

  return (
    <div
      className="link-picker-overlay"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div
        ref={dialogRef}
        className="link-picker"
        role="dialog"
        aria-modal="true"
        aria-labelledby="link-picker-title"
      >
        <header className="link-picker__head">
          <h2 id="link-picker-title">{t('links.picker.title')}</h2>
          <button
            type="button"
            className="link-picker__close"
            aria-label={t('links.picker.close')}
            onClick={onClose}
          >
            <Icon name="x" />
          </button>
        </header>
        <div className="link-picker__field">
          <Icon name="search" />
          <input
            ref={inputRef}
            type="search"
            value={query}
            placeholder={t('links.picker.search')}
            aria-label={t('links.picker.search')}
            onChange={(event) => {
              setQuery(event.target.value)
              setHighlighted(0)
            }}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing) return
              if (event.key === 'ArrowDown' && filteredFiles.length > 0) {
                event.preventDefault()
                setHighlighted((index) =>
                  Math.min(index + 1, filteredFiles.length - 1)
                )
              } else if (event.key === 'ArrowUp') {
                event.preventDefault()
                setHighlighted((index) => Math.max(index - 1, 0))
              } else if (event.key === 'Enter') {
                event.preventDefault()
                const selected = filteredFiles[clampedHighlight]
                if (selected !== undefined && creatingPath === null) {
                  void createLink(selected)
                }
              }
            }}
          />
        </div>
        <div className="link-picker__body">
          {error !== null && <p className="link-picker__error" role="alert">{error}</p>}
          {loading ? (
            <p className="link-picker__empty" role="status">
              {t('links.picker.loading')}
            </p>
          ) : loadFailed ? (
            <button type="button" className="secondary-button" onClick={() => setReload(value => value + 1)}>
              {t('help.retry')}
            </button>
          ) : filteredFiles.length === 0 ? (
            <p className="link-picker__empty">
              {query.trim().length === 0
                ? t('links.picker.empty')
                : t('links.picker.noResults')}
            </p>
          ) : (
            <ul className="link-picker__list" aria-label={t('links.picker.list')}>
              {filteredFiles.map((file, index) => (
                <li key={file.relPath}>
                  <button
                    type="button"
                    data-highlighted={index === clampedHighlight}
                    disabled={creatingPath !== null}
                    onMouseEnter={() => setHighlighted(index)}
                    onClick={() => void createLink(file)}
                  >
                    <Icon className="link-picker__kind" name={KIND_ICONS[file.kind]} />
                    <span className="link-picker__description">
                      <span className="link-picker__name">{file.name}</span>
                      <span className="link-picker__path">
                        {creatingPath === file.relPath
                          ? t('links.picker.connecting')
                          : file.relPath}
                      </span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  )
}
