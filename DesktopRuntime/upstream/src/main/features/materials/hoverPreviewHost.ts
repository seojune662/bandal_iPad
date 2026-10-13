import { extractMaterialHoverPreview, unavailablePreview, type HoverExtractionInput } from './hoverPreviewExtract'

process.parentPort?.on('message', ({ data }: { data: { id: number; input: HoverExtractionInput } }) => {
  void extractMaterialHoverPreview(data.input).then(
    content => process.parentPort?.postMessage({ id: data.id, content }),
    () => process.parentPort?.postMessage({ id: data.id, content: unavailablePreview('unreadable', '내용 미리보기를 불러오지 못했어요.') })
  )
})
