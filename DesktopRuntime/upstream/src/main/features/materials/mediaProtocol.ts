/**
 * `bandal-media://` 스트리밍 프로토콜.
 *
 * 동영상·PDF(그리고 앞으로는 큰 이미지)는 materials:readFile 의 base64-over-IPC
 * 경로로는 감당이 안 된다 — 64MB 상한에 걸리고, 걸리지 않아도 전체를 메모리에
 * 올린다. 이 프로토콜은 Range 요청을 지원하는 스트리밍 응답으로 파일을 내려,
 * <video> 가 임의 위치 탐색(seek)을 할 수 있게 한다.
 *
 * URL 형식 (mediaUrlFor 와 반드시 일치해야 한다):
 *   bandal-media://material/<encodeURIComponent(courseId)>/<seg1>/<seg2>/…
 * relPath 는 '/' 를 포함할 수 있으므로 **세그먼트별로** encodeURIComponent 하고,
 * 파싱 시 세그먼트별로 한 번 decodeURIComponent 한 뒤 '/' 로 다시 잇는다.
 * (전체를 한 번에 인코딩하면 '/'(%2F)가 경로 구분자와 섞여 모호해진다.)
 *
 * 경로 이탈 방어는 이중이다: 여기서 '..'/'.'/구분자 포함 세그먼트를 거르고,
 * 최종적으로 materialsRepo.absolutePathFor(resolveInsideReal) 가 다시 막는다.
 * 모든 실패는 404 로 응답한다 — 렌더러에 경로 존재 여부를 흘리지 않는다.
 *
 * 이 모듈은 electron 을 import 하지 않는다(단위 테스트 용이성). 실제 등록은
 * registerHandlers.ts 의 protocol.handle 과 index.ts 의
 * registerSchemesAsPrivileged 가 담당한다.
 */

import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { Readable } from 'node:stream'

export const MEDIA_SCHEME = 'bandal-media'
export const MEDIA_HOST = 'material'

/** 확장자 → Content-Type. 동영상이 주 대상, 이미지 계열은 향후 사용 대비. */
const MEDIA_CONTENT_TYPES: Record<string, string> = {
  '.wav': 'audio/wav',
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.webm': 'video/webm',
  // pdf.js 가 Range 요청으로 페이지 단위 lazy 로드한다 — 64MB IPC 캡 우회.
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.bmp': 'image/bmp',
  '.avif': 'image/avif'
}

export function mediaContentTypeFor(relPath: string): string {
  const name = relPath.split('/').at(-1) ?? relPath
  const dot = name.lastIndexOf('.')
  const ext = dot < 0 ? '' : name.slice(dot).toLowerCase()
  return MEDIA_CONTENT_TYPES[ext] ?? 'application/octet-stream'
}

export interface ParsedMediaUrl {
  courseId: string
  relPath: string
}

/** 실패는 전부 null — 프로토콜 핸들러가 404 로 바꾼다. 절대 throw 하지 않는다. */
export function parseMediaUrl(url: string): ParsedMediaUrl | null {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return null
  }
  if (parsed.protocol !== `${MEDIA_SCHEME}:`) return null
  if (parsed.host !== MEDIA_HOST) return null

  const segments = parsed.pathname.split('/').slice(1)
  if (segments.length < 2) return null

  let decoded: string[]
  try {
    decoded = segments.map((segment) => decodeURIComponent(segment))
  } catch {
    return null
  }
  const [courseId, ...rest] = decoded
  if (courseId === undefined || courseId === '') return null
  for (const segment of rest) {
    if (
      segment === '' ||
      segment === '.' ||
      segment === '..' ||
      segment.includes('/') ||
      segment.includes('\\')
    ) {
      return null
    }
  }
  return { courseId, relPath: rest.join('/') }
}

export interface ByteRange {
  /** inclusive */
  start: number
  /** inclusive */
  end: number
}

/**
 * 단일 Range(`bytes=start-end`, `bytes=start-`, `bytes=-suffix`)만 지원한다.
 * 형식이 다르거나(다중 범위 등) 만족 불가능하면 null — 200 전체 응답으로
 * 안전하게 물러난다. Chromium 의 <video> 는 단일 범위만 보낸다.
 */
export function parseRangeHeader(
  header: string | null,
  size: number
): ByteRange | null {
  if (header === null || size <= 0) return null
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim())
  if (match === null) return null
  const [, startText, endText] = match
  if (startText === '' && endText === '') return null

  // `bytes=-N`: 마지막 N 바이트
  if (startText === '') {
    const suffix = Number(endText)
    if (suffix <= 0) return null
    return { start: Math.max(0, size - suffix), end: size - 1 }
  }

  const start = Number(startText)
  if (start >= size) return null
  if (endText === '') return { start, end: size - 1 }

  const end = Math.min(Number(endText), size - 1)
  if (start > end) return null
  return { start, end }
}

export interface MediaProtocolDeps {
  /** 경로 이탈 가드를 거친 절대 경로 (materialsRepo.absolutePathFor). */
  absolutePathFor(courseId: string, relPath: string): string | Promise<string>
}

function notFound(): Response {
  return new Response('not found', { status: 404 })
}

/** protocol.handle('bandal-media', …) 에 그대로 넘기는 핸들러. */
export function createMediaProtocolHandler(
  deps: MediaProtocolDeps
): (request: Request) => Promise<Response> {
  return async (request) => {
    const parsed = parseMediaUrl(request.url)
    if (parsed === null) return notFound()

    let abs: string
    try {
      // absolutePathFor 는 이탈/부재 시 throw 한다 — 존재 여부를 숨기고 404.
      abs = await deps.absolutePathFor(parsed.courseId, parsed.relPath)
    } catch {
      return notFound()
    }

    let size: number
    try {
      const stats = await stat(abs)
      if (!stats.isFile()) return notFound()
      size = stats.size
    } catch {
      return notFound()
    }

    const contentType = mediaContentTypeFor(parsed.relPath)
    const range = parseRangeHeader(request.headers.get('range'), size)

    // corsEnabled 스킴에는 CORS 가 적용된다 — pdf.js 의 fetch(range)가
    // 렌더러 오리진에서 오므로 ACAO 와 range 관련 헤더 노출이 필요하다.
    // 읽기 전용 + 경로 이탈 이중 방어 스킴이라 '*' 로 충분하다.
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Expose-Headers':
        'Accept-Ranges, Content-Range, Content-Length'
    }

    if (range === null) {
      const stream = Readable.toWeb(
        createReadStream(abs)
      ) as ReadableStream<Uint8Array>
      return new Response(stream, {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': contentType,
          'Content-Length': String(size),
          'Accept-Ranges': 'bytes'
        }
      })
    }

    const stream = Readable.toWeb(
      createReadStream(abs, { start: range.start, end: range.end })
    ) as ReadableStream<Uint8Array>
    return new Response(stream, {
      status: 206,
      headers: {
        ...corsHeaders,
        'Content-Type': contentType,
        'Content-Length': String(range.end - range.start + 1),
        'Content-Range': `bytes ${range.start}-${range.end}/${size}`,
        'Accept-Ranges': 'bytes'
      }
    })
  }
}
