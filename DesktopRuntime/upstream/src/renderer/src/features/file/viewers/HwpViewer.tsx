import { useEffect, useState } from 'react'
import { HwpUnsupportedError, readHwpText } from '../hwp/hwpContainer'
import { parseHwpxSections, sortSectionPaths } from '../hwpx/parseHwpx'

interface HwpViewerProps {
  base64: string
  fileName: string
  onError: () => void
}

type HwpState =
  | { status: 'loading' }
  | { status: 'ready'; paragraphs: string[] }
  | { status: 'unsupported'; reason: string }

function base64ToBytes(base64: string): Uint8Array {
  const binary = window.atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

async function readHwpxParagraphs(bytes: Uint8Array): Promise<string[]> {
  const jszipModule = await import('jszip')
  const JSZip = (jszipModule as unknown as { default?: typeof import('jszip') })
    .default ?? jszipModule
  const zip = await JSZip.loadAsync(bytes)
  const sectionPaths = sortSectionPaths(
    Object.keys(zip.files).filter((path) =>
      /^Contents\/section\d+\.xml$/iu.test(path)
    )
  )
  const xmls = await Promise.all(
    sectionPaths.map((path) => zip.files[path]!.async('string'))
  )
  return parseHwpxSections(xmls)
}

/**
 * 한글(.hwp/.hwpx) 본문 텍스트 미리보기. 확장자가 아니라 매직 바이트로
 * 컨테이너를 판별한다(zip=PK → hwpx, CFB → hwp 5.0) — 잘못 붙은 확장자도
 * 열린다. 서식·표·이미지는 표시하지 않는다.
 */
export function HwpViewer({
  base64,
  fileName,
  onError
}: HwpViewerProps): JSX.Element {
  const [state, setState] = useState<HwpState>({ status: 'loading' })

  useEffect(() => {
    let cancelled = false
    const load = async (): Promise<void> => {
      const bytes = base64ToBytes(base64)
      if (bytes[0] === 0x50 && bytes[1] === 0x4b) {
        const paragraphs = await readHwpxParagraphs(bytes)
        if (!cancelled) setState({ status: 'ready', paragraphs })
        return
      }
      if (
        bytes[0] === 0xd0 && bytes[1] === 0xcf &&
        bytes[2] === 0x11 && bytes[3] === 0xe0
      ) {
        const text = await readHwpText(bytes)
        if (!cancelled) {
          setState({ status: 'ready', paragraphs: text.split('\n') })
        }
        return
      }
      throw new Error('알 수 없는 컨테이너')
    }
    load().catch((error: unknown) => {
      if (cancelled) return
      if (error instanceof HwpUnsupportedError) {
        setState({
          status: 'unsupported',
          reason: error.message === '암호로 보호된 문서'
            ? '암호로 보호된 문서는 미리 볼 수 없어요.'
            : '이 한글 문서 형식(배포용 등)은 미리 볼 수 없어요.'
        })
        return
      }
      console.error('[Bandal] 한글 문서 해석 실패', error)
      onError()
    })
    return () => {
      cancelled = true
    }
  }, [base64, onError])

  if (state.status === 'loading') {
    return (
      <div className="file-status" role="status">
        한글 문서를 해석하는 중…
      </div>
    )
  }
  if (state.status === 'unsupported') {
    return (
      <div className="file-status" role="status">
        <h2>{fileName}</h2>
        <p>{state.reason}</p>
      </div>
    )
  }

  const meaningful = state.paragraphs.filter(
    (paragraph) => paragraph.trim().length > 0
  )
  return (
    <div className="file-hwp">
      <header className="file-hwp__header">
        <strong>{fileName}</strong>
        <span className="file-hwp__notice">
          텍스트 미리보기 — 서식은 표시되지 않습니다
        </span>
      </header>
      {meaningful.length === 0 ? (
        <div className="file-status" role="status">
          표시할 텍스트가 없습니다.
        </div>
      ) : (
        <article className="file-hwp__document">
          {state.paragraphs.map((paragraph, index) => (
            <p key={index}>{paragraph.length === 0 ? ' ' : paragraph}</p>
          ))}
        </article>
      )}
    </div>
  )
}
