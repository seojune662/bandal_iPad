import { randomUUID } from 'node:crypto'
import {
  closeSync,
  existsSync,
  fsyncSync,
  ftruncateSync,
  mkdirSync,
  openSync,
  readSync,
  statSync,
  writeSync
} from 'node:fs'
import { dirname, extname } from 'node:path'
import type { Database } from 'better-sqlite3'
import type {
  RecordingAnchor,
  RecordingDetail,
  RecordingSession,
  SpeechModelId,
  TranscriptSegment
} from '../../../shared/recording'
import { RECORDING_SAMPLE_RATE, recordingTime } from '../../../shared/recording'
import { requireInt, requireNonEmptyString, resolveInsideReal } from '../../db/validate'
import { speechModel } from './modelCatalog'

// Standard PCM WAV, updated after every accepted chunk. Recovery derives the
// length from the file, not the possibly stale RIFF header or SQLite cursor.
export function wavHeader(samples: number): Buffer {
  const result = Buffer.alloc(44)
  result.write('RIFF', 0)
  result.writeUInt32LE(36 + samples * 2, 4)
  result.write('WAVEfmt ', 8)
  result.writeUInt32LE(16, 16)
  result.writeUInt16LE(1, 20)
  result.writeUInt16LE(1, 22)
  result.writeUInt32LE(RECORDING_SAMPLE_RATE, 24)
  result.writeUInt32LE(RECORDING_SAMPLE_RATE * 2, 28)
  result.writeUInt16LE(2, 32)
  result.writeUInt16LE(16, 34)
  result.write('data', 36)
  result.writeUInt32LE(samples * 2, 40)
  return result
}
function writeAll(fd: number, data: Buffer, position: number): void {
  let offset = 0
  while (offset < data.length) {
    const count = writeSync(fd, data, offset, data.length - offset, position + offset)
    if (count === 0) throw new Error('녹음 파일을 저장하지 못했습니다.')
    offset += count
  }
}
export function createRecordingRepo(db: Database, getFolder: (id: string) => string, onCreated?: (session: RecordingSession) => void) {
  function get(id: string): RecordingSession {
    requireNonEmptyString(id, 'id')
    const row = db.prepare('SELECT payload FROM recording_sessions WHERE id = ?').get(id) as
      | { payload: string }
      | undefined
    if (!row) throw new Error('녹음을 찾을 수 없습니다.')
    return JSON.parse(row.payload) as RecordingSession
  }
  function save(session: RecordingSession): RecordingSession {
    db.prepare('UPDATE recording_sessions SET payload = ? WHERE id = ?').run(
      JSON.stringify(session),
      session.id
    )
    return session
  }
  function audioPath(session: RecordingSession): string {
    return resolveInsideReal(getFolder(session.courseId), session.audioRelPath)
  }
  function list(courseId: string): RecordingSession[] {
    getFolder(courseId)
    return (
      db
        .prepare(
          'SELECT payload FROM recording_sessions WHERE course_id = ? ORDER BY created_at DESC LIMIT 200'
        )
        .all(courseId) as { payload: string }[]
    ).map((row) => JSON.parse(row.payload) as RecordingSession)
  }
  function create(courseId: string, title: string, modelId: SpeechModelId): RecordingSession {
    speechModel(modelId)
    requireNonEmptyString(title, 'title')
    const id = randomUUID()
    const session: RecordingSession = {
      id,
      courseId,
      title: title.trim().slice(0, 160),
      modelId,
      createdAt: new Date().toISOString(),
      status: 'ready',
      audioRelPath: `녹음/${id}/audio.wav`,
      samples: 0,
      transcribedSamples: 0,
      nextSequence: 0,
      error: null
    }
    const path = audioPath(session)
    mkdirSync(dirname(path), { recursive: true })
    const fd = openSync(path, 'wx', 0o600)
    try {
      writeAll(fd, wavHeader(0), 0)
      fsyncSync(fd)
    } finally {
      closeSync(fd)
    }
    db.prepare(
      'INSERT INTO recording_sessions(id, course_id, created_at, payload) VALUES(?, ?, ?, ?)'
    ).run(id, courseId, session.createdAt, JSON.stringify(session))
    onCreated?.(session)
    return session
  }
  function append(id: string, sequence: number, pcm: Uint8Array): RecordingSession {
    const session = get(id)
    requireInt(sequence, 'sequence', 0)
    if (
      !(pcm instanceof Uint8Array) ||
      pcm.byteLength === 0 ||
      pcm.byteLength > 32000 ||
      pcm.byteLength % 2 !== 0
    )
      throw new Error('올바르지 않은 오디오 청크입니다.')
    if (session.status !== 'recording') throw new Error('진행 중인 녹음이 아닙니다.')
    // A response may have been lost; an already committed retry is harmless.
    if (sequence < session.nextSequence) return session
    if (sequence !== session.nextSequence)
      throw new Error('오디오 순서가 어긋났습니다. 녹음을 중단하고 저장된 내용을 확인해 주세요.')
    if (session.samples + pcm.byteLength / 2 > 24 * 3600 * RECORDING_SAMPLE_RATE)
      throw new Error('한 녹음의 최대 길이는 24시간입니다. 새 녹음을 시작해 주세요.')
    const fd = openSync(audioPath(session), 'r+')
    try {
      const nextSamples = session.samples + pcm.byteLength / 2
      writeAll(
        fd,
        Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength),
        44 + session.samples * 2
      )
      writeAll(fd, wavHeader(nextSamples), 0)
      // Acknowledge only durable audio. SQLite metadata can be recovered from
      // file length if the app exits between this fsync and the DB update.
      fsyncSync(fd)
      session.samples = nextSamples
      session.nextSequence += 1
      return save(session)
    } finally {
      closeSync(fd)
    }
  }
  function segments(id: string, afterId = 0): TranscriptSegment[] {
    requireInt(afterId, 'afterId', 0)
    return db
      .prepare(
        `SELECT id, session_id AS sessionId, start_sample AS startSample,
      end_sample AS endSample, text FROM recording_segments WHERE session_id = ? AND id > ? ORDER BY id LIMIT 200`
      )
      .all(id, afterId) as TranscriptSegment[]
  }
  function addSegment(
    id: string,
    startSample: number,
    endSample: number,
    text: string
  ): TranscriptSegment {
    const info = db
      .prepare(
        'INSERT INTO recording_segments(session_id,start_sample,end_sample,text) VALUES(?,?,?,?)'
      )
      .run(id, startSample, endSample, text)
    return { id: Number(info.lastInsertRowid), sessionId: id, startSample, endSample, text }
  }
  function anchors(id: string): RecordingAnchor[] {
    return (
      db
        .prepare(
          'SELECT payload FROM recording_anchors WHERE session_id = ? ORDER BY rowid LIMIT 1000'
        )
        .all(id) as { payload: string }[]
    ).map((row) => JSON.parse(row.payload) as RecordingAnchor)
  }
  function anchor(
    id: string,
    label: string,
    relPath?: string,
    page?: number,
    sample?: number
  ): RecordingAnchor {
    const session = get(id)
    requireNonEmptyString(label, 'label')
    if (anchors(id).length >= 1000)
      throw new Error('한 녹음에 최대 1,000개의 표시를 저장할 수 있습니다.')
    if (relPath !== undefined) {
      if (!['.pdf', '.md'].includes(extname(relPath).toLowerCase()))
        throw new Error('PDF 또는 마크다운을 선택해 주세요.')
      if (!existsSync(resolveInsideReal(getFolder(session.courseId), relPath)))
        throw new Error('연결할 자료를 찾을 수 없습니다.')
    }
    if (page !== undefined) requireInt(page, 'page', 1)
    if (sample !== undefined) requireInt(sample, 'sample', 0)
    const value: RecordingAnchor = {
      id: randomUUID(),
      sample: Math.min(sample ?? session.samples, session.samples),
      label: label.slice(0, 300),
      relPath: relPath ?? null,
      page: page ?? null
    }
    db.prepare('INSERT INTO recording_anchors(id,session_id,payload) VALUES(?,?,?)').run(
      value.id,
      id,
      JSON.stringify(value)
    )
    return value
  }
  function read(id: string, afterId?: number): RecordingDetail {
    const page =
      afterId !== undefined
        ? segments(id, afterId)
        : (
            db
              .prepare(
                `SELECT id, session_id AS sessionId, start_sample AS startSample,
      end_sample AS endSample, text FROM recording_segments WHERE session_id = ? ORDER BY id DESC LIMIT 200`
              )
              .all(id) as TranscriptSegment[]
          ).reverse()
    return { session: get(id), segments: page, anchors: anchors(id) }
  }
  function recover(): void {
    const rows = db.prepare('SELECT payload FROM recording_sessions').all() as { payload: string }[]
    for (const row of rows) {
      const session = JSON.parse(row.payload) as RecordingSession
      if (!['recording', 'paused', 'processing', 'interrupted'].includes(session.status)) continue
      session.status = 'interrupted'
      session.error ??=
        '녹음이 중단되었습니다. 저장된 음성을 다시 듣거나 자막을 다시 생성할 수 있어요.'
      try {
        const path = audioPath(session)
        const size = statSync(path).size
        if (size < 44) throw new Error('녹음 파일의 헤더가 손상되었습니다.')
        session.samples = Math.floor((size - 44) / 2)
        const fd = openSync(path, 'r+')
        try {
          ftruncateSync(fd, 44 + session.samples * 2)
          writeAll(fd, wavHeader(session.samples), 0)
          fsyncSync(fd)
        } finally {
          closeSync(fd)
        }
      } catch {
        session.error = '원음 파일을 찾거나 복구하지 못했습니다. 과목 폴더 연결을 확인해 주세요.'
      }
      save(session)
    }
  }
  function readAudio(session: RecordingSession, from: number, count: number): Float32Array {
    const fd = openSync(audioPath(session), 'r')
    try {
      const bytes = Buffer.alloc(Math.min(count, session.samples - from) * 2)
      let offset = 0
      while (offset < bytes.length) {
        const n = readSync(fd, bytes, offset, bytes.length - offset, 44 + from * 2 + offset)
        if (n === 0) throw new Error('녹음 파일이 예상보다 짧습니다.')
        offset += n
      }
      return Float32Array.from(
        { length: bytes.length / 2 },
        (_, i) => bytes.readInt16LE(i * 2) / 32768
      )
    } finally {
      closeSync(fd)
    }
  }
  function markdown(id: string): string {
    const session = get(id)
    const lines = [
      `# ${session.title.replace(/[\r\n]/g, ' ')}`,
      '',
      `${session.createdAt.slice(0, 10)} · ${recordingTime(session.samples)} · ${speechModel(session.modelId).name}`,
      '',
      `[녹음 듣기](${session.audioRelPath.split('/').map(encodeURIComponent).join('/')})`,
      ''
    ]
    for (const mark of anchors(id))
      lines.push(
        `- **${recordingTime(mark.sample)}** ${mark.label}${mark.page ? ` · p.${mark.page}` : ''}`,
        ''
      )
    let after = 0
    for (;;) {
      const page = segments(id, after)
      if (page.length === 0) break
      for (const segment of page)
        lines.push(`**${recordingTime(segment.startSample)}** ${segment.text}`, '')
      after = page[page.length - 1]!.id
    }
    return lines.join('\n')
  }
  function repoint(courseId: string, from: string, to: string, isDirectory: boolean): void {
    const replace = (value: string): string =>
      value === from
        ? to
        : isDirectory && value.startsWith(`${from}/`)
          ? to + value.slice(from.length)
          : value
    db.transaction(() => {
      const rows = db
        .prepare('SELECT payload FROM recording_sessions WHERE course_id = ?')
        .all(courseId) as { payload: string }[]
      for (const row of rows) {
        const session = JSON.parse(row.payload) as RecordingSession
        const audioRelPath = replace(session.audioRelPath)
        if (audioRelPath !== session.audioRelPath) save({ ...session, audioRelPath })
        for (const mark of anchors(session.id)) {
          if (mark.relPath === null) continue
          const relPath = replace(mark.relPath)
          if (relPath !== mark.relPath)
            db.prepare('UPDATE recording_anchors SET payload = ? WHERE id = ?').run(
              JSON.stringify({ ...mark, relPath }),
              mark.id
            )
        }
      }
    })()
  }
  return {
    get,
    resolve(courseId: string, relPath: string): RecordingSession | null {
      requireNonEmptyString(relPath, 'relPath')
      resolveInsideReal(getFolder(courseId), relPath)
      const row = db.prepare(
        "SELECT payload FROM recording_sessions WHERE course_id = ? AND json_extract(payload, '$.audioRelPath') = ? LIMIT 1"
      ).get(courseId, relPath.replaceAll('\\', '/')) as { payload: string } | undefined
      return row ? JSON.parse(row.payload) as RecordingSession : null
    },
    save,
    list,
    create,
    append,
    read,
    addSegment,
    anchor,
    recover,
    readAudio,
    markdown,
    repoint,
    resetTranscript(id: string) {
      db.prepare('DELETE FROM recording_segments WHERE session_id = ?').run(id)
      return save({ ...get(id), transcribedSamples: 0, error: null })
    }
  }
}
export type RecordingRepo = ReturnType<typeof createRecordingRepo>
