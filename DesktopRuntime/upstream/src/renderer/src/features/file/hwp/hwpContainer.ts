/**
 * HWP 5.0 CFB 컨테이너 접착부. CFB 파싱은 벤더 xlsx 의 CFB export 를
 * 재사용한다(별도 의존성 없음 — hwpContainer.test 왕복 테스트가 벤더
 * 교체 시 시끄럽게 실패하도록 핀 고정). 압축 섹션은 raw deflate 라
 * Chromium/Node 공용 DecompressionStream 으로 푼다.
 */

import {
  extractSectionText,
  parseHwpFileHeader
} from './parseHwp'

interface CfbEntry {
  name: string
  content?: Uint8Array | number[]
}

interface CfbContainer {
  FullPaths: string[]
  FileIndex: CfbEntry[]
}

interface CfbModule {
  read(data: Uint8Array, options: { type: 'buffer' }): CfbContainer
  find(container: CfbContainer, path: string): CfbEntry | null
}

export class HwpUnsupportedError extends Error {}

async function loadCfb(): Promise<CfbModule> {
  const xlsx = await import('xlsx')
  const module_ = (xlsx as unknown as { CFB?: CfbModule; default?: { CFB?: CfbModule } })
  const cfb = module_.CFB ?? module_.default?.CFB
  if (cfb === undefined) {
    throw new Error('벤더 xlsx 에 CFB export 가 없습니다.')
  }
  return cfb
}

function entryBytes(entry: CfbEntry): Uint8Array {
  const content = entry.content ?? []
  return content instanceof Uint8Array ? content : Uint8Array.from(content)
}

export async function inflateRawDeflate(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([bytes.slice()])
    .stream()
    .pipeThrough(new DecompressionStream('deflate-raw'))
  return new Uint8Array(await new Response(stream).arrayBuffer())
}

/**
 * .hwp 파일 바이트에서 본문 텍스트를 뽑는다. 암호 문서·서명 불일치는
 * HwpUnsupportedError 로 구분해 안내 UI 로 강등할 수 있게 한다.
 */
export async function readHwpText(fileBytes: Uint8Array): Promise<string> {
  const cfb = await loadCfb()
  const container = cfb.read(fileBytes, { type: 'buffer' })
  const headerEntry = cfb.find(container, '/FileHeader')
  if (headerEntry === null) throw new HwpUnsupportedError('FileHeader 없음')
  const header = parseHwpFileHeader(entryBytes(headerEntry))
  if (!header.isHwp) throw new HwpUnsupportedError('HWP 서명 불일치')
  if (header.passworded) throw new HwpUnsupportedError('암호로 보호된 문서')

  const sections = container.FullPaths
    .map((path, index) => ({ path, index }))
    .filter(({ path }) => /BodyText\/Section\d+$/u.test(path))
    .sort((left, right) => {
      const number = (path: string): number =>
        Number(/Section(\d+)$/u.exec(path)?.[1] ?? 0)
      return number(left.path) - number(right.path)
    })
  if (sections.length === 0) {
    // 배포용(ViewText) 문서 등 — 본문 스트림이 없다.
    throw new HwpUnsupportedError('본문 스트림 없음')
  }

  const texts: string[] = []
  for (const { index } of sections) {
    const entry = container.FileIndex[index]
    if (entry === undefined) continue
    const raw = entryBytes(entry)
    const stream = header.compressed ? await inflateRawDeflate(raw) : raw
    texts.push(extractSectionText(stream))
  }
  return texts.join('\n\n').trim()
}
