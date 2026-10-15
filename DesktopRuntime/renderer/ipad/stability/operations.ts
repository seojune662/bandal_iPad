export type OperationCategory = 'unsupported' | 'setup' | 'operation' | 'transport'
export interface OperationFailure {
  code: string
  channel: string
  message: string
  category: OperationCategory
  retryable: boolean
  requestId?: string
}

/** This error remains a rejection. An unavailable action must never look saved. */
export class BandalOperationError extends Error {
  readonly code: string
  readonly channel: string
  readonly category: OperationCategory
  readonly retryable: boolean
  readonly requestId: string | undefined
  constructor(failure: OperationFailure) {
    super(failure.message)
    this.name = 'BandalOperationError'
    this.code = failure.code
    this.channel = failure.channel
    this.category = failure.category
    this.retryable = failure.retryable
    this.requestId = failure.requestId
  }
}

export function decodeOperationFailure(value: unknown, channel: string): BandalOperationError | null {
  if (!value || typeof value !== 'object' || !('__bandalError' in value)) return null
  const failure = (value as { __bandalError?: Partial<OperationFailure> }).__bandalError
  if (!failure || typeof failure.message !== 'string' || typeof failure.code !== 'string') {
    return new BandalOperationError({ code: 'INVALID_NATIVE_REPLY', channel, message: '작업 결과를 확인하지 못했습니다. 저장 상태를 확인한 뒤 다시 시도해 주세요.', category: 'transport', retryable: false })
  }
  return new BandalOperationError({
    message: failure.message, code: failure.code, channel,
    category: ['unsupported', 'setup', 'operation', 'transport'].includes(failure.category ?? '') ? failure.category! : 'operation',
    retryable: failure.retryable === true,
    ...(typeof failure.requestId === 'string' ? { requestId: failure.requestId } : {})
  })
}

export function isOperationError(reason: unknown): reason is BandalOperationError {
  return reason instanceof BandalOperationError || !!reason && typeof reason === 'object' && (reason as { name?: unknown }).name === 'BandalOperationError'
}

export interface OperationNotice { reason: unknown; operation?: string; retry?: () => Promise<unknown> }
export function reportOperationError(reason: unknown, options: Omit<OperationNotice, 'reason'> = {}, target: Window = window): void {
  target.dispatchEvent(new CustomEvent<OperationNotice>('bandal:operation-error', { detail: { reason, ...options } }))
}

/** Background work has no invoke promise to reject. Preserve its failure
 * metadata, but never attach a retry that could replay a completed mutation. */
export function installBackendOperationErrors(target: Window = window): () => void {
  const labels: Record<string, string> = {
    'materials.watch': '자료 변경 감시',
    'learning.pathRecovery': '학습 경로 복구',
    'learning.settle': '학습 결과 저장'
  }
  const record = (value: unknown): Record<string, unknown> => value && typeof value === 'object' ? value as Record<string, unknown> : {}
  return (target.bandal.on as (channel: string, listener: (payload: unknown) => void) => () => void)('backend:error', payload => {
    const event = record(payload)
    const failure = record(event.__bandalError ?? event.error ?? payload)
    const operation = typeof event.operation === 'string' ? event.operation : undefined
    const channel = typeof failure.channel === 'string' ? failure.channel
      : typeof event.channel === 'string' ? event.channel : operation ?? 'backend:error'
    const code = typeof failure.code === 'string' ? failure.code
      : typeof event.code === 'string' ? event.code : 'BACKEND_OPERATION_FAILED'
    const message = typeof failure.message === 'string' ? failure.message
      : typeof event.message === 'string' ? event.message
        : typeof event.error === 'string' ? event.error
          : typeof payload === 'string' ? payload : '백그라운드 작업을 완료하지 못했습니다.'
    const category = ['unsupported', 'setup', 'operation', 'transport'].includes(String(failure.category)) ? failure.category as OperationCategory : 'operation'
    const requestId = typeof failure.requestId === 'string' ? failure.requestId : typeof event.requestId === 'string' ? event.requestId : undefined
    reportOperationError(new BandalOperationError({ message, code, channel, category, retryable: false, ...(requestId ? { requestId } : {}) }),
      operation ? { operation: labels[operation] ?? operation } : {}, target)
  })
}

export type CapabilityState = 'available' | 'requiresSetup' | 'unsupported'
export interface RuntimeCapabilities {
  protocolVersion: 1
  platform: 'ipad'
  channels: string[]
  unavailableChannels: string[]
  surfaceChannels: Record<string, string[]>
  methods: Record<string, { state: CapabilityState; reason?: string }>
  features: Record<string, { state: CapabilityState; reason?: string }>
  readiness: Record<string, { channel: string; requestFields: string[]; scope: 'configuration' }>
}
export type ConfiguredFeature = 'ai' | 'account' | 'appleCalendar' | 'credentials' | 'remoteMCP' | 'nativePDF' | 'mail' | 'legacyPresentation'
export interface FeatureReadiness { state: CapabilityState; reason?: string; scope: 'configuration'; reachability: 'unverified' }
/** These replies establish configuration only. A stored key or earlier MCP
 * test cannot establish current network, quota, authentication or reachability. */
export function featureReadiness(feature: ConfiguredFeature, reply: unknown): FeatureReadiness {
  const value = reply && typeof reply === 'object' ? reply as Record<string, any> : {}
  const result = (state: CapabilityState, reason?: string): FeatureReadiness => ({ state, ...(reason ? { reason } : {}), scope: 'configuration', reachability: 'unverified' })
  switch (feature) {
    case 'ai': return value.installed === false ? result('unsupported', value.reason ?? '이 AI 연결은 지원하지 않습니다.')
      : value.loggedIn === true ? result('available') : result('requiresSetup', value.reason ?? 'AI 제공자의 API 키를 등록해 주세요.')
    case 'account': return value.phase === 'signed-in' ? result('available') : result('requiresSetup', value.phase === 'unconfigured' ? '계정 서버 연결을 설정해 주세요.' : '계정 연결 상태를 확인하고 로그인해 주세요.')
    case 'appleCalendar': return value.supported === false ? result('unsupported', '이 환경에서는 캘린더를 연결할 수 없습니다.')
      : value.connected === true && value.authorization === 'authorized' ? result('available') : result('requiresSetup', 'Apple 캘린더를 연결하고 전체 접근을 허용해 주세요.')
    case 'credentials': return value.state === 'ready' ? result('available') : result('requiresSetup', value.reason ?? '기기의 로그인 저장소를 사용할 수 있는지 확인해 주세요.')
    case 'remoteMCP': return value.availability?.available === true && Array.isArray(value.servers) && value.servers.some((server: any) => server.transport === 'http' && server.enabled === true && server.lastTest?.ok === true)
      ? result('available') : result('requiresSetup', value.availability?.reason ?? 'HTTPS MCP 서버를 등록하고 연결 검사를 마친 뒤 켜 주세요.')
    case 'nativePDF': return value.enabled === true ? result('available')
      : value.development === false ? result('unsupported', '이 빌드에서는 네이티브 PDF 표시를 제공하지 않습니다. 기본 PDF 보기는 계속 사용할 수 있습니다.')
        : result('requiresSetup', '이 빌드의 네이티브 PDF 표시 설정을 확인해 주세요.')
    case 'mail': return value.status === 'connected' ? result('available') : result('requiresSetup', value.status === 'unconfigured' ? '이 빌드에 Google 메일 연결 설정이 필요합니다.' : '메일 계정을 연결하거나 다시 인증해 주세요.')
    case 'legacyPresentation': return value.status === 'ready' ? result('available') : result('requiresSetup', value.message ?? '구형 PPT 변환 서버를 연결해 주세요. PPTX는 기기에서 바로 열 수 있습니다.')
  }
}
export async function getFeatureReadiness(feature: ConfiguredFeature, request: Record<string, unknown> = {}): Promise<FeatureReadiness> {
  const capability = await getCapabilities(), source = capability.readiness?.[feature]
  if (!source) return { state: 'unsupported', reason: '기능 상태를 제공하지 않는 앱 버전입니다.', scope: 'configuration', reachability: 'unverified' }
  const reply = await (window.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>)(source.channel, request)
  return featureReadiness(feature, reply)
}
export async function getCapabilities(): Promise<RuntimeCapabilities> {
  return (window.bandal.invoke as (channel: string, request: unknown) => Promise<RuntimeCapabilities>)('runtime:capabilities', {})
}
