# AI 충전 첫 제출 체크리스트 (요금제 화면)

브랜치 `seojune662/plans-screen`. 앱의 구독 화면을 **요금제** 한 화면으로 합치고, 그 안에 AI 충전(소모성 `app.bandal.ipad.credit.pack1`)을 넣었다. 충전 상품은 App Store Connect(ASC)에 아직 없다. 이 문서는 소유자가 제출 전에 할 일을 순서대로 적는다. 값은 [app-review-1.4.0.md](app-review-1.4.0.md) 2절과 [backend/README.md](../../backend/README.md) "App Store verification" 그대로다.

## 앱에서 바뀐 것 (심사자가 보는 길)

- 설정 › 구독·사용량의 카드 버튼은 무료든 구독 중이든 **요금제 보기** 하나다. 더 보기의 "플랜 변경 / 구매 복원 / 구독 관리"는 없앴고, 더 보기의 **충전**은 요금제 화면의 AI 충전으로 스크롤해 연다. 프로필 메뉴의 "플랜 보기"도 "요금제 보기"가 됐다.
- 요금제 화면, 위에서 아래로:
  1. 현재 요금제: "반달 플러스 · 연간", 다음 결제일, 무료 체험 남은 날, 해지해 둔 경우 끝나는 날, 다음 갱신일에 바뀌는 요금제, 결제 실패. 무료면 "무료 이용 중"과 이 iPad에서 만든 폴더·자료 수.
  2. 월간/연간, 무료·Plus·Pro 카드: StoreKit 가격, 연간 할인율("월간보다 N% 저렴"), 체험("7일 무료 체험 후 결제"), 기능 목록. 버튼은 현재 요금제 / 업그레이드 / N일 무료 체험 시작 / 연간으로 변경 / 다음 갱신일에 변경 / 변경 예약됨. 구독 중이면 "업그레이드는 바로 적용되고, 낮추기와 기간 변경은 다음 갱신일부터 적용돼요." 한 줄.
  3. AI 충전: StoreKit 가격, "이번 달 AI 사용량에 더해지고, 만료되지 않아요.", 남은 충전 잔액(서버 값, Auto 질문 회수), 구매 버튼. 로그인하지 않았으면 버튼이 꺼지고 "로그인한 계정에 충전돼요. 로그인하면 살 수 있어요."
  4. 구매 복원, 결제 내역(reportaproblem.apple.com), **App Store에서 구독 해지·관리**(Apple 시트), 이용약관(Apple 표준 EULA), 개인정보처리방침(bandal.io/privacy), 자동 갱신 안내, 충전은 1회 구매라는 안내.
- 프로필 메뉴의 "플랜 보기"는 origin/main에서 눌러도 아무것도 열지 않았다(같은 시뮬레이터에서 확인). 메뉴 팝오버가 닫히면서 그 위에 띄운 화면을 함께 닫았기 때문이다. 이제 `MembershipPaywall.present()`가 닫히는 팝오버를 기다렸다가 띄운다.
- 충전 버튼은 모델 선택 팝오버와 채팅의 한도 안내에도 그대로 있고, 요금제 화면과 같은 구매 로직(`StorePurchase.credit`)을 쓴다. Pro가 한도에 닿으면 팝오버가 이유와 함께 뜨는 것도 그대로다.
- 누가 충전을 살 수 있는지는 바꾸지 않았다: 로그인한 계정이면 요금제와 관계없이 산다(서버 `ipad-store`의 redeem에 요금제 검사가 없고, 앱도 전부터 로그인한 계정에만 충전을 보였다). 무료·Plus가 AI 한도에 닿으면 요금제 화면(Pro 선택), Pro면 충전 팝오버.

## 1. App Store Connect (소유자, 순서대로)

1. **계약/세금/금융**: 유료 앱 계약이 "활성"인지 본다(구독을 이미 팔고 있으면 활성이다).
2. **앱 › 수익화 › 앱 내 구입 › +**: 아래 값으로 만든다. 제품 ID는 코드(`App/Services/StoreSync.swift`의 `creditPack`)와 서버(`backend/supabase/functions/_shared/store/service.ts`의 `PACK_PRODUCT`)와 글자 하나까지 같아야 하고, 만든 뒤에는 바꿀 수 없다.

   | 항목 | 값 |
   |---|---|
   | 유형 | 소모성 (Consumable) |
   | 참조 이름 | `AI Credit` |
   | 제품 ID | `app.bandal.ipad.credit.pack1` |
   | 가격 | 대한민국 ₩5,500 기준, 다른 국가는 Apple 자동 환산 |
   | 판매 국가/지역 | 앱과 같게 |
   | 표시 이름 (한국어 / 영어(미국)) | `AI 충전` / `AI Credit` |
   | 설명 (한국어 / 영어(미국)) | `이번 달 AI 사용량을 더합니다. 만료 없음.` / `Adds to this month's AI allowance. Never expires.` |
   | 가족 공유 | 해당 없음 (소모성) |
   | 심사용 스크린샷 | 아래 "심사용 스크린샷"의 `plans-credit.png` |
   | 심사 메모 | 아래 "충전 심사 메모" |

   **충전 심사 메모**
   > AI Credit adds to the signed-in account's monthly AI allowance and never expires; our server keeps the balance. Path: Settings (gear in the left rail) > 구독·사용량 (Plan & usage) > 요금제 보기 (View plans) > AI 충전 (AI Credit) > "₩5,500 충전". It needs a Bandal account (Account button in the left rail > Sign in with Apple), because the credit is kept on the account. After the purchase the card says "충전했어요" (Credit added) and "남은 충전 잔액" (Credit left) goes up.

3. **구독 4개**(Bandal Membership 그룹)의 상태를 본다. 레벨은 Pro Monthly 1, Pro Yearly 1, Plus Monthly 2, Plus Yearly 2 그대로다. 이미 승인된 구독은 손대지 않는다(심사용 스크린샷을 바꾸면 다시 심사에 들어간다). 바꿔야 하면 `plans-yearly-pro.png`를 쓴다.
4. **앱 정보 › App Store 서버 알림 (V2)**: 프로덕션과 샌드박스 둘 다 `https://ukacrkcwiqafwpppshxb.supabase.co/functions/v1/ipad-store-notifications`인지 본다. 환불된 충전을 회수하는 것이 이 알림이다.
5. **사용자 및 액세스 › Sandbox**: 대한민국 샌드박스 테스터가 있는지 본다(3절에서 쓴다).
6. 3절 확인을 마친 뒤 **앱 버전 페이지 › 앱 내 구입 및 구독**에서 `AI Credit`을 골라 이 화면이 들어간 빌드와 함께 제출한다. 버전 번호와 빌드 번호는 이 브랜치가 정하지 않는다(main의 `project.yml`은 1.4.3 (32), 원격 `release-1.4.4-build33` 브랜치에는 1.4.4 (32) 업로드 기록이 있다).
7. **App Review 정보 › 메모**: `fastlane/metadata/review_information/notes.txt`의 "Plans and AI Credit" 절을 넣는다(이 브랜치에서 고쳤다).

## 2. 서버에서 확인할 것 (Supabase `ukacrkcwiqafwpppshxb`, 소유자)

이 세션은 운영 서버에 접근하지 않았다. 아래는 소유자가 본다.

1. **함수 배포**: `supabase functions list --project-ref ukacrkcwiqafwpppshxb`에 `ipad-store`와 `ipad-store-notifications`가 있고 둘 다 JWT 검증이 꺼져 있다(`--no-verify-jwt`). 없으면 [app-review-1.4.0.md](app-review-1.4.0.md) 1절 4번대로 배포한다.
2. **DB 함수**: `202611060002_ipad_store.sql`이 들어가 있다.
   ```sql
   select proname from pg_proc where proname in ('ipad_redeem_pack', 'ipad_revoke_pack', 'ai_grant_credit', 'ai_revoke_credit');
   ```
3. **지급액**: 충전 하나가 $2.00(200,000,000 µ¢)이다. 앱은 이 값을 모르고 서버가 돌려준 잔액만 보여 준다.
   ```sql
   select pack_ucents, auto_question_ucents from public.ai_settings;  -- 200000000, 70000
   ```
4. **Secrets**: `APPLE_APP_ID=6824053530`, `APPLE_SANDBOX_ALLOWED_USER_IDS=*`. App Review는 샌드박스에서 자기 계정으로 사므로 `*`가 아니면 심사자의 충전이 `sandbox_tester_required`로 거절되고 거래가 끝나지 않는다.
5. **스모크**: `curl -i -X POST https://ukacrkcwiqafwpppshxb.supabase.co/functions/v1/ipad-store -d '{}'`가 401 `{"code":"sign_in_required"}`를 돌려준다.
6. **알림 주소**: 3절의 샌드박스 구매 뒤 `ipad-store-notifications` 로그에 그 거래의 알림(충전은 ONE_TIME_CHARGE)이 오면 200으로 남는다. 충전 알림은 `ipad_store_events`에 기록만 된다(지급은 앱의 redeem이 한다).

## 3. 샌드박스·TestFlight에서 실제 구매 확인 (소유자, 실기기)

준비: TestFlight 빌드(또는 Xcode로 설치한 개발 빌드)를 설치하고, iPad 설정 › App Store › 샌드박스 계정에 대한민국 샌드박스 테스터로 로그인한다. 반달에는 테스트용 반달 계정으로 로그인한다(2절 4번 때문에 어느 계정이든 된다). 샌드박스는 1개월이 5분, 1년이 1시간이다.

충전:
- [ ] 설정 › 구독·사용량 › **요금제 보기** → 아래로 스크롤 → AI 충전 카드에 ₩5,500과 "남은 충전 잔액: AI 약 N회"가 보인다.
- [ ] "₩5,500 충전" → Apple 시트에서 확인 → "충전했어요", 잔액이 약 2,857회 늘어난다(200,000,000 / 70,000).
- [ ] 앱을 완전히 닫고 다시 열어 같은 화면을 본다: 잔액이 그대로다(두 번 지급되지 않음).
- [ ] 서버: `select source, ref, amount_ucents, granted_at from public.ai_credit_grants where source = 'pack' order by granted_at desc limit 5;`에 이 거래(`sandbox:<transactionId>`)가 한 줄만 있다.
- [ ] 서버가 안 될 때: 비행기 모드를 켜고 산다(Apple 시트는 결제 전에 연결이 필요하므로, 시트에서 확인한 직후 켠다) → "결제됐어요. 곧 사용량에 더해져요." → 비행기 모드를 끄고 앱을 백그라운드로 보냈다가 다시 연다 → 잔액이 한 번 늘어난다.
- [ ] 로그아웃 상태: AI 충전 버튼이 꺼져 있고 "로그인한 계정에 충전돼요. 로그인하면 살 수 있어요."가 보인다.
- [ ] 모델 선택 팝오버의 "충전"과 Pro 한도 안내의 "충전"도 같은 가격으로 사지고 "충전했어요"가 뜬다.

구독:
- [ ] 무료에서 Plus 월간 "7일 무료 체험 시작" → "Plus 시작됐어요", 현재 요금제 "반달 플러스 · 월간 / 무료 체험 중 · 7일 남음 · …에 첫 결제".
- [ ] Pro "업그레이드" → 바로 "반달 프로 · 월간".
- [ ] Plus "다음 갱신일에 변경" → "다음 갱신일(…)부터 플러스 월간", 카드는 "변경 예약됨". 5분 뒤 갱신되면 "반달 플러스 · 월간".
- [ ] 연간 탭의 "연간으로 변경" → 다음 갱신일부터 연간.
- [ ] "App Store에서 구독 해지·관리" → Apple 시트에서 해지 → 시트를 닫으면 "자동 갱신 꺼짐 · …에 끝나요".
- [ ] 앱을 지웠다 다시 설치 → 요금제 › 구매 복원 → 구독이 돌아온다(충전은 복원 대상이 아니고, 잔액은 계정에 있으므로 로그인하면 그대로 보인다).

## 4. 심사용 스크린샷

`StoreScreensUITests`가 2048×2732 PNG(세로, iPad Air 13 (M4) 시뮬레이터 원래 해상도, ASC의 12.9/13형 iPad 크기)로 남긴다. ASC KOR 가격 고정값(`--native-store-fixture`)이다.

| 파일 | 쓰는 곳 | 만드는 테스트 |
|---|---|---|
| `plans-credit.png` | AI Credit 심사용 스크린샷 | `testPlansSellAICreditToASignedInAccount` (로그인한 Pro, AI 100%) |
| `plans-yearly-pro.png` | 구독 4개 (바꿀 때만) | `testPlansShowStorePricesAndPickPro` |

이 브랜치에서 만든 파일은 `docs/release/screenshots/plans/`에 두었다.

## 5. 개발: StoreKit 구성 파일과 시험

- `Tests/StoreKit/Bandal.storekit`: 구독 넷(그룹 Bandal Membership, 레벨 Pro 1·Plus 2, 7일 무료 체험)과 AI Credit, KOR 가격(ASC 값). 어느 타깃의 소스·리소스에도 들어 있지 않고, `BandalStoreKit` 스킴의 Run 동작만 이 파일을 가리킨다. Release 빌드의 `.app`에 `.storekit` 파일이 없는 것을 확인했다.
- **시뮬레이터에서 끝까지 사 보기**: Xcode에서 스킴을 `BandalStoreKit`으로 바꾸고 iPad 시뮬레이터에서 ⌘R → 요금제에서 업그레이드·낮추기·기간 변경·충전을 누른다. Apple 시트가 StoreKit 테스트 환경으로 뜨고, Debug › StoreKit › Manage Transactions에서 거래를 보고 환불·Ask to Buy 승인·갱신을 할 수 있다. 충전 지급은 로그인한 계정과 서버가 있어야 하므로 이 환경에서는 "결제됐어요. 곧 사용량에 더해져요."에서 멈춘다. 로그인한 채로 써도 서버는 Xcode가 서명한 거래를 `invalid_apple_signature`로 거절하고, 앱은 그 거래를 끝내지 않고 남겨 둔다(Manage Transactions에서 지운다). 실제 지급 확인은 3절의 샌드박스·TestFlight로 한다. `Bandal` 스킴은 손대지 않았으므로 실기기 실행은 그대로 샌드박스를 쓴다.
- **이 Mac의 `xcodebuild`에서는 StoreKit 구성 파일이 적용되지 않는다.** `SKTestSession`(UI 테스트 프로세스와 앱 안의 단위 테스트 둘 다), 스킴 Run·Test 동작의 구성, 서명 여부, 최소 구성 파일까지 바꿔 봤지만 시뮬레이터의 `storekitd`가 매번 `saveConfigurationData`에 `SKInternalErrorDomain Code=3`을 돌려주고, 앱은 App Store 샌드박스(미국 가격, Apple 계정 로그인 시트)로 간다. Xcode 화면에서 ⌘R로 실행할 때는 다른 길을 쓰므로 위 절차는 Xcode에서 확인해야 한다(이 세션은 Xcode 화면을 조작할 수 없어 확인하지 못했다).
- 그래서 자동 테스트는 앱 안의 DEBUG 전용 가짜 App Store로 버튼을 누른다: `--plans-state free|plus-monthly|plus-yearly|pro|trial|canceled|scheduled|billing`에서 시작하고(`App/Services/PlansStoreSimulator.swift`, 그룹 레벨 규칙: 체험 한 번, 업그레이드 즉시, 낮추기·기간 변경은 다음 갱신일), `--plans-store-mode cancel|ask`로 구매 취소와 승인 대기를 만든다. 가짜 서버는 `--plans-server ok|fail`(`App/Services/PlansServerFixture.swift`, 거래 id마다 한 번 지급). 둘 다 Release 빌드에는 없다(`#if DEBUG`).
  - `PlansPurchaseFlowUITests`: 업그레이드, 낮추기, 기간 변경, 승인 대기, 구매 취소, 충전 → 서버 지급 → 거래 종료 → 재실행해도 다시 보내지 않음, 서버 실패 → 거래를 끝내지 않음 → 다음 실행 때 한 번 지급, 모델 선택 팝오버의 충전.
  - `StoreScreensUITests`: 가격과 버튼, 상태별 문구, 가격을 못 불러온 상태, 로그아웃 상태의 충전, 설정의 진입 버튼, 심사용 스크린샷.
  - `PlansLayoutScreenshotTests`: 세로·가로, 라이트·다크, 좁은 창(`--plans-width 375|678`), 영어.
  - 단위 테스트 `PlansPurchaseTests`, `StoreOffersTests`: StoreKit 없이 같은 판단(즉시인지 다음 갱신일인지, 거래를 끝낼지, 다시 보낼지, 환불된 충전, 무엇을 말할지).
- 환불은 UI 테스트로 만들지 못했다. 환불된 구독이 무료로 돌아가는 것(`MembershipTests`), 환불된 충전이 지급 없이 끝나는 것(`PlansPurchaseTests.testARefundedPackIsFinishedUnpaid`)은 단위 테스트로, 실제 환불 알림은 서버 테스트(`backend/supabase/functions/_shared/store/service_test.ts`)가 본다.

## 6. 문서와 어긋나는 점 (정책은 바꾸지 않았다)

- `docs/web/ai-fair-use.ko.md` "사용량을 다 썼을 때"는 충전팩을 Pro의 길로만 적는다. 서버와 앱은 로그인한 모든 계정에 판다(위 "앱에서 바뀐 것" 끝). 문서를 넓히거나 정책을 좁히는 것은 소유자가 정한다.
- 1.4.1~1.4.3 심사 메모는 "Plans: Free, Bandal Plus, Bandal Pro and AI Credit (consumable) … Unchanged from 1.4.0"이라고 적었지만 AI Credit은 ASC에 없었다. 이번 메모는 AI Credit을 새로 제출하는 상품으로 적었다.
- [app-review-1.4.0.md](app-review-1.4.0.md) 2절의 충전팩 심사용 스크린샷 "충전 팝오버"는 이제 요금제 화면의 AI 충전 카드(`plans-credit.png`)다.
- `notes.txt`의 첫 줄은 아직 "Version 1.4.1 adds three things."다. 이번 버전의 머리말은 버전을 정하는 쪽에서 고친다(이 브랜치는 구매 경로 부분만 고쳤다).
- **`notes.txt`가 ASC 메모 한도(4,000자)를 넘는다.** origin/main에서 이미 4,304자였고 "Plans and AI Credit" 절을 넣어 약 5,200자다. 1.4.1의 세 절(첫 실행 설정, 학교 AI 찾기, 친구 초대)은 이제 "1.4.1부터 그대로"로 줄여도 된다. 제출 전에 줄여야 붙여 넣을 수 있다.
