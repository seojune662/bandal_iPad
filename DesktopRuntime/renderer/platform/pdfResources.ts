/** PDF.js uses these local resources for CID fonts without ToUnicode maps,
 * unembedded standard fonts and image decoders. WK custom schemes use its DOM
 * factories (XHR) instead of worker fetch, which only accepts HTTP(S) URLs. */
export const pdfResourceOptions = {
  cMapUrl: new URL('./pdfjs/cmaps/', document.baseURI).href,
  cMapPacked: true,
  standardFontDataUrl: new URL('./pdfjs/standard_fonts/', document.baseURI).href,
  wasmUrl: new URL('./pdfjs/wasm/', document.baseURI).href,
  useWorkerFetch: false
} as const
