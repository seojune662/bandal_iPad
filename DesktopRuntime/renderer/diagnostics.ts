export type RendererDiagnostic = { errorClass: string; frames: string[]; expression?: string }
export type DiagnosticSource = { filename?: unknown; lineno?: unknown; colno?: unknown }

const classes = new Set(['Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError', 'EvalError', 'URIError', 'AggregateError', 'DOMException'])
const asset = /^bandal-app:\/\/shell\/assets\/([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79}\.(?:js|mjs))$/
const coordinate = (value: unknown): number | undefined => typeof value === 'number' && Number.isInteger(value) && value > 0 && value <= 999_999_999 ? value : undefined
function frame(filename: unknown, line: unknown, column: unknown): string | undefined {
  if (typeof filename !== 'string') return undefined
  const match = asset.exec(filename), row = coordinate(line), col = coordinate(column)
  return match && row !== undefined && col !== undefined ? `${match[1]}:${row}:${col}` : undefined
}
function field(reason: unknown, key: string): unknown {
  try { return reason && typeof reason === 'object' ? (reason as Record<string, unknown>)[key] : undefined } catch { return undefined }
}

/** Only code locations and built-in error metadata may cross the diagnostic
 * bridge. Never send a message, complete stack, function name or document URL.
 */
export function rendererDiagnostic(reason: unknown, source?: DiagnosticSource): RendererDiagnostic {
  const name = field(reason, 'name'), errorClass = typeof name === 'string' && classes.has(name) ? name : 'UnknownError'
  const frames: string[] = [], stack = field(reason, 'stack')
  if (typeof stack === 'string') for (const line of stack.slice(0, 16_384).split('\n').slice(0, 32)) {
    // Safari uses fn@URL:line:column; Chromium wraps the same location in ().
    // Ignore the function label because it can contain user-controlled text.
    const match = /(?:^|[@(\s])(bandal-app:\/\/shell\/assets\/[^\s()]+):(\d+):(\d+)\)?$/.exec(line)
    const value = match && frame(match[1], Number(match[2]), Number(match[3]))
    if (value && !frames.includes(value)) frames.push(value)
    if (frames.length === 5) break
  }
  const fallback = source && frame(source.filename, source.lineno, source.colno)
  if (!frames.length && fallback) frames.push(fallback)
  let expression: string | undefined
  if (errorClass === 'TypeError') {
    const message = field(reason, 'message')
    // WebKit's exact static property-access form. Strings, bracket expressions,
    // call arguments, paths and arbitrary surrounding message text are dropped.
    const match = typeof message === 'string' && /^undefined is not an object \(evaluating '([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*){1,3})'\)$/.exec(message)
    if (match && match[1]!.length <= 64) expression = match[1]
  }
  return { errorClass, frames, ...(expression ? { expression } : {}) }
}
