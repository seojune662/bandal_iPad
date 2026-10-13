/**
 * HWP 5.0 바이너리(레코드 스트림) 파싱 — 순수 함수.
 * 목표는 본문 텍스트 추출뿐이다: PARA_TEXT 레코드의 UTF-16LE 를 읽고
 * 인라인 컨트롤을 규격 크기만큼 건너뛴다.
 */

const HWP_SIGNATURE = 'HWP Document File'
/** FileHeader 의 속성 DWORD 오프셋 — bit0 = 본문 압축(deflate-raw). */
const FLAGS_OFFSET = 36

export const HWPTAG_PARA_TEXT = 67 // HWPTAG_BEGIN(0x10) + 51

export interface HwpFileHeader {
  isHwp: boolean
  compressed: boolean
  passworded: boolean
}

export function parseHwpFileHeader(bytes: Uint8Array): HwpFileHeader {
  if (bytes.length < FLAGS_OFFSET + 4) {
    return { isHwp: false, compressed: false, passworded: false }
  }
  const signature = new TextDecoder('latin1').decode(
    bytes.subarray(0, HWP_SIGNATURE.length)
  )
  if (signature !== HWP_SIGNATURE) {
    return { isHwp: false, compressed: false, passworded: false }
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const flags = view.getUint32(FLAGS_OFFSET, true)
  return {
    isHwp: true,
    compressed: (flags & 0x1) !== 0,
    passworded: (flags & 0x2) !== 0
  }
}

export interface HwpRecord {
  tagId: number
  level: number
  payload: Uint8Array
}

/** 레코드 스트림 순회. 잘린 꼬리는 예외 없이 종료한다. */
export function* iterateHwpRecords(stream: Uint8Array): Generator<HwpRecord> {
  const view = new DataView(stream.buffer, stream.byteOffset, stream.byteLength)
  let offset = 0
  while (offset + 4 <= stream.length) {
    const header = view.getUint32(offset, true)
    offset += 4
    const tagId = header & 0x3ff
    const level = (header >>> 10) & 0x3ff
    let size = header >>> 20
    if (size === 0xfff) {
      if (offset + 4 > stream.length) return
      size = view.getUint32(offset, true)
      offset += 4
    }
    if (offset + size > stream.length) return
    yield { tagId, level, payload: stream.subarray(offset, offset + size) }
    offset += size
  }
}

/**
 * 컨트롤 문자(UTF-16 유닛 코드 < 32)가 차지하는 유닛 수 — HWP 5.0 규격.
 * 인라인/확장 컨트롤(1-8, 11, 12, 14-23)은 문자 + 7유닛 페이로드 = 8유닛,
 * 탭(9)·줄바꿈(10)·문단끝(13)과 나머지(0, 24-31)는 1유닛.
 */
const CONTROL_UNIT_SIZES: readonly number[] = (() => {
  const sizes = new Array<number>(32).fill(1)
  for (const code of [1, 2, 3, 4, 5, 6, 7, 8, 11, 12,
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23]) {
    sizes[code] = 8
  }
  return sizes
})()

export function extractParaText(payload: Uint8Array): string {
  const even = payload.length - (payload.length % 2)
  const view = new DataView(payload.buffer, payload.byteOffset, even)
  let text = ''
  let unit = 0
  const totalUnits = even / 2
  while (unit < totalUnits) {
    const code = view.getUint16(unit * 2, true)
    if (code >= 32) {
      text += String.fromCharCode(code)
      unit += 1
      continue
    }
    if (code === 9) text += '\t'
    else if (code === 10 || code === 13) text += '\n'
    unit += CONTROL_UNIT_SIZES[code] ?? 1
  }
  return text
}

/** 섹션 레코드 스트림 → 문단 텍스트(개행 구분). */
export function extractSectionText(recordStream: Uint8Array): string {
  const parts: string[] = []
  for (const record of iterateHwpRecords(recordStream)) {
    if (record.tagId === HWPTAG_PARA_TEXT) {
      parts.push(extractParaText(record.payload))
    }
  }
  return parts.join('\n').replaceAll(/\n{3,}/gu, '\n\n').trim()
}
