import { Buffer } from './shims/buffer'
import { native } from './native'
import { wavHeader } from '../upstream/src/main/features/recordings/recordingRepo'
import { randomUUID } from './shims/crypto'
import { openSync, closeSync, readSync, writeSync, statSync, fsyncSync, existsSync, renameSync, unlinkSync, mkdirSync } from './shims/fs'
import { dirname } from './shims/path'

/** Native app recordings are float32 mono/16kHz; the desktop repo consumes
 * signed PCM16. Preserve the original file, stream a derived compatible WAV,
 * and retain the same sample count so transcript and PDF-anchor times agree. */
export function copyLegacyRecording(source: string, target: string): number {
  const input = openSync(source, 'r'), header = Buffer.alloc(44)
  let output: number | undefined, temporary: string | undefined
  try {
    if (readSync(input, header, 0, 44, 0) !== 44 || header.toString('utf8', 0, 4) !== 'RIFF' || header.toString('utf8', 8, 12) !== 'WAVE' || header.toString('utf8', 12, 16) !== 'fmt ' || header.readUInt32LE(16) !== 16 || header.toString('utf8', 36, 40) !== 'data') throw new Error('Legacy WAV structure is unsupported')
    const format = header.readUInt16LE(20), bits = header.readUInt16LE(34), bytesPerSample = bits / 8
    if (header.readUInt16LE(22) !== 1 || header.readUInt32LE(24) !== 16000 || !((format === 3 && bits === 32) || (format === 1 && bits === 16))) throw new Error('Legacy WAV audio format is unsupported')
    const payloadSize = statSync(source).size - 44
    if (payloadSize < 0 || payloadSize % bytesPerSample !== 0) throw new Error('Legacy WAV has incomplete PCM frames')
    const samples = payloadSize / bytesPerSample
    if (samples * 2 > 0xffffffff - 36) throw new Error('Legacy recording exceeds the WAV size limit')
    mkdirSync(dirname(target), { recursive: true }); temporary = `${target}.${randomUUID()}.tmp`; output = openSync(temporary, 'wx', 0o600)
    const write = (bytes: Uint8Array) => { let offset = 0; while (offset < bytes.length) { const count = writeSync(output!, bytes, offset, bytes.length - offset); if (!count) throw new Error('Recording conversion write failed'); offset += count } }
    write(wavHeader(samples))
    const chunk = Buffer.alloc(64 * 1024)
    let position = 44
    while (position < payloadSize + 44) {
      const length = Math.min(chunk.length, payloadSize + 44 - position), count = readSync(input, chunk, 0, length, position)
      if (count !== length) throw new Error('Legacy recording changed during migration')
      position += count
      if (format === 1) write(chunk.subarray(0, count))
      else {
        const floats = new DataView(chunk.buffer, chunk.byteOffset, count), pcm = Buffer.alloc(count / 2), converted = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength)
        for (let index = 0; index < count / 4; index++) {
          const value = floats.getFloat32(index * 4, true)
          if (!Number.isFinite(value)) throw new Error('Legacy recording contains invalid PCM values')
          converted.setInt16(index * 2, Math.round(Math.max(-1, Math.min(1, value)) * (value < 0 ? 32768 : 32767)), true)
        }
        write(pcm)
      }
    }
    fsyncSync(output); closeSync(output); output = undefined
    if (existsSync(target)) {
      if (native('fs.sha256', { path: target }) !== native('fs.sha256', { path: temporary })) throw new Error('Recording migration target changed; preserved both versions')
      unlinkSync(temporary)
    } else renameSync(temporary, target)
    temporary = undefined
    return samples
  } finally {
    closeSync(input)
    if (output !== undefined) closeSync(output)
    if (temporary && existsSync(temporary)) unlinkSync(temporary)
  }
}
