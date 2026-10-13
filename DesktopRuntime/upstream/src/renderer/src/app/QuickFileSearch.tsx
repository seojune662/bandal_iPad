/**
 * [M6-A] ⌘P quick file search — a small omnibox overlay that searches the
 * SELECTED course's materials (`materials:search`). Enter opens the hit by
 * the same rules as the sidebar (pdf/note → tab, everything else → Finder),
 * Esc closes. Open/close state lives in useQuickSearch (shortcuts.ts).
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import type {
  MaterialKind,
  MaterialSearchHit
} from '../../../shared/types/materials'
import { openMaterialInCourse } from '../features/workspace/openMaterial'
import { isViewableFile } from '../features/file/fileFormats'
import { acquirePointerPassthrough } from '../features/browser/webviewPassthrough'
import { invoke } from '../lib/ipc'
import { useCoursesStore } from '../stores/coursesStore'
import { useFocusTrap } from '../components/useFocusTrap'
import { useQuickSearch } from './shortcuts'
import { Icon, type IconName } from './icons'
import './quick-search.css'

const SEARCH_DEBOUNCE_MS = 180
const MAX_RESULTS = 12

const KIND_ICONS: Record<MaterialKind, IconName> = {
  pdf: 'filePdf',
  note: 'fileText',
  image: 'fileImage',
  video: 'file',
  other: 'file'
}

export function QuickFileSearch(): JSX.Element | null {
  const isOpen = useQuickSearch((state) => state.isOpen)
  const close = useQuickSearch((state) => state.close)
  const courses = useCoursesStore((state) => state.courses)
  const selectedCourseId = useCoursesStore((state) => state.selectedCourseId)
  const course =
    courses.find((entry) => entry.id === selectedCourseId) ?? null

  const [query, setQuery] = useState('')
  const [hits, setHits] = useState<MaterialSearchHit[]>([])
  const [isSearching, setIsSearching] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [highlighted, setHighlighted] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const dialogRef = useRef<HTMLDivElement>(null)
  const sequenceRef = useRef(0)

  useFocusTrap(dialogRef, {
    active: isOpen,
    initialFocus: inputRef,
    onEscape: close
  })

  // Reset on every open; keep guests from eating the pointer while up.
  useEffect(() => {
    if (!isOpen) return
    setQuery('')
    setHits([])
    setHighlighted(0)
    const release = acquirePointerPassthrough()
    return () => {
      release()
    }
  }, [isOpen, close])

  useEffect(() => {
    const sequence = ++sequenceRef.current
    setHits([])
    setError(null)
    setIsSearching(false)
    if (!isOpen || course === null) return
    const normalized = query.trim()
    if (normalized.length === 0) {
      setHits([])
      setIsSearching(false)
      return
    }
    setIsSearching(true)
    const timeout = window.setTimeout(() => {
      void invoke('materials:search', { courseId: course.id, query: normalized })
        .then((results) => {
          if (sequence !== sequenceRef.current) return
          setHits(results.slice(0, MAX_RESULTS))
          setHighlighted(0)
        })
        .catch((cause: unknown) => {
          if (sequence === sequenceRef.current) setError(cause instanceof Error ? cause.message : '파일을 검색하지 못했어요.')
        })
        .finally(() => {
          if (sequence === sequenceRef.current) setIsSearching(false)
        })
    }, SEARCH_DEBOUNCE_MS)
    return () => { window.clearTimeout(timeout); sequenceRef.current += 1 }
  }, [isOpen, course, query, attempt])

  const activate = useCallback(
    (hit: MaterialSearchHit | undefined): void => {
      if (hit === undefined || course === null || isSearching) return
      openMaterialInCourse(course.id, hit.kind, hit.relPath)
      close()
    },
    [course, close, isSearching]
  )

  if (!isOpen) return null

  const clamped = Math.min(highlighted, Math.max(hits.length - 1, 0))
  const showsResults = course !== null && query.trim().length > 0

  return (
    <div
      className="quick-search-overlay"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) close()
      }}
    >
      <div
        ref={dialogRef}
        className="quick-search"
        role="dialog"
        aria-modal="true"
        aria-label="빠른 파일 검색"
      >
        <div className="quick-search__field">
          <Icon name="search" />
          <input
            ref={inputRef}
            type="text"
            placeholder={
              course === null ? '먼저 과목을 선택해 주세요' : `${course.name}에서 파일 찾기`
            }
            aria-label="파일 검색어"
            value={query}
            disabled={course === null}
            onChange={(event) => {
              setQuery(event.target.value)
              setHighlighted(0)
            }}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing) return
              if (event.key === 'ArrowDown') {
                event.preventDefault()
                setHighlighted((index) => Math.min(index + 1, hits.length - 1))
              } else if (event.key === 'ArrowUp') {
                event.preventDefault()
                setHighlighted((index) => Math.max(index - 1, 0))
              } else if (event.key === 'Enter') {
                event.preventDefault()
                activate(hits[clamped])
              }
            }}
          />
          <kbd className="quick-search__esc" aria-hidden="true">
            esc
          </kbd>
        </div>

        <div className="quick-search__body">
          {!showsResults ? null : error ? (
            <div className="quick-search__hint" role="alert">
              <p>{error}</p>
              <button type="button" className="button button--secondary" onClick={() => setAttempt(value => value + 1)}>다시 시도</button>
            </div>
          ) : isSearching && hits.length === 0 ? (
            <p className="quick-search__hint" role="status">
              찾는 중…
            </p>
          ) : hits.length === 0 ? (
            <p className="quick-search__hint">결과 없음</p>
          ) : (
            <ul className="quick-search__list" role="listbox" aria-label="검색 결과">
              {hits.map((hit, index) => (
                <li key={hit.relPath} role="presentation">
                  <button
                    type="button"
                    role="option"
                    aria-selected={index === clamped}
                    data-highlighted={index === clamped}
                    onMouseEnter={() => setHighlighted(index)}
                    onClick={() => activate(hit)}
                  >
                    <span className="quick-search__icon">
                      <Icon name={KIND_ICONS[hit.kind]} />
                    </span>
                    <span className="quick-search__name">{hit.name}</span>
                    <span className="quick-search__meta">
                      {hit.relPath.includes('/')
                        ? hit.relPath.slice(0, hit.relPath.lastIndexOf('/'))
                        : hit.kind !== 'other' || isViewableFile(hit.relPath) ? '탭에서 열기' : '폴더에서 보기'}
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
