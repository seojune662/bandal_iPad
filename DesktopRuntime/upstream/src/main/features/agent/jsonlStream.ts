/**
 * JSONL parsing over a child-process stdout stream, plus a small stderr ring
 * buffer. Tolerates occasional garbage lines; gives up (and reports) after too
 * many consecutive malformed lines so a wedged/foreign process is surfaced as
 * `malformed-output` instead of hanging silently.
 */

import { createInterface, type Interface } from 'node:readline'
import type { Readable } from 'node:stream'

export const DEFAULT_MAX_LINE_BYTES = 10 * 1024 * 1024
export const DEFAULT_MAX_CONSECUTIVE_MALFORMED = 5
export const DEFAULT_STDERR_RING_LINES = 100

export interface JsonlStreamOptions {
  /** Called with each successfully parsed JSON value. */
  onJson: (value: unknown) => void
  /** Called once when the consecutive-malformed limit is hit. */
  onMalformedLimit: (detail: string) => void
  /** Lines longer than this count as malformed. Default 10MB. */
  maxLineBytes?: number
  /** Consecutive malformed lines before onMalformedLimit. Default 5. */
  maxConsecutiveMalformed?: number
}

export interface JsonlStream {
  dispose(): void
}

/** Attaches a line-oriented JSON parser to a readable (child stdout). */
export function attachJsonlStream(
  input: Readable,
  options: JsonlStreamOptions
): JsonlStream {
  const maxLineBytes = options.maxLineBytes ?? DEFAULT_MAX_LINE_BYTES
  const maxMalformed =
    options.maxConsecutiveMalformed ?? DEFAULT_MAX_CONSECUTIVE_MALFORMED

  let consecutiveMalformed = 0
  let limitReported = false
  let disposed = false

  const reader: Interface = createInterface({ input, crlfDelay: Infinity })

  const reportMalformed = (detail: string): void => {
    consecutiveMalformed += 1
    if (consecutiveMalformed >= maxMalformed && !limitReported) {
      limitReported = true
      options.onMalformedLimit(detail)
    }
  }

  reader.on('line', (line) => {
    if (disposed || limitReported) {
      return
    }
    const trimmed = line.trim()
    if (trimmed === '') {
      return
    }
    if (Buffer.byteLength(trimmed, 'utf8') > maxLineBytes) {
      reportMalformed(`line exceeds ${maxLineBytes} bytes`)
      return
    }
    try {
      const value: unknown = JSON.parse(trimmed)
      consecutiveMalformed = 0
      options.onJson(value)
    } catch {
      reportMalformed(`unparseable line: ${trimmed.slice(0, 200)}`)
    }
  })

  return {
    dispose: () => {
      disposed = true
      reader.close()
    }
  }
}

export interface StderrRing {
  push(chunk: Buffer | string): void
  /** Last lines joined with newlines (most recent last). */
  tail(): string
}

/** Keeps the last `capacity` stderr lines for crash diagnostics. */
export function createStderrRing(
  capacity: number = DEFAULT_STDERR_RING_LINES
): StderrRing {
  let lines: string[] = []
  let partial = ''

  return {
    push: (chunk) => {
      const text = partial + chunk.toString()
      const parts = text.split('\n')
      partial = parts.pop() ?? ''
      const complete = parts.filter((line) => line.trim() !== '')
      if (complete.length > 0) {
        lines = [...lines, ...complete].slice(-capacity)
      }
    },
    tail: () => {
      const all = partial === '' ? lines : [...lines, partial]
      return all.slice(-capacity).join('\n')
    }
  }
}
