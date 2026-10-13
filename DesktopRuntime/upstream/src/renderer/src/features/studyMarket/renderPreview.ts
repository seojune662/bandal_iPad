/** Rasterize only the selected page or excerpt; original files stay private. */
export async function renderMarketPreview(source: { mime: string; base64?: string; text?: string }): Promise<string> {
  const canvas = document.createElement('canvas')
  const context = canvas.getContext('2d', { alpha: false })
  if (!context) throw new Error('Preview canvas unavailable')
  if (source.mime === 'application/pdf' && source.base64) {
    const [{ pdfjs }, { configurePdfWorker }] = await Promise.all([import('react-pdf'), import('../pdf/pdfWorker')])
    configurePdfWorker()
    const bytes = Uint8Array.from(atob(source.base64), character => character.charCodeAt(0))
    const pdf = await pdfjs.getDocument({ data: bytes, isEvalSupported: false }).promise
    try {
      const page = await pdf.getPage(1)
      const natural = page.getViewport({ scale: 1 })
      const viewport = page.getViewport({ scale: 1200 / Math.max(natural.width, natural.height) })
      canvas.width = Math.ceil(viewport.width)
      canvas.height = Math.ceil(viewport.height)
      await page.render({ canvas, canvasContext: context, viewport }).promise
    } finally { await pdf.destroy() }
  } else if (source.mime.startsWith('image/') && source.base64) {
    const image = new Image()
    image.src = `data:${source.mime};base64,${source.base64}`
    await image.decode()
    const scale = Math.min(1, 1200 / Math.max(image.naturalWidth, image.naturalHeight))
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale))
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale))
    context.fillStyle = '#ffffff'
    context.fillRect(0, 0, canvas.width, canvas.height)
    context.drawImage(image, 0, 0, canvas.width, canvas.height)
  } else if (source.text) {
    canvas.width = 1000
    canvas.height = 1200
    context.fillStyle = '#ffffff'
    context.fillRect(0, 0, canvas.width, canvas.height)
    context.fillStyle = '#222222'
    context.font = '24px sans-serif'
    let y = 72
    for (const paragraph of source.text.slice(0, 2000).split('\n')) {
      let line = ''
      for (const character of paragraph) {
        if (context.measureText(line + character).width > 880) {
          context.fillText(line, 60, y)
          line = ''
          y += 38
        }
        line += character
        if (y > 1110) break
      }
      if (y > 1110) break
      context.fillText(line, 60, y)
      y += 38
    }
  } else { throw new Error('Preview source unavailable') }
  return canvas.toDataURL('image/png')
}
