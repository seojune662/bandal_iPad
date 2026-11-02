# 반달 멤버십: App Store Connect 입력값 (2026-11-02)

PR8(구독)에 맞춰 App Store Connect(ASC)에 넣을 값이다. 코드는 아래 제품 ID만 안다(`App/Services/Membership.swift`의 `Membership.products`). 이름, 설명, 가격, 체험은 모두 ASC에서 오고, 페이월(`SubscriptionStoreView`)이 그 값을 그대로 보여 준다. 그래서 아래 문구에도 동기화는 넣지 않았다.

2026-11-02에 ASC API로 읽어 확인한 것은 다음과 같다.
- 이 앱(Apple ID 6824053530, `app.bandal.ipad`)에는 구독 그룹도, 앱 내 구입도 아직 없다.
- 대한민국 가격대 681개 중에 ₩3,900과 ₩29,000이 둘 다 있다.

## 0. 먼저 할 것

1. **계약/세금/금융 › 유료 앱 계약(Paid Applications)**: 서명하고 은행 계좌와 세금 양식을 넣는다. 이 계약이 "활성"이어야 판매는 물론 샌드박스 구매 시험도 된다.
2. (선택) **App Store Small Business Program**: 가입하면 수수료가 15%다. 가입하지 않으면 첫해 30%이고, 1년 넘게 이어진 구독은 15%다.

## 1. 구독 그룹

| 항목 | 값 |
|---|---|
| 참조 이름 | `Bandal Membership` |
| 현지화(한국어) 그룹 표시 이름 | 반달 멤버십 |
| 현지화(영어(미국)) 그룹 표시 이름 | Bandal Membership |
| 앱 이름 표시 | 앱 이름 사용 |

## 2. 구독 상품 두 개 (같은 그룹)

| 항목 | 월간 | 연간 |
|---|---|---|
| 참조 이름 | `Bandal Plus Monthly` | `Bandal Plus Yearly` |
| 제품 ID | `app.bandal.ipad.plus.monthly` | `app.bandal.ipad.plus.yearly` |
| 구독 기간 | 1개월 | 1년 |
| 레벨 | 1 | 1 (월간과 같은 레벨) |
| 가족 공유 | 끔 | 끔 |
| 가격: 기준 국가 | 대한민국 ₩3,900 | 대한민국 ₩29,000 |
| 가격: 다른 국가/지역 | Apple 자동 환산 그대로 | Apple 자동 환산 그대로 |
| 판매 국가/지역 | 앱과 같게(148개, EU 27개국 제외) | 앱과 같게 |
| 세금 카테고리 | 앱과 동일 | 앱과 동일 |
| 표시 이름(한국어, 30자 이내) | 반달 플러스 월간 | 반달 플러스 연간 |
| 설명(한국어, 45자 이내) | 과목·자료 무제한, AI 기능 무제한(본인 API 키) | 같음 |
| 표시 이름(영어(미국)) | Bandal Plus Monthly | Bandal Plus Yearly |
| 설명(영어(미국)) | Unlimited courses, materials, AI (own key) | 같음 |
| 심사용 스크린샷 | 아래 6절의 샌드박스 결제 화면 | 같음 |
| 심사 메모 | 아래 "구독 심사 메모" | 같음 |

- **제품 ID는 코드와 글자 하나까지 같아야 한다.** 한 번 만들면 바꿀 수 없고, 지워도 같은 ID를 다시 쓸 수 없다.
- **레벨**: 같은 레벨에 둔 상품끼리는 같은 서비스로 본다. 월간과 연간 사이 전환은 "크로스그레이드"이고, 기간이 다르면 다음 갱신일에 바뀐다.
- **가족 공유**: 나중에 켤 수는 있다. 한 번 켜면 다시 끌 수 없다.

**구독 심사 메모** (두 상품에 같이)

> Free use has limits on this iPad: 1 course, 10 materials (PDFs and notes) and 20 AI requests a month with the user's own API key. Bandal Plus removes these limits. To reach the purchase screen, create a second course, or open Settings > 구독 (Subscription) > 반달 플러스 보기. No login is needed to buy or restore.

## 3. 무료 체험 (도입 오퍼): 두 상품에 각각

| 항목 | 값 |
|---|---|
| 유형 | 무료 |
| 기간 | 1주 |
| 국가/지역 | 전체 |
| 시작일 / 종료일 | 바로 / 없음 |

- 체험은 그룹당 한 번이다. 월간으로 체험한 사람은 연간에서 다시 체험할 수 없다.
- 페이월에는 "7일 무료" 문구를 코드로 넣지 않았다. StoreKit이 체험 자격이 있는 사람에게만 체험 조건을 보여 준다.

## 4. 앱 버전 페이지 (구독을 처음 내는 버전)

1. **앱 내 구입 및 구독**: 두 구독을 고른다. 첫 구독은 새 앱 버전과 함께 심사에 내야 한다. 그 버전은 `NativeReleaseFlags.membership`을 켠 빌드여야 한다. 지금은 꺼 두었고, 끈 빌드로 내면 심사자가 구매 화면을 찾지 못한다.
2. **설명**: 끝에 붙인다(Apple 표준 EULA를 쓰면 설명에 링크가 있어야 한다). `fastlane metadata` 레인으로 올린다면 `fastlane/metadata/*/description.txt`에도 같은 줄을 넣어야 덮어쓰이지 않는다.

   한국어:
   ```text
   반달 플러스 (자동 갱신 구독)
   - 무료로는 이 iPad에서 과목 1개와 자료 10개를 만들고, 본인 API 키로 쓰는 AI 기능을 매달 20회 쓸 수 있습니다.
   - 반달 플러스는 과목과 자료를 개수 제한 없이 만들고, AI 기능을 횟수 제한 없이 씁니다.
   - 처음 구독하면 1주 무료 체험 뒤에 결제됩니다. 결제는 Apple 계정으로 하며, 기간이 끝나기 24시간 전까지 해지하지 않으면 자동으로 갱신됩니다. 설정 › [이름] › 구독에서 관리하거나 해지할 수 있습니다.
   - 구독이 끝나도 이미 만든 과목과 자료는 그대로 열고 고칠 수 있습니다.
   - 이용약관(EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
   - 개인정보 처리방침: https://bandal.io/privacy
   ```

   영어:
   ```text
   Bandal Plus (auto-renewable subscription)
   - Free: on this iPad, create 1 course and 10 materials, and use AI features with your own API key 20 times a month.
   - Bandal Plus: unlimited courses and materials, and unlimited AI requests.
   - New subscribers get a 1-week free trial before the first charge. Payment is charged to your Apple Account. The subscription renews automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel it in Settings › [your name] › Subscriptions.
   - When a subscription ends, the courses and materials you made stay open and editable.
   - Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
   - Privacy Policy: https://bandal.io/privacy
   ```
3. **사용권 계약(EULA)**: ASC 칸은 비워 둔다(Apple 표준). **개인정보 처리방침 URL**은 이미 `https://bandal.io/privacy`다.
4. **App Review 정보 › 메모**: 지금 메모 2절의 "no paid features or in-app purchases" 문장은 지운다. 그리고 다음 절을 더한다.

   ```text
   5. Subscription (Bandal Plus)
   The app is free to use with limits: on this iPad, 1 course and 10 materials (PDFs and notes) can be created, and the AI assistant (user's own API key) can be used 20 times a month. Bandal Plus, an auto-renewable subscription (monthly or yearly, 1-week free trial for new subscribers), removes these limits. To see the purchase screen, create a second course ("+" next to 과목 > 새 과목 만들기), or open Settings > 구독 (Subscription) > 반달 플러스 보기. Buying and restoring need no login; Restore Purchases is on the same screen. When a subscription ends, nothing already made is locked.
   ```
5. **앱 개인정보 보호(App Privacy)**: 구독 때문에 바꿀 것은 없다. 거래는 기기 안에서만 확인하고 어디로도 보내지 않는다. 로그인 화면 때문에 라벨을 바꾸는 것은 별개 일이다.
6. **App Store 서버 알림 URL**: 비워 둔다(서버 없음).
7. **청구 유예 기간**: 켠다. 앱 › 구독 › "청구 유예 기간" 섹션에서 "청구 유예 기간 설정"을 누른다. 이 설정은 앱 하나에 하나이고, 앱의 모든 구독에 같이 적용된다.

   | 항목 | 값 |
   |---|---|
   | 기간 | 16일 |
   | 유예 기간을 활성화할 갱신 유형 | 모든 갱신 |
   | 서버 환경 | 프로덕션 및 Sandbox 환경 |

   - "모든 갱신"이면 무료 체험이 유료로 넘어갈 때 결제가 실패해도 유예를 받는다. "유료에서 유료로 전환한 갱신만"을 고르면 체험 끝의 결제 실패는 유예 없이 무료로 돌아간다.
   - 바꾼 설정은 최대 24시간 뒤에, 그다음 갱신부터 적용된다.
   - 앱 코드는 바꿀 것이 없다. StoreKit의 현재 권한(`Transaction.currentEntitlements`)에는 유예 기간 중인 구독도 들어 있으므로, 앱은 유예 기간 동안 Plus로 본다.

## 5. 나중에 Pro를 더할 때

- 같은 그룹에 `app.bandal.ipad.pro.monthly`와 `app.bandal.ipad.pro.yearly`(아직 쓰지 않은 ID)를 레벨 1로 넣고, Plus 두 상품은 레벨 2로 내린다.
  - Plus에서 Pro로 가는 것은 업그레이드라 바로 바뀐다.
  - Pro에서 Plus로 가는 것은 다운그레이드라 다음 갱신일에 바뀐다.
- 코드: `Membership.Tier`에 `pro`를 `plus` 다음에 더하고, `Membership.products`에 두 ID를 넣는다. 무료 한도는 `plus` 이상이면 풀리므로 Pro도 무제한이다. Pro만의 기능은 `tier >= .pro`로 묶는다.

## 6. 실기기 샌드박스 확인 (PR8 머지 전)

준비:
- ASC › 사용자 및 액세스 › Sandbox › 테스터를 만든다(국가: 대한민국).
- iPad에 `NativeReleaseFlags.membership`을 켠 개발 빌드를 설치한다(Xcode로 설치한 빌드는 샌드박스를 쓴다).
- 설정 › App Store › 샌드박스 계정에 로그인한다.
- 샌드박스는 시간이 빠르다. 1개월이 5분이고, 1년은 1시간이다. 갱신은 12번까지 된다.

확인:
- [ ] 반달에 로그아웃한 상태에서 체험을 시작한다. 바로 Plus가 되고, 설정 › 구독이 "이용 중"이다.
- [ ] 해지하거나 만료시킨다. 무료로 돌아가도 만든 과목과 자료는 그대로다. 새로 만들 때만 페이월이 뜬다.
- [ ] 앱을 지웠다 다시 설치한 뒤 "구매 복원"을 누른다. 다시 Plus가 된다.
- [ ] 반달에 로그인한 상태에서 산 거래에 `appAccountToken`(반달 사용자 id)이 있다.
- [ ] 무료일 때 두 번째 과목, 열한 번째 자료, 스물한 번째 AI 요청에서 페이월이 이유와 함께 뜬다.
- [ ] 이 화면을 캡처해 2절의 심사용 스크린샷으로 쓴다.

## 7. 내가 정한 값 (바꾸려면 알려 주세요)

- 그룹 표시 이름 "반달 멤버십", 상품 표시 이름 "반달 플러스 월간/연간", 그리고 2절의 설명 문구.
- 앱 화면의 이름은 "반달 플러스"다(페이월 제목, 설정 › 구독).
- 레벨: 월간과 연간을 같은 레벨에 뒀다.
- 다른 국가 가격은 Apple 자동 환산 그대로다.
- 청구 유예 기간 16일은 사용자가 정했다. 갱신 유형 "모든 갱신"과 서버 환경 "프로덕션 및 Sandbox 환경"은 내가 골랐다.
