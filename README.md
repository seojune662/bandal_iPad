# 반달 for iPad

iPadOS 18 이상에서 실행하는 Swift 기반 학습 앱입니다. 네이티브 PDF/Pencil 입력,
여러 웹·노트 탭, 2분할 작업 공간과 로컬 저장·동기화를 구현한 개발 검증 버전입니다.
정식 출시 완료본은 아닙니다. 구현 범위와 남은 검증은 [구현 현황](docs/implementation-status.md)을 확인하세요.

## 실행

필요 환경: macOS, Xcode 26.2 이상, XcodeGen, Node.js 22 이상, pnpm.
앱의 최소 OS는 iPadOS 18.0이며 iPhone과 Mac Catalyst는 대상이 아닙니다.

```sh
pnpm --dir WebEditor install --frozen-lockfile
node Scripts/build-web-editor.mjs
xcodegen generate
open Bandal.xcodeproj
```

Xcode에서 `Bandal` scheme과 iPad를 선택하고 실행합니다. 실제 기기에 설치할 때는
Signing의 Development Team을 설정해야 합니다. 인접한 `../bandal` 저장소의
설치된 편집기 의존성을 재사용할 수도 있습니다. 생성된 웹 번들은 Git에 포함하지 않습니다.

명령행 시뮬레이터 빌드:

```sh
bash Scripts/build.sh
```

처음 실행하면 편집 가능한 안내 노트와 PDF가 열립니다. `+`에서 노트, 브라우저,
AI, 보드, 캘린더, 화이트보드, 녹음, 학습 도구를 열고 탭 메뉴의 **옆에서 열기**로
나란히 배치합니다. 좁은 창에서는 두 영역의 상태를 유지하며 전환합니다.

## 계정과 자료

AI 키는 설정에서 입력하며 기기 Keychain에 저장됩니다. Supabase 계정 세션도
Keychain에만 보관합니다. 외부 웹사이트의 WKWebView에는 앱 브리지를 설치하지 않습니다.

동기화 서버는 [backend](backend/README.md)의 RPC와 비공개 Storage 버킷을 사용합니다.
서버 URL과 publishable 키만 빌드에 넣으려면 아래 선택 명령을 실행합니다.
개인 세션과 서비스 역할 키는 복사하지 않습니다.

```sh
python3 Scripts/configure-public-env.py --desktop ../bandal
xcodegen generate
```

설정에서 Google·카카오 또는 이메일로 연결합니다. OAuth 반환 주소는 기존 데스크톱과
같은 `bandal://auth/callback`입니다. 각 로컬 저장소는 최초 동기화 계정에 묶입니다.
다른 계정으로의 프로필 전환 UI는 아직 제공하지 않습니다.

데스크톱 연결은 [연결 도구](Tools/desktop-bridge/README.md)를 사용합니다.
계정 연결 없이 `.bandalpack`으로도 PDF·노트·필기를 주고받을 수 있습니다.
교환 파일은 iPad 메모리 보호를 위해 원본 합계 64MB 이하로 제한합니다.
큰 원본과 장시간 녹음은 파일 스트리밍 방식의 계정 동기화를 사용합니다.

## 구조

| 경로 | 역할 |
|---|---|
| `App/` | SwiftUI 작업 공간, UIKit/PDFKit/PencilKit, 브라우저, 녹음, 학습 도구 |
| `Packages/BandalCore/` | SQLite·전송 대기열·동기화·충돌 보존·파일 무결성 |
| `WebEditor/` | 앱에 포함되는 React/Milkdown 편집기와 Office/HWP 뷰어 |
| `backend/` | Supabase 마이그레이션 및 서버 검증 |
| `Tools/desktop-bridge/` | 데스크톱 데이터 계약 변환·왕복·앱 통합 |
| `Tests/` | 네이티브 필기·녹음·AI·작업 공간 단위 및 UI 검증 |

문서 ID와 원본 SHA-256을 분리하고 필기는 회전 전 CropBox 기준의 정규화 좌표로
저장합니다. 두 기기의 서로 다른 신규 획은 병합하며 같은 객체의 충돌은 사본으로
남깁니다. 자료 원본·충돌·복구 파일을 자동으로 영구 삭제하는 기능은 없습니다.

## 검증

```sh
xcrun simctl list devices available
BANDAL_DESTINATION='platform=iOS Simulator,id=SIMULATOR_UUID' bash Scripts/test.sh
```

물리 Pencil의 지연·손바닥 접촉과 2시간 복합 녹음은 자동 테스트의 대체 대상이 아닙니다.
실기기 측정 및 출시 기준은 [검증 기록](docs/implementation-status.md)에 구분합니다.

기존 반달 코드의 MIT 고지와 사전의 CC BY-SA/WordNet 고지를 함께 보관합니다.
추가 라이브러리와 모델의 출처는 [서드파티 고지](THIRD_PARTY_NOTICES.md)에 정리했습니다.
