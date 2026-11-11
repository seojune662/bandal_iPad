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
| 심사용 스크린샷 | 구독 4개: 플랜 선택(연간, Pro 선택) / 충전팩: 충전 팝오버. `StoreScreensUITests`가 2064×2752 PNG로 남긴다 (ASC KOR 가격 픽스처). |
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

1. 로그아웃 상태에서 AI 보내기·퀴즈·플래시카드·예상문제 생성 → 보내기 버튼 위에 "AI를 쓰려면 로그인이 필요해요" 팝오버(설정으로 이동하지 않음). Apple로 로그인 → 같은 AI 패널로 돌아오고 입력 중이던 글이 그대로 있다.
2. 로그인 → 보내기 → Anthropic 동의 시트 → 동의 → 답이 스트리밍되고 설정 › 구독·사용량에 사용량 %.
3. 다른 계정으로 바꿔 보내기 → 그 계정의 동의 시트가 다시 뜬다.
4. 무료 예산 소진 → 플랜 선택(전체 화면, 연간, Pro 카드 선택됨).
5. 샌드박스 Plus 구매 → 설정 › 구독·사용량 "플러스 이용 중", AI %가 플러스 기준으로 바뀐다.
6. Plus 예산 소진 → 플랜 선택(Pro 카드 선택됨, Plus 카드 "현재 플랜") → Pro "7일 무료로 시작" 또는 "업그레이드" → 토스트 "Pro 시작됐어요" → 즉시 프로 예산.
7. Pro 체험 중 예산 → $0.30. Pro 소진 → 채팅 오류 줄의 "충전"에 충전 팝오버가 이유와 함께 자동으로 뜬다.
8. 충전 팝오버 "₩5,500 충전" → Apple 결제 → "충전했어요", 충전 잔액 반영, 기기를 껐다 켜도 중복 지급 없음.
9. 모델 선택기에서 Sonnet + 높음 → 사용량이 Auto보다 빠르게 닳는다.
10. 플랜 선택 하단 구매 복원, Pro → Plus "변경" → 토스트 "다음 갱신일부터 Plus …으로 바뀌어요" (다음 갱신일 적용).

### 1.4.0 UX (레일·프로필·모델 선택기·설정)

11. 레일: 홈 아래 AI 버튼으로 패널이 열리고 닫힌다. AI 패널 가장자리 "AI" 탭과 레일 ? 버튼이 없다.
12. 프로필 (로그아웃): 레일 하단 프로필 → 그 자리에서 Apple/Google 로그인. (로그인): 이메일(회색), "이름 · 플랜"(무료/Plus/Pro/Pro 체험), 설정 · 사용량 · 도움말(화면 도우미 · 문서 · 문의하기) · 플랜 보기 · 로그아웃. 사용량 → 설정 › 구독, 플랜 보기 → 페이월.
13. 모델 선택: 입력창 아래 "Auto ▾" → 검색(자동 포커스) · Auto · Anthropic/OpenAI 그룹 · 배지 · Effort(Auto는 "low 고정") · "이번 달 AI 사용량 N%"·자세히. 모델을 고르면 바로 닫히고 필이 "Sonnet 5.5 · medium"으로 바뀐다. 새 대화는 마지막 선택으로 시작, 이전 대화는 자기 모델 유지.
14. 하드웨어 키보드: 과목·폴더·노트 이름 변경 중 Esc → 원래 이름, Enter → 확정, 다른 곳 탭 → 확정. 팝오버는 Esc·바깥 탭으로 닫힌다.
15. 확인 팝오버: 과목 보관·자료 삭제·대화 삭제가 누른 행에 붙어 뜬다. PDF 원문 메모·댓글은 닫으면 저장되고 Esc는 취소.
16. 다크 모드에서 팝오버·토스트·모델 선택기 색이 읽힌다.
17. 설정: 왼쪽 목록이 일반 · 화면 · 계정 · 구독·사용량 · AI · 동기화 · 통합 7개. 알림·단축키·고급은 일반, 학교는 계정, 달력·브라우저는 통합 안에 있다. AI는 로그아웃이면 상단 배너 + 로그인, 공정 이용 안내 링크가 bandal.io/ko/docs/ai-fair-use를 연다. 계정 삭제·로그아웃·동기화 끄기·캐시 비우기는 누른 버튼에 확인 팝오버.
18. 도움말 › 문의하기가 메일(hi@bandal.io)을 연다.
19. 충전 팝오버 가격 = Apple 결제 시트 가격 (₩5,500). 상품을 불러오기 전엔 버튼이 비어 있고 비활성, 비행기 모드에선 "불러오지 못했어요" + 다시 시도.
20. 플랜 선택 3카드 가격 = Apple 결제 시트 가격 (월간 Plus ₩1,500 · Pro ₩4,500 / 연간 Plus ₩11,000 · Pro ₩29,000), 배지 "최대 46% 할인". 다르면 기기 App Store 계정(설정 › App Store › 샌드박스 계정 포함)의 국가부터 확인.
21. 모델 선택은 입력창 "Auto ▾" 팝오버로만 열린다. 큰 제목 + 취소/적용 시트("AI 선택")가 어디에도 없다. 설정 왼쪽 아래 버전이 1.4.0 (19)인지 먼저 확인 (빌드 18 바이너리에는 "AI 선택" 시트가 없다).

## 6. 알려진 사항

- 설정 › 구독·사용량의 "disk I/O error"는 UI 테스트 전용 재설정이 열린 DB를 지우던 문제였다(#42에서 수정, 기기에서는 나지 않음).
- 친구 초대는 1.4.1. 루틴(새 툴)은 범위 밖, 계량(작업 상한)만 들어 있다.
