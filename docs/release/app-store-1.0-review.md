# App Store 1.0 심사 준비 점검 (2026-10-18)

무료·로컬 전용 iPad 1.0 출시 기준으로 코드를 읽고 정리한 결과다. 결정 사항: 구독·동기화 문구·마켓플레이스·Gmail은 릴리스 플래그로 끄고 코드는 유지, 연령 등급 17+, EU 27개국 제외.

## 1. 가이드라인별 점검

| 항목 | 가이드라인 | 상태 | 근거 |
|---|---|---|---|
| Sign in with Apple | 4.8 | 통과 | `NativeLoginGate` Apple·Google·카카오 세 가지. Apple은 `DesktopAppleAuthorization` 네이티브 → Supabase `/auth/v1/token?grant_type=id_token` |
| 계정 삭제 | 5.1.1(v) | 통과 | 설정 → 계정 → "계정 삭제" 확인 다이얼로그 → Edge Function `account-delete`. Apple 인가 코드 등록으로 토큰 철회까지 포함 |
| 로그인 강제 여부 | 5.1.1 | 통과 | `requiresLogin`은 기존 계정에 묶인 프로필에서만 true. 미로그인 상태로 앱 전체 사용 가능 |
| 암호화 신고 | 2.5 | 통과 | `ITSAppUsesNonExemptEncryption = NO` 이미 Info.plist에 있음 |
| 구독 패널 | 3.1.1 | **수정** | `NativeSettingsWorkspace.subscriptionPanel`: StoreKit 상품 `app.bandal.ipad.sync.*` 조회, "데스크톱 구독도 적용" 문구. IAP 없이 출시하므로 플래그로 숨김 |
| 동기화 차단 문구 | 3.1.1 | **수정** | `syncPanel`의 "동기화 구독이 필요해요" 문구와 동기화 토글. 1.0은 로컬 전용이므로 패널 전체 숨김 |
| 마켓플레이스 | 2.1 미완성 | **수정** | `NativeStudyMarketClient`는 읽기 전용이고 "준비하고 있어요" 자리표시. 레일 버튼과 화면 숨김 |
| Gmail 연동 | 2.1 / Google 검증 | 조치 불필요 | 네이티브 설정에는 "Gmail API 계정 연결은 이 버전에서 제공되지 않습니다"로 이미 비노출. `DesktopMailService` 코드만 남아 있음 |
| AI 제공자 | 2.5, 5.2.5 | 경미 | BYOK API 키 방식, 사용자 문구는 OpenAI·Anthropic·Google. 내부 rawValue `codex`/`claude-code`는 저장 키라 유지. 설정 검색 키워드 "claude code codex"만 정리 |
| 내장 브라우저 | 연령 등급 | 결정 완료 | 주소창 있는 범용 WKWebView 브라우저 → "무제한 웹 접근" 예, 17+ |
| 개인정보 매니페스트 | ITMS-91053 | **수정** | `PrivacyInfo.xcprivacy` 없음. 아래 2절의 API 사용 |
| 버전 | — | **수정** | 0.1.0 (46) → 1.0.0 (1) |
| 사용자 간 메시지·UGC | 1.2 | 해당 없음 | 공유는 시스템 공유 시트뿐. 마켓플레이스 숨김 후 사용자 생성 콘텐츠 노출 없음 |
| 데스크톱 의존 기능 | 2.1 | 없음 | 모든 기능이 iPad 단독 동작. PowerPoint 변환 서버만 선택적 외부 서비스 |
| 서드파티 SDK | — | 해당 없음 | sherpa-onnx(기기 내 음성 인식), SwiftMath. Apple 지정 SDK 목록에 없음. 분석·광고 SDK 없음 |

## 2. Required reason API 사용

| 카테고리 | 사유 코드 | 사용 위치 |
|---|---|---|
| UserDefaults | CA92.1 | `NativePDFWorkspacePreferences`, `NativeDesktopTheme`, `NativeSettingsWorkspace` 등 앱 설정 저장 |
| 파일 타임스탬프 | C617.1, 3B52.1 | `attributesOfItem`·`lstat`: `NativeLibraryRepository`, `NativeRepositoryContext`, `LocalSpeech`. 앱 컨테이너와 사용자가 문서 선택기로 연 외부 폴더 |
| 시스템 부팅 시간 | — | 사용 없음 |
| 디스크 공간 | — | 사용 없음 |
| 활성 키보드 | — | 사용 없음 |

## 3. 앱 개인정보 라벨 (App Store Connect 입력용)

1.0 로컬 전용 기준. 동기화가 꺼져 있으므로 노트·PDF·필기는 서버로 가지 않는다.

| 데이터 항목 | 수집 위치 파일 | 용도 | 사용자 연결 | 추적 |
|---|---|---|---|---|
| 이메일 주소 | `DesktopAccountService` (Supabase auth user.email) | 앱 기능(계정) | 예 | 아니오 |
| 이름·닉네임 | `DesktopAccountService` (`profiles.nickname`, OAuth metadata) | 앱 기능(계정) | 예 | 아니오 |
| 사용자 ID | `DesktopAccountService` (Supabase user id) | 앱 기능(계정) | 예 | 아니오 |
| 기타 사용자 콘텐츠 (AI 질문·첨부) | `DesktopAIService` → 사용자가 선택한 OpenAI/Anthropic/Google API | 앱 기능 | 아니오 | 아니오 |

Apple 라벨 선택: **연락처 정보 → 이메일, 이름** / **식별자 → 사용자 ID** / **사용자 콘텐츠 → 기타 사용자 콘텐츠**. 전부 "앱 기능" 목적, 추적 없음. AI 항목은 사용자가 직접 키를 넣고 제공자를 고르지만 Apple 정의상 기기 밖으로 나가므로 보수적으로 신고한다.

수집하지 않는 것: 녹음·자막은 sherpa-onnx로 기기 내 처리, 캘린더는 EventKit 로컬, 브라우저 자격 증명과 API 키는 Keychain 로컬, 진단·크래시 로그 없음, 광고 식별자 없음.

## 4. Apple·Supabase 설정 상태 (대표 확인)

- App ID `app.bandal.ipad` 등록, Sign in with Apple 활성.
- Sign in with Apple 키 `AuthKey_472BDSF848.p8`, App Store Connect API 키 `9LX29K24YD` (App Manager). 둘 다 `~/.appstoreconnect/private_keys/`에만 둔다.
- Supabase Apple provider 활성, Client IDs에 `app.bandal.ipad` 포함. 웹 OAuth용 Secret Key는 비어 있음(네이티브 id_token 흐름에는 불필요).
- 이 Mac에는 Apple Distribution 인증서가 없다. 업로드 스크립트가 API 키로 클라우드 서명을 시도하고, 권한 부족이면 Admin 키가 필요하다.

## 5. 남은 수동 작업

1. TestFlight 실기기에서 Apple 로그인·계정 삭제 확인 (지금까지 기기 빌드는 빈 entitlements로 설치돼 미검증).
2. App Store Connect 웹: 개인정보 라벨(3절), 연령 등급(무제한 웹 접근 예 → 17+), 가격 무료, 배포 지역 EU 제외.
3. 심사 메모에 테스트 계정과 "로그인 없이도 전체 기능 사용 가능" 안내.
