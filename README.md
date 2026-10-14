# 반달 for iPad

반달 데스크톱 **0.84.1의 실제 React·Dockview 화면**을 iPad 앱에서 실행하는 개발 버전입니다. 원본 작업 공간, 20개 설정 화면, CSS·로고·글꼴을 사용하며, Swift 호스트가 파일·SQLite·브라우저·녹음·계정 등 iPad 기능을 연결합니다. 최소 지원 OS는 iPadOS 18.0입니다.

현재 기본 진입점은 `App/BandalApp.swift → DesktopShell`입니다. 초기 SwiftUI 작업 공간과 PDFKit/PencilKit 화면은 기본 화면이 아닙니다. 전체 계획이나 정식 출시가 완료된 상태는 아니며, 실제 계정·학교 사이트·Pencil·장시간 녹음 검증이 남아 있습니다. [구현 현황](docs/implementation-status.md)과 [기능별 연결 감사](DesktopRuntime/docs/feature-parity-audit.md)를 확인하세요.

**현재 설치 빌드는 11입니다(2026-10-14 16:36 KST 일반 실행).** 사용자는 빌드 10에서 획이 그려지는 것을 확인했지만, 쓰는 동안 두께가 불규칙해지는 문제를 보고했습니다. 빌드 11은 필압 변화 완화, 윤곽 연결 개선, Metal 가장자리 처리와 긴 획의 증분 계산을 적용했습니다. 새 획만 공통 `inkVersion: 3`을 사용하며 기존 획의 데이터와 표현은 보존합니다.

**자동 검사와 물리 Pencil 인수는 구분합니다.** 빌드 11은 실제 iPad 32개, iPadOS 18.3.1 시뮬레이터 20개 검사를 통과했습니다. 공통 획 계산·Metal 표시·선과 점 생성·원본 undo/redo·저장·재실행 복원을 포함합니다. UIKit 입력 검사는 격리된 DEBUG fixture의 XCTest 손가락 입력이므로 물리 Pencil의 압력·Scribble·필기감 성공을 뜻하지 않습니다. 빌드 11의 실제 필기감은 사용자 확인 대기이며, 네이티브 PDF는 개발용 비교 옵션으로 유지합니다.

**사용자 자료 보존:** 빌드 11 업데이트 전후 SQLite 무결성 검사와 PDF 18,872바이트, 필기 37행의 모든 열 대조를 통과했습니다. 사용자가 추가한 활성 필기 10개·사각형 1개와 기존 삭제 상태 26행을 보존했습니다. 데스크톱의 새 획 표시·선택·내보내기·동기화 호환 코드도 반영했으며, 기존 설치된 데스크톱 앱에 적용하려면 해당 소스로 다시 빌드해야 합니다.

**이전 오류 조사:** 빌드 4에서 사용자가 PDF를 열 때 빨간 오류 배너가 남는다고 보고했습니다. 키 이름이 없는 `keydown`을 원본 화면에 전달하면 같은 `undefined … t.trim` 오류가 발생하는 경로를 재현해, iPad 입력 경계에서 잘못된 이벤트만 차단했습니다. 정상 단축키·텍스트·한글 조합 입력을 보존하는 WebKit 회귀와 실기기 PDF 자료 목록·필기 도구 검사 2개가 통과했습니다. 빌드 6은 2026-10-14 03:38 KST에 일반 실행했고, 이후 사용자가 **“지금은 상자가 안 뜸”**이라고 확인했습니다. 실제 사용자 오류의 스택은 확보하지 못해 해당 입력 경로가 원인이었다고 단정하지 않습니다. 재발 시 확인할 오류 종류·번들 위치와 잘못된 입력 발생 여부만 기록합니다.

iPadOS 경로 별칭·컨테이너 변경 대응, PDF 터치 대상 교체 처리, PDF.js 로컬 자산·라이선스 193개는 적용했습니다. 기존 PDF 바이트·필기 7획 보존도 별도 백업 대조로 확인했습니다. Apple Pencil 직접 필압·팜 리젝션 검증은 남아 있습니다.

## 빌드와 실행

필요 환경은 macOS, Xcode 26.2 이상, XcodeGen, Node.js 22 이상, pnpm 9.15.4입니다. Xcode가 공식 sherpa-onnx 1.13.8 Swift 패키지를 내려받습니다. iPhone과 Mac Catalyst는 대상이 아닙니다.

```sh
pnpm --dir DesktopRuntime install --frozen-lockfile
node DesktopRuntime/scripts/build.mjs
xcodegen generate
open Bandal.xcodeproj
```

Xcode에서 `Bandal` scheme과 iPad를 선택해 실행합니다. 실기기 실행에는 Signing의 Development Team 설정이 필요합니다. 원본 데스크톱 버전 0.84.1과 iPad 배포 버전 0.1.0은 서로 다른 버전입니다.

canonical 빌드 명령은 `node DesktopRuntime/scripts/build.mjs`입니다. 원본 스냅샷과 PDF 자산을 검증하고 renderer, backend, 미리보기 worker, 패키지 무결성을 순서대로 처리합니다. renderer만 다시 빌드하면 출력 폴더의 backend가 지워지므로 전체 명령을 사용하세요. `DesktopRuntime/node_modules`가 없으면 기존 `../bandal/node_modules`를 재사용하는 개발 경로도 있지만, 독립 환경에서는 위의 잠금 파일 설치를 사용합니다.

명령행 시뮬레이터 빌드:

```sh
bash Scripts/build.sh
```

## 구조

| 경로 | 역할 |
|---|---|
| `DesktopRuntime/upstream/` | 데스크톱 0.84.1 스냅샷. 1,019개 파일의 해시·바이트 수를 manifest로 검증 |
| `DesktopRuntime/renderer/` | 원본 엔트리 앞에 설치하는 WK IPC와 입력·파일·녹음 등의 플랫폼 어댑터 |
| `DesktopRuntime/backend/` | 원본 저장소·서비스를 JavaScriptCore에서 실행하는 어댑터, 동기화 투영·이전 데이터 이행 |
| `App/Desktop/` | WK 셸, 외부 브라우저, 실제 SQLite·파일·Keychain·AVFoundation·계정·메일·알림 등 Swift 연결 |
| `Packages/BandalCore/` | 공통 동기화 레코드·전송 대기열·충돌·자산 무결성 |
| `backend/` | Supabase 동기화 스키마와 별도 PPT 변환 서버 |
| `Tests/` | 실제 SQLite·WK·오디오 파일을 사용하는 단위 테스트와 원본 화면 XCUITest |

원본 스냅샷을 직접 수정하지 않고, 소스 구문을 확인하는 빌드 변환으로 iPad 입력과 연결부를 적용합니다. PDF는 원본 PDF.js 뷰어·필기 도구를 기본으로 사용하며, DEBUG 실험실에서 PDFKit/UIKit/Metal 본문을 비교할 수 있습니다. 새 본문도 원본 필기 객체·저장·실행 취소를 사용합니다. 노트와 화이트보드는 원본 편집기입니다. 외부 웹사이트는 별도 WKWebView에 표시하며 앱 IPC를 노출하지 않습니다.

## 계정·저장·기존 데이터

AI API 키와 계정 토큰은 Keychain에 보관합니다. 브라우저 로그인·쿠키는 프로필별로 분리하고 일반 콘텐츠 동기화에 넣지 않습니다. 원본 계정 화면에는 동기화 상태와 충돌 사본 처리가 연결되어 있습니다. 실제 두 기기의 계정 동시 편집·네트워크 단절 검증은 아직 출시 조건입니다.

Supabase 서버 설정은 [backend 안내](backend/README.md)를 따릅니다. 기존 데스크톱의 공개 설정만 빌드에 넣는 선택 명령은 다음과 같습니다. 개인 세션이나 서비스 역할 키를 복사하지 않습니다.

```sh
python3 Scripts/configure-public-env.py --desktop ../bandal
xcodegen generate
```

초기 iPad 버전의 `Documents/Bandal` 자료는 새 `Documents/BandalDesktop` 저장소로 복사·검증한 뒤 이행합니다. 원본은 삭제하지 않으며 이행 영수증으로 중복 적용을 막습니다. 실제 백업 복사본에서 현재 필기 **7획과 삭제 ID 11개**를 포함해 PDF·노트·필기 보존 및 반복 실행 안전성을 확인했습니다.

빌드 4 설치 후 백업에서도 SQLite 무결성 검사 통과, 기존 PDF 18,872바이트와 SHA-256 동일, 필기 7개 행의 모든 열이 빌드 3 검증본과 동일함을 확인했습니다. 초기 자동 검사와 일반 실행 관찰에서는 새 renderer 오류가 없었지만, 이후 사용자의 오류 배너 보고가 있어 정상 사용 완료의 근거로 삼지 않습니다.

[후속 화면 상태 이행](DesktopRuntime/backend/legacy-view-state.ts)은 이전 탭 순서·분할·포커스·선택 과목과 검증된 PDF 페이지를 원본 저장 형식으로 복원합니다. 현재 원본 UI에서 저장한 값은 덮어쓰지 않고, 비공개·삭제·문서 불일치 등 제외 상태는 보관본과 이유를 남깁니다. 원본 API와 WebKit Dockview fixture 검증을 통과했으며, 빌드 4에서는 기존 사용자 자료를 초기화하지 않고 여는 실기기 검사도 통과했습니다. 이전 PDFKit의 세부 스크롤 좌표·배율은 이행 범위에 포함하지 않습니다.

Google 메일의 iOS OAuth 설정과 인증된 구형 `.ppt` 변환 서버는 아직 준비되지 않은 외부 조건입니다. 코드 연결을 실제 로그인·변환 완료로 보지 않습니다.

## 검증 실행

원본·패키지 및 플랫폼 타입 검사:

```sh
pnpm --dir DesktopRuntime run verify
pnpm --dir DesktopRuntime run typecheck
pnpm --dir DesktopRuntime exec playwright install chromium webkit
pnpm --dir DesktopRuntime test
pnpm --dir DesktopRuntime run test:backend
pnpm --dir DesktopRuntime run test:pencil
pnpm --dir DesktopRuntime run test:browser
pnpm --dir DesktopRuntime run test:settings
pnpm --dir DesktopRuntime run test:ink
pnpm --dir DesktopRuntime run test:workspace
pnpm --dir DesktopRuntime run test:pdf-export
```

네이티브·원본 화면 테스트는 canonical 빌드 후 사용 가능한 iPad 시뮬레이터를 지정합니다.

```sh
xcrun simctl list devices available
node DesktopRuntime/scripts/build.mjs
xcodegen generate
xcodebuild -project Bandal.xcodeproj -scheme Bandal \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath .derivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO test
```

코어·호환 도구·renderer 검사와 Xcode 테스트를 함께 실행하려면 `BANDAL_DESTINATION='platform=iOS Simulator,id=SIMULATOR_UUID' bash Scripts/test.sh`를 사용합니다. 뒤에 `-only-testing:BandalTests/DesktopBrowserMemoryTests`처럼 Xcode 선택 인자를 붙일 수 있습니다. Node backend fixture의 SQLite 바인딩도 `DesktopRuntime` 잠금 파일에 고정되어 있습니다.

통과한 범위와 실패 후 재검증 기록은 [구현 현황](docs/implementation-status.md)에 배치별로 기록합니다. 화면 표시, 원본 코드 연결, 시뮬레이터 테스트, 실서비스 성공은 서로 다른 검증입니다.

기존 반달의 MIT 고지와 사전·모델·추가 라이브러리 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 정리했습니다.
