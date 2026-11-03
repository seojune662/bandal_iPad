# 1.2.0 심사 제출 체크리스트 (2026-11-03)

main(7907265)은 1.1.0 (8)에 동기화(#1–#11, #13)와 반달 멤버십(#12)을 더한 상태다. 1.1.0 (7)은 이미 판매 중(READY_FOR_SALE)이라 새 버전 1.2.0 (8)으로 낸다. 버전, 멤버십 플래그, Fastfile, 05 스크린샷 테스트는 이 문서와 같은 PR에서 바꿨다.

"지금 상태"는 2026-11-03에 ASC API를 읽기 전용으로 조회해 확인한 값이다. 구독 상품 입력값은 [app-store-membership.md](app-store-membership.md)에 있어 여기서 되풀이하지 않는다.

## 1. 이대로는 제출이 막히는 것

| 할 일 | 지금 상태 |
|---|---|
| 연간 상품 `app.bandal.ipad.plus.yearly` 만들기 | ASC에 월간만 있다. 사용자가 고치는 중이다. |
| 월간 한국어 설명 고치기 | `iPad 보고서 문안`이 들어가 있다. `과목·자료 무제한, AI 기능 무제한(본인 API 키)`로 바꾼다. 사용자가 고치는 중이다. |
| 1주 무료 체험(도입 오퍼): 두 상품에 각각 | 월간에 없다. 사용자가 고치는 중이다. |
| 구독 심사용 스크린샷: 두 상품에 각각 | 없다. 멤버십을 켠 빌드가 TestFlight에 올라가야 찍을 수 있다(5-B). |
| 유료 앱 계약 | API로는 보이지 않는다. 샌드박스에서 가격이 뜨면 활성이다. |
| App Store 배포 프로파일에 iCloud 넣기 | 2026-11-02 기준으로 배포 프로파일에 iCloud가 없다. `fastlane profile`로 다시 만든다. |
| 개인정보 처리방침 고치기 | 데스크톱 팀이 bandal_web에서 고치는 중이다. 지금 bandal.io/privacy의 iPad 절은 "iPad 앱 1.0은 개인정보를 수집하지 않습니다. 계정, 로그인, 동기화…를 제공하지 않으며"라서 3절의 라벨과 맞지 않는다. 고칠 것은 7절에 있다. |

## 2. 순서

### 빌드

- [x] `App/Native/NativeReleaseFlags.swift`의 `membership`을 `true`로 바꿨다(이 PR). 끈 빌드로 내면 심사자가 구매 화면을 찾지 못한다.
- [x] `project.yml`의 `MARKETING_VERSION`을 `"1.2.0"`으로 바꿨다(이 PR). 빌드 번호 8은 그대로 쓴다.
- [x] `fastlane/Fastfile`의 `metadata`·`screenshots` 레인을 `app_version: "1.2.0"`으로 바꿨다(이 PR). 1.1.0으로 두면 판매 중인 1.1.0을 고치려다 실패한다.
- [ ] `fastlane profile`을 실행한 뒤 `Scripts/upload.sh`로 올린다. 빌드하는 체크아웃에 `App/Resources/Configuration.plist`가 있어야 한다.
- [ ] TestFlight로 실기기에서 확인한다.
  - [ ] iCloud 동기화 연결. 배포용으로 서명한 빌드에서는 처음이다.
  - [ ] Google Drive 연결
  - [ ] 샌드박스 구매
    - 페이월에 월간·연간과 1주 체험이 뜬다.
    - 구매하면 설정 › 구독이 "이용 중"이 된다.
    - 다시 설치한 뒤 "구매 복원"을 누르면 Plus가 돌아온다.
  - [ ] 계정 삭제
    - Apple로 로그인한 뒤 설정 › 계정 › 계정 삭제를 누른다.
    - iPad 설정 › Apple 계정 › 로그인 및 보안 › Apple로 로그인 목록에서 반달이 빠지면 토큰 철회까지 된 것이다.

### App Store Connect (1.2.0)

- [ ] 1절의 구독 항목을 마친다. 청구 유예 기간(16일)을 아직 켜지 않았다면 켠다([app-store-membership.md](app-store-membership.md) 4절 7).
- [ ] 새 버전 1.2.0을 만들고 빌드를 고른다.
- [ ] 앱 내 구입 및 구독: 두 구독을 고른다. 첫 구독은 이 버전과 함께 심사에 들어간다.
- [ ] 설명과 새로운 기능: 6절 문구를 넣는다.
  - `fastlane metadata`는 `fastlane/metadata`를 그대로 올린다. 지금 그 폴더에는 1.1.0의 새로운 기능과 1.0의 심사 메모(`review_information/notes.txt`)가 들어 있다. 6절·4절 문구로 바꾸기 전에는 이 레인을 돌리지 않는다.
- [ ] 스크린샷: 5-A
- [ ] 앱 심사 정보
  - "로그인 필요"는 꺼 둔 채로 둔다.
  - 메모는 4절 문안으로 바꾼다.
  - 첨부에 5-C 녹화를 넣는다(권장).
- [ ] 앱 개인정보 보호: 3절대로 바꾸고 게시한다.
  - 라벨은 버전이 아니라 앱에 붙는다. 게시하는 즉시 1.1.0 페이지에도 보이니 제출 직전에 게시한다.
- [ ] 출시 방식을 확인한다. 1.1.0은 "승인 후 자동 출시"였다.
- [ ] 심사에 제출한다.

## 3. 앱 개인정보 보호 (라벨)

"이 앱에서 데이터를 수집합니까?"에는 **예**라고 답하고 아래 세 가지만 고른다.

| 데이터 유형 | 용도 | 사용자에게 연결됨 | 추적 |
|---|---|---|---|
| 연락처 정보 › 이메일 주소 | 앱 기능 | 예 | 아니요 |
| 연락처 정보 › 이름 | 앱 기능 | 예 | 아니요 |
| 식별자 › 사용자 ID | 앱 기능 | 예 | 아니요 |

앱의 개인정보 매니페스트(`App/Resources/PrivacyInfo.xcprivacy`)도 같은 세 가지를 신고한다.

판단 기준은 Apple의 정의다. "'수집'은 전송된 요청을 실시간으로 처리하는 데 필요한 기간보다 더 오랫동안 귀사 또는 타사가 접근할 수 있는 방식으로 데이터를 기기 외부로 전송하는 것을 의미합니다."

**수집하는 것**

로그인(선택)을 하면 반달 계정 서버(Supabase, `auth.bandal.io`)에 아래가 남는다.
- 계정 ID
- 이메일
- Google 프로필 이름(Google로 로그인했을 때)
- 사용자가 정한 닉네임. Apple 분류에서 대화명·핸들은 '사용자 ID'의 예로 나온다.

설정 › 계정의 안내 문구("로그인하면 이메일과 닉네임이 반달 계정 서버에 저장됩니다")와도 맞다.

**수집하지 않는 것**

- **자료와 필기(동기화 포함)**: 기기와 사용자 본인의 iCloud Drive 또는 Google Drive(`drive.file`)에만 있다. 반달은 여기에 접근하지 못한다. 기기 이름, `device_id`, Google 계정 힌트도 그 저장소 안의 파일에만 들어간다.
- **구입**: StoreKit 거래는 기기에서만 확인하고 어디로도 보내지 않는다. 로그인했을 때 붙는 `appAccountToken`은 Apple로 가는 값이다. Apple 안내에도 "귀사는 Apple이 수집하는 데이터를 공개할 책임은 없습니다"라고 되어 있다.
- **AI 질문과 첨부**: 사용자의 키로, 사용자가 고른 제공자에게 iPad에서 바로 보낸다. 1.0·1.1 때와 같은 판단이고, 그때도 "수집 안 함"으로 승인됐다.
- **무료 한도와 AI 월 사용 횟수**: 기기 안에서만 센다.
- **브라우저 기록, 캘린더, 카메라**: 기기 안에서만 쓴다.
- **분석·광고·충돌 보고**: 해당 SDK가 없다.
- **Google 프로필 사진 주소**: Supabase 사용자 정보에 남을 수 있지만 앱은 받지도 쓰지도 않는다.

## 4. 심사 노트 (앱 심사 정보 › 메모)

메모 칸은 4,000자까지다. 아래 문안은 공백 포함 3,582자다.

```text
Hello,

Version 1.2.0 adds three optional features: sign-in, sync and the Bandal Plus subscription. No demo account is needed. Every feature, including sync, purchase and restore, works without signing in, and the app never asks for sign-in at launch.

1. Sign-in and account deletion
- The 계정 (Account) button in the left rail offers Sign in with Apple and Sign in with Google. Signing in only adds a Bandal profile (nickname and avatar).
- To delete the account, while signed in: Settings > 계정 (Account) > 계정 삭제 (Delete Account). This deletes the account on our server and revokes the Sign in with Apple token. Files on the iPad stay.

2. Sync (optional, free, not part of the subscription)
- Settings > 동기화 (Sync): choose iCloud or Google Drive. Courses and materials are stored only in the user's own storage: the app's iCloud Drive folder, or a "Bandal" folder in their Google Drive (drive.file scope: only files the app creates). We run no server for documents and cannot read them.
- Sync needs an iCloud or Google account. Reviewing the other features does not need it.

3. Bandal Plus (auto-renewable subscription)
- Free use on this iPad: 1 course, 10 materials (PDFs and notes) and 20 AI requests a month. Bandal Plus (monthly or yearly, 1-week free trial for new subscribers) removes these limits. When it ends, nothing already made is locked.
- To see the purchase screen: Settings > 구독 (Subscription) > 반달 플러스 보기, or create a second course ("+" next to 과목 > 새 과목 만들기).
- Restore Purchases is on the purchase screen and at Settings > 구독 > 구매 복원. The purchase screen links to the Terms of Use (Apple standard EULA) and our Privacy Policy.

Guideline 2.1(b)
1. Anyone can use the app for free within the limits above. Bandal Plus is for users who need more courses, materials or AI requests.
2. Only inside the app, with In-App Purchase.
3. Bandal Plus bought with In-App Purchase on the same Apple Account, brought back with Restore Purchases.
4. None. Nothing is unlocked by payment outside the app. AI requests are billed by the AI provider to the user's own API account; we do not sell AI access or API keys.

How to use the main features
- Create a course: "+" next to 과목 > 새 과목 만들기 (New Course).
- Import a PDF: the tray icon "파일 가져오기" (Import Files) above 자료 (Materials), then pick any PDF. Tap it to open.
- Handwriting: choose the pen, highlighter or eraser in the PDF toolbar and write with Apple Pencil. "+" > "새 노트" in 자료 creates a handwriting note.
- Tabs and panes: "+" in the tab bar opens a note, Markdown, browser or AI tab. The layout button splits the workspace.
- AI assistant (optional): needs the user's own OpenAI, Anthropic or Google API key in Settings > AI 엔진 (AI Engine). We do not provide a key.

External services
- Bandal account server (auth.bandal.io), only after sign-in: account ID, email, name from the sign-in provider, and nickname. No documents or handwriting.
- Apple: Sign in with Apple, In-App Purchase. Transactions are verified on the device and not sent to us.
- Google: Sign in with Google (through our account server), and the Google Drive API for sync, called from the iPad.
- AI providers: only with the user's own key, after a consent screen for each provider. Requests go from the iPad straight to the provider.
- In-app browser: loads the sites the user opens. Because it can open any website, the age rating is 17+.
- No analytics, advertising or crash-reporting services.

Regional differences: not distributed in the EU or China mainland. The features are the same everywhere else.
Regulated industry: not applicable.
```

## 5. 스크린샷

### A. App Store: iPad 13", 2752×2064(가로)

1.1.0과 같은 규격이다. 한국어 세트만 있고, 영어(미국)도 이 세트를 쓴다.

| 파일 | 화면 | 1.2.0 |
|---|---|---|
| 01-pdf-handwriting.png | PDF 필기 | 유지 |
| 02-markdown-note.png | 마크다운 노트 | 유지 |
| 03-split-workspace.png | 분할 작업 공간 | 유지 |
| 04-planner.png | 학업 보드 | 유지 |
| 05-settings.png → **05-sync.png** | 설정 › 동기화 | 교체한다. iCloud가 켜져 있고 "최신 상태 · …에 동기화"와 기기 이름 "iPad"가 보인다. 이메일은 나오지 않는다. |

- 제출할 빌드의 화면이 1.1.0과 눈에 띄게 다르면 01–04도 다시 찍는다. ui/taste-audit 변경이 들어가는 경우가 그렇다.
- 찍는 법: `AppStoreScreenshotTests`를 iPad Pro 13-inch (M4) 시뮬레이터에서 돌린다.
  - 05는 이 PR부터 동기화 화면을 찍는다. 시뮬레이터를 테스트용 Apple 계정으로 iCloud에 로그인하고 iCloud Drive를 켜 둔다. 테스트는 앱을 `-BandalCloudSync icloud`로 다시 실행해 05를 찍고, 2분 안에 "최신 상태"가 뜨지 않으면 실패한다.
  - 동기화는 05에서만 켜므로 01–04에는 그 계정의 자료가 나오지 않는다. 대신 돌릴 때마다 그 계정의 iCloud Drive › 반달에 '선형대수학' 과목이 하나씩 쌓인다.
  - 가로 캡처는 90° 돌아간 채로 나온다. `sips -r 270`으로 세워서(1.1.0 파일과 같은 방향) `fastlane/screenshots/ko/`에 두고 `05-settings.png`는 지운다. `screenshots` 레인은 ASC의 기존 스크린샷을 지우고 폴더에 있는 것을 모두 올린다(`overwrite_screenshots`).

### B. 구독 심사용 스크린샷: 두 상품에 각각 (필수, 같은 이미지 가능)

- 화면은 페이월(반달 플러스 시트)이다. 아래가 보여야 한다.
  - 월간·연간 가격
  - 1주 무료 체험
  - 구독 버튼
  - 이용약관과 개인정보 처리방침 링크
- 멤버십을 켠 TestFlight 빌드를 실기기에서 열고 샌드박스 계정으로 찍는다. 시뮬레이터에서는 StoreKit 설정 파일이 없어 상품이 뜨지 않는다.
- 심사용이라 스토어에는 나오지 않는다.

### C. 심사 첨부 화면 녹화 (권장)

1.0 때 2.1로 녹화를 요구받은 적이 있다. 실기기에서 1–2분 정도 아래 순서로 찍는다.
1. 로그인 없이 시작한다.
2. 두 번째 과목을 만들면 페이월이 뜬다.
3. 샌드박스로 구매한다.
4. 설정 › 구독이 "이용 중"으로 바뀐다. "구매 복원"도 눌러 본다.
5. 설정 › 동기화를 연다.
6. 계정 › Apple로 로그인한 뒤 계정을 삭제한다.

파일 선택기에 개인 파일 이름이 보이면 가린다.

## 6. 설명과 새로운 기능

**설명**

1. 끝에 [app-store-membership.md](app-store-membership.md) 4절 2의 구독 블록을 붙인다. Apple 표준 EULA 링크가 여기에 있다.
2. "저장" 문단을 바꾼다. 지금은 "모든 자료는 iPad 안에 저장되며 계정 없이 바로 사용할 수 있습니다." 한 줄이다.

```text
저장
- 자료는 iPad에 저장되며 계정 없이 바로 쓸 수 있습니다.
- 원하면 본인의 iCloud나 Google Drive로 다른 기기와 무료로 동기화할 수 있습니다. 자료는 반달 서버에 올라가지 않습니다.
```

```text
Storage
- Everything is stored on your iPad. No account is needed.
- You can sync with your other devices through your own iCloud or Google Drive, for free. Your materials are never uploaded to Bandal's servers.
```

**새로운 기능** (`release_notes.txt`)

1.1.0은 한국어 파일에도 영어 문구가 들어가 있다. ui/taste-audit 변경이 들어가면 줄을 더한다.

```text
- 본인의 iCloud나 Google Drive로 다른 기기와 과목·자료·필기를 동기화합니다(설정 › 동기화). 무료이며 반달 계정이 없어도 됩니다.
- 반달 플러스: 과목과 자료를 개수 제한 없이 만들고 AI 기능을 횟수 제한 없이 씁니다. 무료로는 과목 1개, 자료 10개, AI 월 20회를 쓸 수 있습니다.
- Apple이나 Google 계정으로 반달 프로필에 로그인할 수 있습니다(선택).
```

```text
- Sync courses, materials and handwriting with your other devices through your own iCloud or Google Drive (Settings > Sync). Free, and no Bandal account is needed.
- Bandal Plus: unlimited courses, materials and AI requests. Free use includes 1 course, 10 materials and 20 AI requests a month.
- Optional sign-in with Apple or Google for a Bandal profile.
```

## 7. 개인정보 처리방침에 고칠 것 (bandal_web, iPad 절)

- **로그인(선택, Apple·Google)**
  - 계정 ID, 이메일, 이름, 닉네임을 반달 계정 서버(Supabase)에 둔다.
  - 앱에서 계정을 삭제하면 지운다. Apple 로그인 토큰도 철회한다.
- **동기화(선택)**
  - 사용자 본인의 iCloud Drive나 Google Drive에만 저장한다. 반달은 접근하지 않는다.
  - Google Drive 권한은 앱이 만든 파일(`drive.file`)로 한정한다.
  - 동기화 파일에는 기기 이름이 들어간다. Drive라면 Google 계정 이메일도 들어간다.
- **구독**
  - 결제는 Apple이 처리하고 반달은 결제 정보를 받지 않는다.
  - 로그인한 상태라면 반달 계정 ID를 Apple 거래에 붙인다(`appAccountToken`).
- **녹음 문구 빼기**: 지금 문구는 "…화이트보드와 녹음은 iPad 안에 저장합니다"다. 녹음은 1.0 빌드 6에서 뺐다.

## 8. 확인만 하면 되는 것

- 수출 규정: `ITSAppUsesNonExemptEncryption`이 `NO`라서 질문이 나오지 않는다.
- 연령 등급: 17+ 그대로다(앱 안 브라우저 때문).
- 판매 국가: 그대로다. EU 27개국과 중국 본토는 빠져 있다.
- App Store 서버 알림 URL: 비워 둔다. 서버가 없다.
