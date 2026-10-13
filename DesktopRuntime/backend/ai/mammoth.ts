import * as module from 'mammoth/mammoth.browser.js'
const mammoth = (module as any).default ?? module
export async function extractRawText(input: { buffer: Uint8Array }) {
  const bytes = input.buffer
  return mammoth.extractRawText({ arrayBuffer: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) })
}
export default { extractRawText }
