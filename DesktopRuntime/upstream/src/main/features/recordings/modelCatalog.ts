import type { SpeechModelId } from '../../../shared/recording'

interface ModelFile {
  name: string
  bytes: number
  sha256: string
  url?: string
}
export interface SpeechModel {
  id: SpeechModelId
  name: string
  description: string
  repo: string
  revision: string
  files: ModelFile[]
}
// Sizes and SHA-256 come from the publisher's LFS metadata (tokens hashed
// separately). Immutable revisions prevent an upstream change during install.
export const SPEECH_MODELS: SpeechModel[] = [
  {
    id: 'whisper-large-v3-turbo',
    name: 'Whisper large-v3-turbo',
    description:
      '기본 강의 모델 · 한국어 전사 · FP16 원본 정밀도. Apple Silicon에서 Metal GPU 가속. 짧은 구간을 재분석해 임시 자막을 표시하고 발화가 끝나면 확정합니다.',
    repo: 'ggerganov/whisper.cpp',
    revision: '5359861c739e955e79d9a303bcbc70fb988958b1',
    files: [
      {
        name: 'ggml-large-v3-turbo.bin',
        bytes: 1624555275,
        sha256: '1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69'
      },
      {
        name: 'silero_vad.onnx',
        bytes: 643854,
        sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
        url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx'
      }
    ]
  },
  {
    id: 'zipformer-ko',
    name: 'Zipformer Korean',
    description:
      '한국어 · 실시간 스트리밍. 작은 모델로 자막을 빠르게 표시합니다. 영어 전문용어와 문장부호는 약할 수 있어요.',
    repo: 'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16',
    revision: 'ba6078bca4daf3f0dd37f79d0ab505af71df14a6',
    files: [
      {
        name: 'encoder-epoch-99-avg-1.int8.onnx',
        bytes: 126968852,
        sha256: '8d0b1aa24fbedd4e3948564ab7facd151b8ce9b0c48fc987c541de2de3af5697'
      },
      {
        name: 'decoder-epoch-99-avg-1.int8.onnx',
        bytes: 2844692,
        sha256: '68ea197936aabd249f38b53a87c775422bca64428ad4427d0e6e8092593e71fb'
      },
      {
        name: 'joiner-epoch-99-avg-1.int8.onnx',
        bytes: 2581421,
        sha256: '128b80a66a1f718488af8560f9d15895109b99ff3e573f0a0130e03774ef1ced'
      },
      {
        name: 'tokens.txt',
        bytes: 60246,
        sha256: '016bdf0965029263b7ad01b742366ee542ef0bef38261510e8176ff6f2e9e668'
      }
    ]
  },
  {
    id: 'sensevoice',
    name: 'SenseVoice',
    description:
      '한국어 · 영어 · 일본어 · 중국어 · 광둥어. 발화 구간이 끝나면 자막을 표시합니다. 언어를 자동 감지합니다.',
    repo: 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    revision: '2365baeacb507f821a0c8120fcee3d484dba7a07',
    files: [
      {
        name: 'model.int8.onnx',
        bytes: 239233841,
        sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51'
      },
      {
        name: 'tokens.txt',
        bytes: 315894,
        sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc'
      },
      {
        name: 'silero_vad.onnx',
        bytes: 643854,
        sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
        url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx'
      }
    ]
  }
]
export function speechModel(id: unknown): SpeechModel {
  const model = SPEECH_MODELS.find((entry) => entry.id === id)
  if (!model) throw new Error('지원하지 않는 음성 모델입니다.')
  return model
}
