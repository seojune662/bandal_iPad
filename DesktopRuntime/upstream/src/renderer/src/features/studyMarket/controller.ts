export const OPEN_STUDY_MARKET_SELL_EVENT = 'bandal:study-market-sell'

export interface StudyMarketSellIntent {
  courseId: string
  relPath?: string
}

let pendingIntent: StudyMarketSellIntent | null = null

/** Keep the intent until the marketplace mounts; navigation may be lazy. */
export function openStudyMarketSell(intent: StudyMarketSellIntent): void {
  pendingIntent = intent
  window.dispatchEvent(new Event('bandal:open-study-market'))
  window.dispatchEvent(new CustomEvent(OPEN_STUDY_MARKET_SELL_EVENT, { detail: intent }))
}

export function takeStudyMarketSellIntent(): StudyMarketSellIntent | null {
  const intent = pendingIntent
  pendingIntent = null
  return intent
}
