# 1.4.0 출시 체크리스트: AI 제공·계량·Pro·AI 충전

스택: #36 (백엔드 계량) → #37 (App Store 검증) → #38 (앱 프록시) → #39 (Pro·충전) → #40 (모델 선택기) → 이 PR (버전·메타데이터).
스펙: Claude Docs "반달 iPad 1.4.0 스펙" (https://claude.ai/artifact/KK5VDZq6HioUPHxJL6TL7D).

## 1. 서버 배포 (Supabase `ukacrkcwiqafwpppshxb`)

migration history가 맞춰져 있지 않으므로 `db push`를 쓰지 않는다 (backend/README.md).

1. `backend/`를 git archive로 scratch 디렉터리에 풀고 거기서 `supabase link --project-ref ukacrkcwiqafwpppshxb`.
2. 이름 충돌 확인: `ai_*`, `ipad_*` 테이블/함수가 라이브에 없어야 한다.
3. `supabase db query --linked -f supabase/migrations/202611060001_ai_metering.sql`, 이어서 `202611060002_ipad_store.sql`.
4. `supabase functions deploy ai-proxy ipad-store ipad-store-notifications --no-verify-jwt` (데스크톱 함수 13개는 건드리지 않는다).
5. Secrets:
   - `APPLE_APP_ID=6824053530`
   - `APPLE_SANDBOX_ALLOWED_USER_IDS=*` (App Review와 TestFlight 테스터가 샌드박스로 산다. TestFlight가 공개 링크가 되면 사용자 ID 목록으로 좁힌다.)
   - `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`: 사용자가 직접 넣는다.
6. 스모크: `curl …/functions/v1/ai-proxy/config`가 401 `SIGN_IN_REQUIRED`를 돌려준다.

## 2. App Store Connect

| 항목 | 값 |
|---|---|
| App Store Server Notifications (V2), 프로덕션·샌드박스 | `https://ukacrkcwiqafwpppshxb.supabase.co/functions/v1/ipad-store-notifications` |
| 구독 레벨 (Bandal Membership) | Pro Monthly 1, Pro Yearly 1, Plus Monthly 2, Plus Yearly 2 |
| 충전팩 | Consumable, Reference `AI Credit`, Product ID `app.bandal.ipad.credit.pack1`, ₩5,500, 표시명 `AI 충전` / `AI Credit`, 설명 `이번 달 AI 사용량을 더합니다. 만료 없음.` / `Adds to this month's AI allowance. Never expires.` |
| 충전팩 지급액 | 서버 `ai_settings.pack_ucents` = $2.00 (스펙 미결 사항의 권장안; SQL 한 줄로 바뀐다) |
| Plus 설명 | `과목과 자료 무제한, AI 사용량 기본` / `Unlimited courses and materials, standard AI allowance` |
| Pro 설명 | `과목과 자료 무제한, AI 사용량 4배` / `Unlimited courses and materials, 4× AI allowance` |
| 심사용 스크린샷 | Pro 두 개: 페이월(업그레이드) / 충전팩: 충전 시트 (실기기에서 캡처) |
| 제출 묶음 | iOS 1.4.0 + Pro Monthly + Pro Yearly + AI Credit |

## 3. 개인정보 라벨 (App Privacy) 변경

1.3까지는 "AI는 사용자 키로 기기에서 직접"이었으므로 라벨에 없었다. 1.4.0부터 추가한다.

| 데이터 유형 | 용도 | 사용자와 연결 | 추적 |
|---|---|---|---|
| 사용자 콘텐츠 › 기타 사용자 콘텐츠 (질문, 첨부, AI가 읽은 자료) | 앱 기능 | 예 (계정으로 보냄) | 아니요 |
| 사용 데이터 › 제품 상호작용 (AI 사용량: 토큰 수·비용·모델) | 앱 기능 | 예 | 아니요 |
| 구입 내역 | 앱 기능 | 예 | 아니요 |

개인정보 처리방침(bandal.io/privacy)에 추가: AI 요청을 Anthropic·OpenAI에 처리 위탁, 반달 서버는 내용을 저장하지 않고 사용량만 기록, App Store 거래 상태를 AI 한도 계산에 사용.

## 4. 심사 메모

`fastlane/metadata/review_information/notes.txt` (3,100자). 데모 계정이 필요 없다는 문장은 뺐다: AI 확인에는 Apple/Google 로그인이 필요하다고 적었다.

## 5. 실기기 확인 (키 등록 후)

1. 로그아웃 상태에서 AI 보내기 → "로그인해 주세요".
2. 로그인 → 보내기 → Anthropic 동의 시트 → 동의 → 답이 스트리밍되고 설정 › 구독에 사용량 %.
3. 다른 계정으로 바꿔 보내기 → 그 계정의 동의 시트가 다시 뜬다.
4. 무료 예산 소진 → 멤버십 페이월(Plus 연간이 위).
5. 샌드박스 Plus 구매 → 설정 › 구독 "플러스 이용 중", AI %가 플러스 기준으로 바뀐다.
6. Plus 예산 소진 → Pro 페이월(+ AI 충전 링크) → Pro 업그레이드 → 즉시 프로 예산.
7. Pro 체험 중 예산 → $0.30, 소진 시 충전 시트에 체험 안내.
8. AI 충전 구매 → 충전 잔액 반영, 기기를 껐다 켜도 중복 지급 없음.
9. 모델 선택기에서 Sonnet + 높음 → 사용량이 Auto보다 빠르게 닳는다.
10. 구매 복원, Pro → Plus 다운그레이드 예약 (다음 갱신일 적용).

## 6. 알려진 사항

- 설정 › 구독에 시뮬레이터에서 "disk I/O error"가 보인다 (`nativeMembership:usage`, 이 스택이 바꾸지 않은 코드). main에서 따로 확인한다.
- 친구 초대는 1.4.1. 루틴(새 툴)은 범위 밖, 계량(작업 상한)만 들어 있다.
