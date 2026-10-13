// Audio runs at the AudioContext's 16 kHz. Chromium performs device-rate
// conversion with its resampler; no renderer timers or per-frame IPC.
class RecordingPCM extends AudioWorkletProcessor {
  constructor() {
    super()
    this.buffer = new Int16Array(8000)
    this.used = 0
    this.energy = 0
    this.paused = false
    this.port.onmessage = ({ data }) => {
      if (data === 'pause') {
        this.paused = true
        this.flush()
        this.port.postMessage({ flushed: true })
      }
      if (data === 'resume') this.paused = false
    }
  }
  flush() {
    if (!this.used) return
    const pcm = this.buffer.slice(0, this.used)
    this.port.postMessage({ pcm: pcm.buffer, level: Math.sqrt(this.energy / this.used) }, [
      pcm.buffer
    ])
    this.used = 0
    this.energy = 0
  }
  process(inputs) {
    if (this.paused) return true
    const channels = inputs[0]
    if (!channels || !channels[0]) return true
    for (let i = 0; i < channels[0].length; i++) {
      let sample = 0
      for (const channel of channels) sample += channel[i] ?? 0
      sample = Math.max(-1, Math.min(1, sample / channels.length))
      this.energy += sample * sample
      this.buffer[this.used++] = Math.round(sample * (sample < 0 ? 32768 : 32767))
      if (this.used === this.buffer.length) this.flush()
    }
    return true
  }
}
registerProcessor('bandal-recording-pcm', RecordingPCM)
