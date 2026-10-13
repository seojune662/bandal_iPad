import { useMemo } from 'react'

interface TextViewerProps {
  text: string
  fileName: string
}

const MAX_TEXT_BYTES = 2 * 1024 * 1024

function textPreview(text: string): { text: string; truncated: boolean } {
  const bytes = new TextEncoder().encode(text)
  if (bytes.byteLength <= MAX_TEXT_BYTES) return { text, truncated: false }

  // Streaming decode intentionally drops an incomplete trailing UTF-8 code
  // point rather than showing a replacement character at the cut boundary.
  const decoder = new TextDecoder('utf-8')
  return {
    text: decoder.decode(bytes.subarray(0, MAX_TEXT_BYTES), { stream: true }),
    truncated: true
  }
}

export function TextViewer({ text, fileName }: TextViewerProps): JSX.Element {
  const preview = useMemo(() => textPreview(text), [text])

  return (
    <div className="file-text" role="region" aria-label={`${fileName} 텍스트 내용`}>
      {preview.truncated && (
        <p className="file-text__notice" role="status">
          파일이 커서 앞부분 2MB만 표시합니다.
        </p>
      )}
      <pre className="file-text__content">{preview.text}</pre>
    </div>
  )
}
