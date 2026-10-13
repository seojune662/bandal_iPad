import type { SupabaseClient } from '@supabase/supabase-js'
import type {
  IpcRequest,
  IpcResponse
} from '../../../shared/ipc/contract'
import {
  createRateGuard,
  type RateGuard,
  type RateRule
} from './rateGuard'

export const FEEDBACK_RATE_ACTION = 'feedback:send'
export const FEEDBACK_BODY_LIMIT = 4_000
export const FEEDBACK_RATE_RULE = {
  limit: 3,
  windowMs: 60_000
} satisfies RateRule

export type FeedbackRequest = IpcRequest<'feedback:send'>
export type FeedbackResult = IpcResponse<'feedback:send'>

export interface FeedbackService {
  send(req: FeedbackRequest): Promise<FeedbackResult>
}

export interface FeedbackServiceDeps {
  getClient(): SupabaseClient | null
  rateGuard: Pick<RateGuard, 'take'>
  appVersion: string
  platform: string
  getPalette(): string
}

/** Builds the service-specific local guard used by the feedback IPC runtime. */
export function createFeedbackRateGuard(): RateGuard {
  return createRateGuard({
    rules: { [FEEDBACK_RATE_ACTION]: FEEDBACK_RATE_RULE }
  })
}

function isRemoteRateLimit(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false
  const record = error as Record<string, unknown>
  return record['code'] === 'P0001' && record['message'] === 'rate_limited'
}

/**
 * Records only the failure class. The feedback body and remote error object
 * are deliberately excluded because both may contain user-authored content.
 */
function logUnavailable(): void {
  console.error('[feedback] submit_feedback unavailable')
}

export function createFeedbackService(
  deps: FeedbackServiceDeps
): FeedbackService {
  return {
    async send(req) {
      const client = deps.getClient()
      if (client === null) return { ok: false, reason: 'unavailable' }

      const decision = deps.rateGuard.take(FEEDBACK_RATE_ACTION)
      if (!decision.allowed) return { ok: false, reason: 'rate-limited' }

      try {
        const { error } = await client.rpc('submit_feedback', {
          p_kind: req.kind,
          p_body: req.body.slice(0, FEEDBACK_BODY_LIMIT),
          p_app_version: req.includeAppInfo ? deps.appVersion : null,
          p_os: req.includeAppInfo ? deps.platform : null,
          p_palette: req.includeAppInfo ? deps.getPalette() : null
        })

        if (error === null) return { ok: true }
        if (isRemoteRateLimit(error)) {
          return { ok: false, reason: 'rate-limited' }
        }

        logUnavailable()
        return { ok: false, reason: 'unavailable' }
      } catch (error) {
        if (isRemoteRateLimit(error)) {
          return { ok: false, reason: 'rate-limited' }
        }
        logUnavailable()
        return { ok: false, reason: 'unavailable' }
      }
    }
  }
}
