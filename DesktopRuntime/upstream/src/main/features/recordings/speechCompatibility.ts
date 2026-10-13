import { release } from 'node:os'
import type { SpeechModelId } from '../../../shared/recording'

export function speechUnavailableReason(
  modelId: SpeechModelId,
  platform: NodeJS.Platform = process.platform,
  kernelVersion = release()
): string | undefined {
  // Verified in both shipped Mach-O binaries (LC_BUILD_VERSION minos 15.0).
  // Do not raise the entire app's minimum OS or silently switch the model.
  if (
    modelId === 'whisper-large-v3-turbo' &&
    platform === 'darwin' &&
    Number(kernelVersion.split('.')[0]) < 24
  )
    return '이 Whisper 실행기는 macOS 15 이상이 필요합니다. 시스템 업데이트 후 사용할 수 있어요.'
  return undefined
}
