import React, { useCallback, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { DocxViewer } from './DocxViewer'
import { SheetViewer } from './SheetViewer'
import { HwpViewer } from './HwpViewer'
import { base64, postOffice, type OfficeDocument } from './types'
import './office.css'

declare global { interface Window { bandalOffice: { load(document: OfficeDocument): void } } }

function OfficeApp() {
  const [source, setSource] = useState<OfficeDocument | null>(null)
  const [content, setContent] = useState('')
  const [message, setMessage] = useState('문서를 불러오는 중…')
  const [error, setError] = useState('')
  const [progress, setProgress] = useState<number | null>(null)
  const failure = useCallback(() => setError('문서 내용을 읽지 못했어요. 파일이 손상되었거나 암호로 보호되었는지 확인해 주세요.'), [])

  useEffect(() => {
    window.bandalOffice = { load: document => {
      if (document.version !== 1 || !document.materialID || !document.fileName || !document.extension || typeof document.source !== 'string') throw new Error('Invalid document')
      setSource(document)
    } }
    void postOffice({ version: 1, type: 'ready' }).catch(failure)
    const stopLinks = (event: MouseEvent) => { if ((event.target as Element | null)?.closest('a')) event.preventDefault() }
    document.addEventListener('click', stopLinks)
    return () => document.removeEventListener('click', stopLinks)
  }, [failure])

  useEffect(() => {
    if (!source) return
    const controller = new AbortController()
    let presentation: import('@silurus/ooxml/pptx').PptxPresentation | null = null
    const activeSource = source
    setError(''); setContent(''); setProgress(null); setMessage('문서를 읽는 중…')
    void (async () => {
      const response = await fetch(activeSource.source, { signal: controller.signal })
      if (!response.ok) throw new Error('원본 자료를 읽지 못했어요.')
      const data = await response.arrayBuffer()
      if (data.byteLength > 64 * 1024 * 1024) throw new Error('64 MB 이하의 문서를 열 수 있어요. 큰 문서는 PDF로 가져와 주세요.')
      if (controller.signal.aborted) return
      if (activeSource.extension !== 'pptx') { setContent(base64(new Uint8Array(data))); return }
      setMessage('슬라이드를 해석하는 중…')
      const { PptxPresentation } = await import('@silurus/ooxml/pptx')
      presentation = await PptxPresentation.load(data, {
        mode: 'main', progressiveLayout: true, useGoogleFonts: false,
        resourceLimits: { maxArchiveEntries: 8192, maxArchiveEntryBytes: 128 * 1024 * 1024, maxTotalInflatedBytes: 384 * 1024 * 1024 }
      })
      await presentation.waitUntilLayoutComplete()
      if (controller.signal.aborted) return
      const count = presentation.slideCount
      if (!count || count > 500) throw new Error('1–500쪽의 프레젠테이션을 열 수 있어요.')
      const width = presentation.slideWidth / 12700, height = presentation.slideHeight / 12700
      const pixelWidth = Math.min(2000, Math.max(1200, width * 2))
      for (let index = 0; index < count; index++) {
        if (controller.signal.aborted) return
        setMessage(`필기할 슬라이드를 준비하는 중 · ${index + 1} / ${count}`)
        setProgress(index / count)
        const runs: import('@silurus/ooxml/pptx').PptxTextRunInfo[] = []
        const bitmap = await presentation.renderSlideToBitmap(index, { width: pixelWidth, dpr: 1, onTextRun: run => runs.push(run) })
        const canvas = document.createElement('canvas')
        try {
          if (controller.signal.aborted) return
          canvas.width = bitmap.width; canvas.height = bitmap.height
          const context = canvas.getContext('2d')
          if (!context) throw new Error('슬라이드 이미지 생성 실패')
          context.drawImage(bitmap, 0, 0)
          const scale = width / pixelWidth
          await postOffice({ version: 1, type: 'slide', materialID: activeSource.materialID, index, count, width, height,
            png: canvas.toDataURL('image/png').split(',')[1] ?? '',
            text: runs.map(run => ({ text: run.text, x: (run.shapeX + run.inShapeX) * scale, y: (run.shapeY + run.inShapeY) * scale,
              width: run.w * scale, height: run.h * scale, fontSize: run.fontSize * scale, rotation: run.rotation }))
          })
        } finally { bitmap.close(); canvas.width = 0; canvas.height = 0 }
        await new Promise<void>(resolve => requestAnimationFrame(() => resolve()))
      }
      if (controller.signal.aborted) return
      setMessage('필기 화면을 여는 중…'); setProgress(1)
      await postOffice({ version: 1, type: 'complete', materialID: activeSource.materialID, count })
    })().catch((cause: unknown) => {
      if (controller.signal.aborted) return
      const text = cause instanceof Error ? cause.message : '문서를 열지 못했어요.'
      setError(text)
      void postOffice({ version: 1, type: 'error', materialID: activeSource.materialID, message: text }).catch(() => {})
    }).finally(() => presentation?.destroy())
    return () => { controller.abort(); presentation?.destroy() }
  }, [source])

  if (error) return <div className="file-status error" role="alert">{error}</div>
  if (!source || !content) return <div className="file-status" role="status"><p>{message}</p>{progress !== null && <progress max={1} value={progress} />}</div>
  const props = { base64: content, fileName: source.fileName, onError: failure }
  return <main><header className="document-heading"><strong>{source.fileName}</strong><span>읽기 전용</span></header>
    {source.extension === 'docx' ? <DocxViewer {...props} /> :
      ['hwp', 'hwpx'].includes(source.extension) ? <><p className="notice">본문 텍스트 미리보기 · 서식, 표, 이미지는 포함하지 않습니다.</p><HwpViewer {...props} /></> :
      <SheetViewer content={{ data: content, encoding: 'base64' }} fileName={source.fileName} onError={failure} />}
  </main>
}

createRoot(document.getElementById('root')!).render(<OfficeApp />)
