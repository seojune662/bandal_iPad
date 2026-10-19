# App Store 1.0 제출 초안 (2026-10-19)

대표 확인 전에는 제출하지 않는 항목의 초안. 확정되면 App Store Connect API로 그대로 입력한다.
점검 결과와 막힌 항목은 같은 날짜의 세션 보고를 따른다.

## 1. App Privacy (개인정보 수집 항목)

전제에 따라 두 가지 중 하나를 고른다.

### A. 1.0에서 계정 기능까지 숨길 때 (권장)

- **"데이터를 수집하지 않음"** 선택.
- 근거: 반달 서버로 가는 데이터가 없다. 녹음·자막은 sherpa-onnx로 기기 내 처리, 캘린더는 EventKit 로컬, API 키는 Keychain, 분석·광고·크래시 SDK 없음.
- AI 질문은 사용자가 입력한 키로 OpenAI·Anthropic·Google에 **직접** 전송된다. Apple 정의상 개발자나 개발자의 서드파티 파트너가 수집하는 것이 아니므로 라벨 대상이 아니다. 심사 메모와 처리방침에는 명시한다.

### B. 로그인(Apple·Google·카카오)을 1.0에 남길 때

| 데이터 | 용도 | 사용자 연결 | 추적 |
|---|---|---|---|
| 연락처 정보 → 이메일 주소 | 앱 기능 | 예 | 아니오 |
| 연락처 정보 → 이름 | 앱 기능 | 예 | 아니오 |
| 식별자 → 사용자 ID | 앱 기능 | 예 | 아니오 |

`PrivacyInfo.xcprivacy`에는 B 기준(이메일·이름·사용자 ID·기타 사용자 콘텐츠)이 이미 들어 있다. A를 고르면 매니페스트의 `NSPrivacyCollectedDataTypes`를 비운다.

## 2. 연령 등급 설문

2025년 이후의 새 설문 기준. 값은 API 필드명 그대로.

| 질문 | 답 |
|---|---|
| 만화·판타지 폭력 / 사실적 폭력 / 장기적·잔혹한 폭력 | NONE |
| 비속어·저속한 유머 | NONE |
| 성적 콘텐츠·노출 (일반 / 노골적) | NONE |
| 공포·무서운 주제 | NONE |
| 성인·선정적 주제 | NONE |
| 술·담배·약물 | NONE |
| 총기·무기 | NONE |
| 도박 (실제 / 모의) | false / NONE |
| 경연·콘테스트 | NONE |
| 루트 박스 | false |
| 의료·치료 정보 | NONE |
| 건강·웰니스 주제 | NONE |
| 메시지·채팅 | false (사용자 간 메시지 없음) |
| 사용자 생성 콘텐츠 | false (마켓플레이스 숨김) |
| 소셜 미디어 | false |
| **무제한 웹 접근** | **true** (주소창이 있는 WKWebView 브라우저) |
| 보호자 제어 | false |
| 광고 | false |
| 연령 확인 | false |
| 키즈 연령대 | 없음 |
| 등급 상향 조정 | NONE |
| 한국 GRAC 등급 | 해당 없음 (게임 아님) |

결과: 무제한 웹 접근 하나로 **17+** (새 체계 표기는 **18+**). 대표가 정한 17+와 같다.

## 3. 수출 규정(암호화)

- `ITSAppUsesNonExemptEncryption = NO`가 Info.plist에 있어 제출 시 암호화 질문이 생략된다.
- 근거: 앱이 쓰는 암호화는 Apple 제공 TLS(URLSession·WKWebView)와 Keychain뿐이다. 독자 알고리즘이나 서드파티 암호화 라이브러리 없음. 프랑스 추가 신고 불필요.

## 4. 스토어 문구

이미 App Store Connect `ko`에 올라가 있는 문구(`fastlane/metadata/ko/`)는 담백한 편이라 그대로 둔다. 바꿔야 할 곳만 적는다.

- **앱 이름**: 현재 레코드는 `bandal`. 한국 스토어 노출을 생각하면 `반달`이 맞다. 유일해야 하므로 이름 변경이 거부되면 `반달 – PDF 필기와 노트` 형태로 간다. → 대표 결정.
- **설명 "저장과 계정" 단락**: 계정을 숨기면(1-A) 아래 두 줄로 교체.
  > 저장
  > - 모든 자료는 iPad 안에 저장되며 로그인 없이 바로 사용할 수 있습니다.
- **카테고리**: 주 카테고리 교육(Education), 부 카테고리 생산성(Productivity). 현재 비어 있음. → 대표 확인.
- 키워드, 부제, 프로모션 문구, 지원 URL(`https://bandal.io`), 처리방침 URL(`https://bandal.io/privacy`)은 그대로.

## 5. 심사 메모 (App Review Notes)

현재 `fastlane/metadata/review_information/notes.txt`. 로그인을 숨기면 "로그인은 선택 사항입니다…" 단락을 삭제하고 아래로 바꾼다.

> 이 버전에는 계정, 동기화, 구독, 결제가 없습니다. 모든 자료는 iPad 안에 저장됩니다.

나머지(핵심 기능 확인 순서, AI는 BYOK라 건너뛰어도 됨, 브라우저 때문에 17+)는 유지. 테스트 계정은 필요 없다.

심사 연락처는 App Store Connect에 아직 없다(`appStoreReviewDetail` 비어 있음). **이름(성·이름)과 전화번호**가 필요하다. 이메일은 `hi@bandal.io`.

## 6. 개인정보 처리방침

- 사이트: `https://bandal.io/privacy`(ko), `/en/privacy`(en) 둘 다 200. 현재 게시본에는 iPad 항목이 없다.
- 초안: bandal-web PR #1 (`release/ipad-privacy`, 미배포). 추가 내용: 4절 iPad 앱(기기 저장, 선택 로그인, 녹음 기기 내 처리, 캘린더, BYOK AI, 브라우저, 분석 없음, 계정 삭제), 8절 처리 위탁·국외 이전, 9절 보유 기간, 10절 개인정보 보호책임자(크런치맬로 대표이사, hi@bandal.io).
- 계정을 숨기면(1-A) 4절의 "로그인은 선택 사항이며…" 항목과 "계정은 설정 → 계정 → 계정 삭제…" 항목을 "iPad 앱 1.0은 계정·동기화·마켓플레이스를 제공하지 않습니다"로 합친다.
- 배포는 대표 확인 후 PR 머지.

## 7. 3단계에서 API로 설정할 값 (확정 후)

- 가격: 무료 (`appPriceSchedule`, 기준 지역 KOR, price point 0).
- 지역: 175개 중 EU 27개국 제외 148개 (`territories-keep.json`).
- 출시 방식: 현재 `releaseType = AFTER_APPROVAL`(승인 즉시 자동 출시). 3단계에서 `MANUAL`로 PATCH해야 "심사 승인 후 수동 출시"가 된다.
- 빌드 연결: 업로드 후 `appStoreVersions/{id}/relationships/build`.
- 제출: `reviewSubmissions` + `reviewSubmissionItems`.
