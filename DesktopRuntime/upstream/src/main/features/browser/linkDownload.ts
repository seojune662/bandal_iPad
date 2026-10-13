/**
 * 브라우저에서 끌어온 링크를 과목 자료로 내려받는다.
 *
 * 반드시 `persist:browsing` 세션으로 fetch 한다 — 학사 포털의 PDF 는 로그인
 * 쿠키가 있어야 받아지므로, 학생이 웹뷰에서 로그인해 둔 그 세션을 그대로
 * 태워야 한다. 파일 이름/경로 안전성은 전부 materialsRepo.writeFile 이
 * 이미 강제한다(경로 이탈 거부·중복 리네임·wx). 여기서는 이름 후보만 만든다.
 */

import { session } from 'electron'
import { ValidationError } from '../../db/errors'
import { MAX_WRITE_BYTES } from '../materials/materialsRepo'
import {
  driveConfirmUrl,
  googleDriveFileId,
  rewriteDriveUrl
} from './driveUrl'
import { BROWSING_PARTITION } from './webviewPolicy'

export const FALLBACK_FILE_NAME = '다운로드'

/** Content-Disposition → URL 경로 → 폴백 순서로 파일 이름 후보를 고른다. */
export function fileNameForDownload(
  contentDisposition: string | null,
  finalUrl: string
): string {
  const fromDisposition = parseDispositionFileName(contentDisposition)
  const candidate = fromDisposition ?? fileNameFromUrl(finalUrl)
  const cleaned = sanitizeFileName(candidate ?? '')
  return cleaned === '' ? FALLBACK_FILE_NAME : cleaned
}

function parseDispositionFileName(header: string | null): string | null {
  if (header === null || header === '') return null
  // RFC 5987 filename*=UTF-8''… 가 우선, 그다음 따옴표/맨몸 filename=.
  const extended = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)/u.exec(header)
  if (extended?.[1] !== undefined) {
    try {
      return decodeURIComponent(extended[1].trim())
    } catch {
      return extended[1].trim()
    }
  }
  const quoted = /filename\s*=\s*"([^"]+)"/u.exec(header)
  if (quoted?.[1] !== undefined) return quoted[1]
  const bare = /filename\s*=\s*([^;]+)/u.exec(header)
  return bare?.[1]?.trim() ?? null
}

function fileNameFromUrl(url: string): string | null {
  try {
    const parsed = new URL(url)
    const last = parsed.pathname.split('/').filter((part) => part !== '').pop()
    if (last === undefined) return null
    try {
      return decodeURIComponent(last)
    } catch {
      return last
    }
  } catch {
    return null
  }
}

/** 경로 구분자·제어 문자를 걷어내 requireBasename 이 거부할 이름을 막는다. */
/** Shared with the will-download handler: strips separators and control chars. */
export function sanitizeFileName(raw: string): string {
  return raw
    .replace(/[/\\\u0000-\u001f]/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim()
    .slice(0, 180)
}

export interface LinkDownloadResult {
  fileName: string
  dataBase64: string
}

async function responseBody(response: Response): Promise<Buffer> {
  if (!response.ok) {
    throw new ValidationError(`다운로드에 실패했습니다 (HTTP ${response.status})`)
  }
  const declared = Number(response.headers.get('content-length') ?? '0')
  if (Number.isFinite(declared) && declared > MAX_WRITE_BYTES) {
    throw new ValidationError('파일이 너무 큽니다 (50MB 제한)')
  }
  const body = Buffer.from(await response.arrayBuffer())
  if (body.byteLength > MAX_WRITE_BYTES) {
    throw new ValidationError('파일이 너무 큽니다 (50MB 제한)')
  }
  return body
}

function isHtmlResponse(response: Response, body: Buffer): boolean {
  if (response.headers.get('content-type')?.includes('text/html') === true) {
    return true
  }
  const prefix = body.subarray(0, 4096).toString('utf8')
  return /<!doctype\s+html|<html\b|<form\b/iu.test(prefix)
}

/**
 * 링크를 브라우징 세션으로 받아 (이름 후보, base64 본문)을 돌려준다.
 * 저장은 호출자가 materialsRepo.writeFile 로 한다.
 */
export async function fetchLinkForMaterials(
  url: string,
  browsing = session.fromPartition(BROWSING_PARTITION)
): Promise<LinkDownloadResult> {
  const driveId = googleDriveFileId(url)
  const rewritten = rewriteDriveUrl(url)
  let parsed: URL
  try {
    parsed = new URL(rewritten)
  } catch {
    throw new ValidationError('내려받을 주소가 올바르지 않습니다')
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new ValidationError('http/https 주소만 내려받을 수 있습니다')
  }

  let response = await browsing.fetch(parsed.toString(), {
    redirect: 'follow'
  })
  let body = await responseBody(response)
  if (isHtmlResponse(response, body)) {
    const confirmUrl = driveConfirmUrl(body.toString('utf8'))
    if (confirmUrl !== null) {
      response = await browsing.fetch(confirmUrl, { redirect: 'follow' })
      body = await responseBody(response)
    }
  }

  const disposition = response.headers.get('content-disposition')
  const finalUrl = response.url === '' ? parsed.toString() : response.url
  const fileName = (disposition === null || disposition === '') && driveId !== null
    ? sanitizeFileName(driveId)
    : fileNameForDownload(disposition, finalUrl)

  return {
    fileName,
    dataBase64: body.toString('base64')
  }
}
