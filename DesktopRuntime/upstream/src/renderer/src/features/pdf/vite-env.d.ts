/**
 * Minimal Vite asset-import typing for this feature (the project does not
 * reference vite/client globally). Covers the pdf.js worker `?url` import.
 */

declare module '*?url' {
  const url: string
  export default url
}
