Hello,

Version 1.4.2 is a redesign plus on-device handwriting search. No new in-app purchases, permissions or external services; first-run setup, school setup and friend invites work as in 1.4.1. Labels below are Korean (English).

1. New design
- Window chrome, tab strip, note screen, pen palette, menus, settings sheet and AI panel were redrawn. The window edge colour can be changed in Settings > 화면 (Display) > 꾸미기 (Decor) and in the first-run setup.
- Notes: every Markdown format is a button on the note's bar; a new note offers a choice of 종이 (Paper). Folders open as windows in the sidebar. The 학업 보드 (Study Board) shows tasks with reminders.

2. Handwriting search (on device)
- Handwriting in PDFs and notes is recognised on the iPad with Apple's Vision framework and indexed locally. Nothing is sent to a server.
- How to test: write a word with Apple Pencil (or a finger) on a PDF page, wait a few seconds, then type it in the search field "자료·손글씨·대화 검색" (Search materials, handwriting and chats) or, inside the document, "문서에서 찾기" (Find in document, Cmd+F with a keyboard); the matching strokes are highlighted.

Unchanged from 1.4.1
- AI goes through our server to Anthropic or OpenAI after a per-provider consent sheet (5.1.2(i)); the server stores no questions, materials or answers.
- Plans: Free, Bandal Plus, Bandal Pro and AI Credit (consumable) in Settings > 구독·사용량 (Plan & usage). Restore Purchases is on the plan screen.
- Sync is optional (the user's own iCloud or Google Drive). Recordings stay on the device. In-app browser (17+). Account deletion: Settings > 계정 > 계정 삭제 (Delete Account).

External services
- Bandal server (auth.bandal.io / Supabase): account (ID, email, name, nickname); AI usage records; App Store transaction status; the invite code and which account invited which (account IDs only); the school directory.
- Anthropic, OpenAI: AI requests after consent. Anthropic also runs the school website search (school name, country and app language only).
- Apple: Sign in with Apple, In-App Purchase. Google: Sign in with Google, Google Drive API for sync.
- No analytics, advertising or crash reporting. No device identifiers are collected.

Not distributed in the EU or China mainland.