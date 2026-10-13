import {
  BANDAL_LINK_SCHEME,
  type MaterialLink
} from '../../../../shared/types/link'
import { materialKindForPath } from '../../../../shared/materialKind'
import type { MaterialKind } from '../../../../shared/types/materials'
import { requestPdfPageJump } from '../search/searchNavigation'
import { openMaterialInCourse } from '../workspace/openMaterial'

const MATERIAL_LINK_TARGET = 'material'
const PDF_JUMP_RETRY_MS = 50
const PDF_JUMP_MAX_ATTEMPTS = 200

export const PDF_ANNOTATION_JUMP_EVENT = 'bandal:pdf-annotation-jump'

export interface PdfAnnotationJumpDetail {
  courseId: string
  relPath: string
  page: number
  annotationId: string
  /** The matching PdfViewer sets this to stop the sender's mount/load retry. */
  handled: boolean
}

export type NoteLinkResolution =
  | { kind: 'pass-through' }
  | { kind: 'invalid-bandal' }
  | { kind: 'material'; link: MaterialLink }

export interface MaterialLinkNavigationDeps {
  openMaterial: (
    courseId: string,
    kind: MaterialKind,
    relPath: string
  ) => void
  jumpToPage: (page: number) => void
  jumpToAnnotation: (detail: Omit<PdfAnnotationJumpDetail, 'handled'>) => void
}

/** Renderer-side pure parser for URLs arriving from Milkdown's DOM. */
export function parseMaterialLinkHref(href: string): MaterialLink | null {
  if (typeof href !== 'string' || href.trim().length === 0) return null

  let url: URL
  try {
    url = new URL(href.trim())
  } catch {
    return null
  }
  if (
    url.protocol !== BANDAL_LINK_SCHEME ||
    url.hostname !== MATERIAL_LINK_TARGET ||
    (url.pathname !== '' && url.pathname !== '/')
  ) {
    return null
  }

  const relPath = url.searchParams.get('path')
  if (relPath === null || relPath.length === 0) return null

  const rawPage = url.searchParams.get('page')
  let page: number | null = null
  if (rawPage !== null) {
    if (!/^\d+$/.test(rawPage)) return null
    page = Number(rawPage)
    if (!Number.isSafeInteger(page) || page < 1) return null
  }

  const annotationId = url.searchParams.get('annotationId')
  return annotationId === null || annotationId.length === 0
    ? { relPath, page }
    : { relPath, page, annotationId }
}

/** Pure click policy: only the bandal: scheme is intercepted. */
export function resolveNoteLink(href: string): NoteLinkResolution {
  let url: URL
  try {
    url = new URL(href.trim())
  } catch {
    return { kind: 'pass-through' }
  }
  if (url.protocol !== BANDAL_LINK_SCHEME) return { kind: 'pass-through' }
  const link = parseMaterialLinkHref(href)
  return link === null ? { kind: 'invalid-bandal' } : { kind: 'material', link }
}

let annotationJumpTimer: number | null = null

/** Retries until a newly mounted PDF has loaded the requested annotation. */
export function requestPdfAnnotationJump(
  detail: Omit<PdfAnnotationJumpDetail, 'handled'>
): void {
  if (annotationJumpTimer !== null) window.clearTimeout(annotationJumpTimer)
  let attempts = 0

  const tryJump = (): void => {
    attempts += 1
    const eventDetail: PdfAnnotationJumpDetail = { ...detail, handled: false }
    window.dispatchEvent(
      new CustomEvent<PdfAnnotationJumpDetail>(PDF_ANNOTATION_JUMP_EVENT, {
        detail: eventDetail
      })
    )
    if (eventDetail.handled) {
      annotationJumpTimer = null
      return
    }
    if (attempts >= PDF_JUMP_MAX_ATTEMPTS) {
      annotationJumpTimer = null
      return
    }
    annotationJumpTimer = window.setTimeout(tryJump, PDF_JUMP_RETRY_MS)
  }

  tryJump()
}

const DEFAULT_NAVIGATION_DEPS: MaterialLinkNavigationDeps = {
  openMaterial: openMaterialInCourse,
  jumpToPage: requestPdfPageJump,
  jumpToAnnotation: requestPdfAnnotationJump
}

/** Opens a parsed link through the existing workspace and PDF jump paths. */
export function openMaterialLink(
  courseId: string,
  link: MaterialLink,
  deps: MaterialLinkNavigationDeps = DEFAULT_NAVIGATION_DEPS
): void {
  const kind = materialKindForPath(link.relPath)
  deps.openMaterial(courseId, kind, link.relPath)
  if (kind === 'pdf' && link.page !== null) deps.jumpToPage(link.page)
  if (
    kind === 'pdf' &&
    link.page !== null &&
    link.annotationId !== undefined
  ) {
    deps.jumpToAnnotation({
      courseId,
      relPath: link.relPath,
      page: link.page,
      annotationId: link.annotationId
    })
  }
}
