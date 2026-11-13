Hello,

Version 1.4.3 is a bug-fix release. It fixes a freeze on 11-inch iPads running iPadOS 27: with a PDF open between the left sidebar and the right panel, the pen palette above the page could loop on its own layout and stop the app. The palette looks and works as in 1.4.2.

No new features, in-app purchases, permissions or external services. Everything in the 1.4.2 notes still applies; the short version follows.

Unchanged from 1.4.2
- AI goes through our server to Anthropic or OpenAI after a per-provider consent sheet (5.1.2(i)); the server stores no questions, materials or answers.
- Plans: Free, Bandal Plus, Bandal Pro and AI Credit (consumable) in Settings > 구독·사용량 (Plan & usage). Restore Purchases is on the plan screen.
- Sync is optional (the user's own iCloud or Google Drive). Recordings stay on the device. In-app browser (17+). Account deletion: Settings > 계정 > 계정 삭제 (Delete Account).

External services
- Bandal server (auth.bandal.io / Supabase): account (ID, email, name, nickname); AI usage records; App Store transaction status; the invite code and which account invited which (account IDs only); the school directory.
- Anthropic, OpenAI: AI requests after consent. Anthropic also runs the school website search (school name, country and app language only).
- Apple: Sign in with Apple, In-App Purchase. Google: Sign in with Google, Google Drive API for sync.
- No analytics, advertising or crash reporting. No device identifiers are collected.

Not distributed in the EU or China mainland.