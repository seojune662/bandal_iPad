interface QuitEvent {
  preventDefault(): void
}

/** Keeps every quit continuation behind the same pending IPC drain. */
export function createQuitDrain(resumeQuit: () => void, delayMs: number): {
  beforeQuit(event: QuitEvent): void
  reset(): void
} {
  let drained = false
  let generation = 0
  let timer: ReturnType<typeof setTimeout> | undefined

  return {
    beforeQuit(event) {
      if (drained) return
      event.preventDefault()
      if (timer !== undefined) return
      const requestedGeneration = generation
      timer = setTimeout(() => {
        timer = undefined
        if (requestedGeneration !== generation) return
        drained = true
        resumeQuit()
      }, delayMs)
    },
    reset() {
      generation++
      clearTimeout(timer)
      timer = undefined
      drained = false
    }
  }
}
