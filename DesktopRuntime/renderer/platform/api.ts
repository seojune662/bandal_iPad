export function nativeAIRequest(channel: 'agent:apiKey' | 'agent:setApiKey', request: { provider: string; key?: string | null }): Promise<any> {
  return (window.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>)(channel, request)
}
