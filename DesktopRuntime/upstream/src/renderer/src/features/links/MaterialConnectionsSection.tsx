import { useCallback, useState } from 'react'
import type { TabDescriptor } from '../../../../shared/tabs'
import type {
  MaterialBacklink,
  MaterialBacklinks,
  MaterialLinkRecord
} from '../../../../shared/types/link'
import { showToast } from '../../app/toast'
import { useT } from '../../i18n'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor, tabTitle } from '../workspace/tabIdentity'
import { TabKindIcon } from '../workspace/workspaceIcons'
import { useMaterialConnections } from './useMaterialConnections'
import './links.css'

interface MaterialBacklinksSectionProps {
  backlinks: MaterialBacklinks
  onOpenNote: (backlink: MaterialBacklink) => void
  onOpenBoard: (backlink: MaterialBacklink) => void
  emptyLabel?: string
}

interface BacklinkListProps {
  kind: 'note' | 'whiteboard'
  label: string
  items: MaterialBacklink[]
  onOpen: (backlink: MaterialBacklink) => void
}

interface ConnectionRow {
  direction: 'outgoing' | 'incoming'
  record: MaterialLinkRecord
  descriptor: TabDescriptor
}

export interface MaterialConnectionsSectionProps {
  courseId: string
  relPath: string
}

export function backlinkPageLabel(page: number | null): string | null {
  return page === null ? null : `${page}쪽`
}

function BacklinkList({
  kind,
  label,
  items,
  onOpen
}: BacklinkListProps): JSX.Element | null {
  if (items.length === 0) return null

  return (
    <div className="pdf-rail__backlink-group">
      <h4 className="pdf-rail__backlink-kind">{label}</h4>
      <ul className="pdf-rail__backlink-list">
        {items.map((backlink, index) => {
          const pageLabel = backlinkPageLabel(backlink.page)
          return (
            <li key={`${backlink.ref}:${backlink.page ?? 'all'}:${index}`}>
              <button
                type="button"
                className="pdf-rail__backlink"
                onClick={() => onOpen(backlink)}
              >
                <TabKindIcon
                  kind={kind}
                  className="pdf-rail__backlink-icon"
                  aria-hidden="true"
                />
                <span className="pdf-rail__backlink-label">
                  {backlink.label}
                </span>
                {pageLabel !== null && (
                  <span className="pdf-rail__backlink-page">{pageLabel}</span>
                )}
              </button>
            </li>
          )
        })}
      </ul>
    </div>
  )
}

/** Kept exported for the existing PDF backlink regression surface. */
export function MaterialBacklinksSection({
  backlinks,
  onOpenNote,
  onOpenBoard,
  emptyLabel
}: MaterialBacklinksSectionProps): JSX.Element | null {
  const t = useT()
  if (
    backlinks.notes.length + backlinks.boards.length === 0 &&
    emptyLabel === undefined
  ) {
    return null
  }

  return (
    <section className="pdf-rail__backlinks" aria-label={t('links.citations.title')}>
      <h3 className="pdf-rail__backlinks-title">
        {t('links.citations.title')}
      </h3>
      {backlinks.notes.length + backlinks.boards.length === 0 ? (
        <p className="material-connections__empty">{emptyLabel}</p>
      ) : (
        <>
          <BacklinkList
            kind="note"
            label={t('links.citations.notes')}
            items={backlinks.notes}
            onOpen={onOpenNote}
          />
          <BacklinkList
            kind="whiteboard"
            label={t('links.citations.boards')}
            items={backlinks.boards}
            onOpen={onOpenBoard}
          />
        </>
      )}
    </section>
  )
}

function relPathForDescriptor(descriptor: TabDescriptor): string | null {
  switch (descriptor.kind) {
    case 'pdf':
    case 'note':
    case 'image':
    case 'file':
      return descriptor.payload.relPath
    case 'browser':
    case 'chat':
    case 'board':
    case 'whiteboard':
    case 'plugin-panel':
    case 'recording':
    case 'learning':
      return null
  }
}

export function connectionFileName(descriptor: TabDescriptor): string {
  const relPath = relPathForDescriptor(descriptor)
  return relPath === null
    ? tabTitle(descriptor)
    : (relPath.split('/').at(-1) ?? relPath)
}

function LinkedMaterialRow({
  row,
  pending,
  onOpen,
  onRemove
}: {
  row: ConnectionRow
  pending: boolean
  onOpen: (row: ConnectionRow) => void
  onRemove: (record: MaterialLinkRecord) => void
}): JSX.Element {
  const t = useT()
  const label = row.record.label.trim()
  const isPageNote = row.record.kind === 'pdf-page-note'

  return (
    <li className="material-connections__row" data-direction={row.direction}>
      <TabKindIcon
        kind={row.descriptor.kind}
        className="material-connections__kind-icon"
        aria-hidden="true"
      />
      <span className="material-connections__body">
        <span className="material-connections__file" title={connectionFileName(row.descriptor)}>
          {connectionFileName(row.descriptor)}
        </span>
        <span className="material-connections__meta">
          <span>{isPageNote ? 'PDF 페이지 필기' : t(`links.connected.${row.direction}`)}</span>
          <span aria-hidden="true">·</span>
          <span>
            {isPageNote
              ? `${row.record.metadata?.pageSizes.length ?? 0}쪽 · ${row.record.metadata?.syncScroll === false ? '동기화 꺼짐' : '동기화 켬'}`
              : label.length === 0 ? t('links.label.empty') : label}
          </span>
        </span>
      </span>
      <span className="material-connections__actions">
        <button type="button" onClick={() => onOpen(row)}>
          {isPageNote ? '나란히 열기' : t('links.action.open')}
        </button>
        <button
          type="button"
          disabled={pending}
          onClick={() => onRemove(row.record)}
        >
          {pending ? t('links.action.unlinking') : t('links.action.unlink')}
        </button>
      </span>
    </li>
  )
}

export function MaterialConnectionsSection({
  courseId,
  relPath
}: MaterialConnectionsSectionProps): JSX.Element {
  const t = useT()
  const { backlinks, outgoing, incoming, loading, error, remove } =
    useMaterialConnections(courseId, relPath)
  const [pendingId, setPendingId] = useState<string | null>(null)

  const openNote = useCallback(
    (backlink: MaterialBacklink): void => {
      useWorkspaceStore.getState().openTab(
        descriptorFor('note', { courseId, relPath: backlink.ref })
      )
    },
    [courseId]
  )
  const openBoard = useCallback(
    (backlink: MaterialBacklink): void => {
      useWorkspaceStore.getState().openTab(
        descriptorFor('whiteboard', { courseId, boardId: backlink.ref })
      )
    },
    [courseId]
  )
  const openConnection = useCallback((row: ConnectionRow): void => {
    if (
      row.record.kind === 'pdf-page-note' &&
      (row.record.source.kind === 'pdf' || row.record.source.kind === 'file') &&
      row.record.target.kind === 'note'
    ) {
      useWorkspaceStore.getState().openPdfNotePair(
        row.record.source,
        row.record.target,
        row.record.id,
        1
      )
      return
    }
    useWorkspaceStore.getState().openTab(row.descriptor)
  }, [])
  const unlink = useCallback(
    async (record: MaterialLinkRecord): Promise<void> => {
      setPendingId(record.id)
      try {
        await remove(record.id)
      } catch (caught) {
        console.error('[Bandal] 자료 연결을 해제하지 못했습니다.', caught)
        showToast(t('links.error.remove'), 'danger')
      } finally {
        setPendingId(null)
      }
    },
    [remove, t]
  )

  const rows: ConnectionRow[] = [
    ...outgoing.map((record) => ({
      direction: 'outgoing' as const,
      record,
      descriptor: record.target
    })),
    ...incoming.map((record) => ({
      direction: 'incoming' as const,
      record,
      descriptor: record.source
    }))
  ]
  const stateLabel = loading
    ? t('links.loading')
    : error === null
      ? null
      : t('links.error.load')

  return (
    <div className="material-connections" aria-busy={loading || undefined}>
      <MaterialBacklinksSection
        backlinks={backlinks}
        onOpenNote={openNote}
        onOpenBoard={openBoard}
        emptyLabel={stateLabel ?? t('links.citations.empty')}
      />
      <section
        className="material-connections__linked"
        aria-label={t('links.connected.title')}
      >
        <h3 className="material-connections__title">
          {t('links.connected.title')}
        </h3>
        {rows.length === 0 ? (
          <p className="material-connections__empty">
            {stateLabel ?? t('links.connected.empty')}
          </p>
        ) : (
          <ul className="material-connections__list">
            {rows.map((row) => (
              <LinkedMaterialRow
                key={`${row.direction}:${row.record.id}`}
                row={row}
                pending={row.record.id === pendingId}
                onOpen={openConnection}
                onRemove={(record) => void unlink(record)}
              />
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
