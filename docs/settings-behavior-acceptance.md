# 설정 동작 검증 기록

현재 기준은 원본 `SettingsApp`의 20개 분류와 `TabsSettingsPanel`의 6개 하위 탭이다. 화면이 열리거나 IPC handler가 존재하는 것은 기능 완료의 증거로 사용하지 않는다.

`settings-control-inventory.json`에는 실제 컴포넌트 import 그래프와 iPad 변환 후 JSX에서 추출한 231개 컨트롤 선언이 있다. 여기에는 실험실에 합성한 DEBUG 전용 PDF 비교 컨트롤 1개가 포함된다. 동적 목록의 선언 하나는 실제 계정·프로필·모델별 모든 행을 대신하지 않는다. `node DesktopRuntime/scripts/settings-inventory.mjs --check`로 코드 변경에 따른 누락을 찾고, 변경 시 재생성한다. 각 컨트롤의 최종 인수 상태는 아직 미검증이며 아래 회귀 증거는 검사한 경계에만 적용한다.

판정은 **통과 / 실패 / 미검증 / 플랫폼 제한 / 외부 설정 대기**로 구분한다. 한 항목이 통과하려면 조작, 저장, 소비 화면의 실제 효과, 재실행, 실패·취소·복구, 손·키보드 접근을 확인해야 한다. 실계정·사용자 자료의 수정/삭제 테스트는 수행하지 않는다. 파일 초기화·쿠키 삭제·계정 전환은 격리된 자료에서 검사한다.

## 이번에 확인하고 수정한 결함

| 항목 | 수정 | 회귀 증거 | 남은 실기기 확인 |
|---|---|---|---|
| 탭 → 녹음 기본 마이크 | 웹 마이크 API를 사용하던 설정을 AVAudioSession 장치 목록과 변경 이벤트에 연결 | 실제 원본 React 설정에 웹 마이크 API 접근을 금지한 WebKit 검사 통과. 네이티브 UID 저장 및 USB 목록 변경 확인 | 실제 USB·Bluetooth 마이크 연결/해제와 녹음 입력 |
| 탭 → 녹음 모델 | 설정 표시와 녹음 시작이 같은 iPad 모델 정규화를 사용 | 최초 Zipformer 선택 표시, SenseVoice 변경·저장, 모델 다운로드 요청 ID 확인 | 실기기 모델 다운로드·취소·오프라인 전사 |
| 시스템 권한 | 마이크·캘린더 항목, 권한 요청, 거부 시 설정 이동, 복귀 시 새 상태 조회 | 실제 React 상태 갱신 및 요청 구분 WebKit 통과. Swift 핸들러 주입 테스트 작성 | 실제 OS 프롬프트·거부·재허용; Swift 테스트 실행 결과는 통합 빌드 기록 참조 |
| 달력 권한 복귀 | Mac/macOS 전용 안내를 iPad 설정 안내로 변경하고 foreground 복귀 시 상태 재조회 | 실제 WebKit에서 거부→설정 이동→허용 상태 재조회, 선택/저장 실패/연결 해제 검사 | 실제 EventKit 사용자 캘린더 접근 |
| 시험 알림 | 권한 거부를 미지원으로 잘못 표시하던 경로 수정. 최초 요청/거부/설정에서 재허용 구분 | WebKit에 복구 안내 표시. Swift handler는 OS 권한/스케줄 경계 주입으로 요청 중복·거부·재허용·실패 검사 | 실제 OS 수신/권한 prompt |
| HTML 북마크 | 파일 picker, 선택 프로필 유지, 원본 parser/repo로 URL·중복 처리, 일괄 저장 | SQLite rollback/용량·항목 한도/부정 URL, WebKit 성공·취소·실패·프로필 귀속 | Files 앱 실제 선택과 브라우저 열기 |
| 브라우저 기본 확대 (빌드 8 이후 수정) | 설정에는 125%가 표시되지만 신규 native guest에 명령을 보내지 않아 본문이 100%였던 누락 수정. 원본 `BrowserSettings.defaultZoomLevel`의 새 탭 기본값 계약에 따라 최초 값을 캡처하고 native 성공 후 tab 값을 확정. 기존 tab의 명시 배율은 유지 | 실제 원본 BrowserGuestView/nativePageHandle + WebKit에서 신규·비공개·재시작·재탐색·재마운트·명시 100%·native 실패 안내/미확정/재시도 검사. `LearningBrowser9b` iPadOS 18.3.1 시뮬레이터에서 실제 backend 설정 재조회→WKWebView.pageZoom 소비·재탐색·기존 100% 보존 통과 | 다음 빌드 설치 후 실제 사이트 시각 확대. 현재 사용자 기기의 빌드 8에는 이 후속 수정이 포함되지 않음 |
| Chromium 확장 | 실행할 수 없는 설치 버튼 비활성화 및 미지원 이유 사전 표시 | WebKit에서 설명 표시·버튼 비활성·설치 호출 없음 확인 | 좁은 화면·VoiceOver 설명 읽기 |
| 고급·개인정보·정보 | iPad 자료 폴더를 macOS 홈 경로로 축약하던 표시 수정, 로그·진단의 실제 미리보기 동작 안내, 진단 실패 사유 보존, iPad 업데이트 경로 안내 | 실제 원본 React에서 경로 선택/취소/오류, 초기화 확인/취소/실패 후 재시도, 로그/캐시 호출, 진단 성공 후 실패 시 기존 결과 보존, KO/EN 배포 안내 WebKit 통과 | 실제 Files 접근·Quick Look 공유·배포 채널 업데이트 |
| 개발용 PDF 비교 | native DEBUG capability가 허용한 경우에만 실험실에 toggle 표시. 저장 후 PDF를 다시 열어야 적용됨을 안내 | 실제 React의 조회/저장/저장 실패 시 원상태/재진입 조회, Release·native 조회 실패 시 숨김 WebKit 통과. 셸 reload·PDF 자동 종료 요청 없음 | 실제 Native Host flag 저장과 PDF 재열기 효과는 기기 검사로 확인 |

## 컨트롤별 인수 매트릭스

아래 행 안의 쉼표로 구분한 컨트롤은 각각 독립적으로 검사한다. 실제 선언의 파일·컴포넌트·위치는 JSON 목록을 사용한다.

| 분류 | 검사할 컨트롤 / 성공 기준 | 현재 증거와 최종 상태 |
|---|---|---|
| AI 엔진 | 3개 제공자, 키 등록·교체·삭제, 모델·실행 환경 설명. 실제 자료 질문, 스트리밍·취소·인증 실패·재연결 | 기존 제공자 서비스 단위 검사. 유료 실계정 통합 **미검증** |
| 화면 도우미 | 반달 화면 캡처, 영역 선택·취소, 첨부 및 현재 자료 AI 연결, 권한 바로가기 | 앱 내부 캡처 검사 존재. 타 앱 읽기/조작은 **플랫폼 제한** |
| 계정 | 로그인·취소·로그아웃, 닉네임, 세션 복원, 다른 계정 자료 격리 | 기존 계정 서비스 검사. 실제 로그인 왕복 **미검증** |
| 일반 | 언어 2종, 현재 탭 옆 삽입, 마지막 과목 복원, 온보딩 다시 보기, 튜토리얼 다시 보기 | 실제 언어 전환·실패 복구, 튜토리얼 기록 보존, 시작 안내 재설정, 과목 store 마지막 과목 복원/비복원·종료 전 flush **통과**. 실제 앱 재실행·온보딩 전체 흐름 **미검증** |
| 학교 | 학교 선택·검색, 서비스 추가·수정·삭제·정렬, 표시할 즐겨찾기. 사이드바·메일 서비스에 반영 | 실제 학교 store 선택·서비스 숨기기/복원 및 위젯 메일 선택지 반영 **통과**. 모든 학교 검색/커스텀 편집 UI **미검증** |
| 플러그인 | 설치·활성·설정·초기화·제거, 카탈로그 검색/실패, 학습 팩 import/실행, HTTPS MCP 연결/테스트/삭제 | 팩·MCP·카탈로그 서비스 검사 존재. UI 전체 왕복 **미검증**. 로컬 Node/stdio **플랫폼 제한** |
| 달력 | 연결·해제, 캘린더 선택, 표시·내보내기 설정, 권한 이동, 과제 중복 없이 일정 반영 | 실제 UI 연결·선택·저장 실패/권한 복구, 실제 backend 서비스의 표시 필터·읽기전용 거절·재시작 영속·종일 종료일·중복 없는 재내보내기·빈 선택 재연결·해제 시 일정 보존 **통과**. EventKit OS 경계는 fixture이며 실캘린더 왕복 **미검증** |
| 브라우저 | 프로필 추가·수정·삭제, 홈페이지 저장·유효성, 검색엔진, 기본 확대, 링크 처리, 스와이프, 팝업, 추적 보호, DNT, 사이트별 쿠키/저장소/권한 제거, AI 접근권한·감사 | backend 저장·잘못된 URL 거절·재실행 **통과**. 기본 확대는 빌드 8 이후 누락 수정 및 원본 guest가 실제 native 명령을 내보내는 WebKit 경계 **통과**, 실패 후 재시도·기존 tab 보존 포함. 실제 WK 적용 XCTest 실행은 별도 기록. 모든 설정의 실사이트 효과 **미검증** |
| 브라우저 가져오기 | HTML 북마크/CSV 파일 선택·취소·확인·중복, 프로필별 반영; 다른 앱 저장소 직접 읽기와 구분 | HTML parser+실제 SQLite repo와 WebKit 프로필 귀속/취소/오류 **통과**. 네이티브 picker 경계 XCTest 존재, 실제 파일 선택 왕복 **미검증**. 타 앱 저장소 직접 읽기 **플랫폼 제한** |
| 화면 | 시스템·밝음·어두움, 글자 크기 4단계, 편집기 글꼴 3종, 밀도 2종. 현재 모든 탭 즉시 적용·재실행 유지 | backend 변경·재실행, 실제 화면 controls와 applyTheme의 theme/fontScale/editorFont/density DOM 효과, 시스템 테마·키보드 선택 **통과**. 모든 탭 시각 비교·VoiceOver **미검증** |
| 탭 → Markdown | 본문 글꼴·제목 접두어, 저장·빈 값; 열린 노트 글꼴과 신규 파일 이름 적용 | 원본 UI 저장·backend 재실행, 원본 createMarkdownTab이 변경 접두어로 notes:create를 호출하고 실제 Dockview 노트 탭 생성 **통과**. native 파일 picker와 무관한 메모리 IPC fixture 경계는 별도 실제 notes repo 검사로 확인 |
| 탭 → 브라우저 | 브라우저 분류와 같은 패널/설정 값, 하위 탭 전환 | 하위 탭 접근 **통과**. 전체 브라우저 효과와 함께 인수 |
| 탭 → AI | AI 분류와 같은 제공자 상태/키 설정, 하위 탭 전환 | 하위 탭 접근 **통과**. 실제 AI 통합과 함께 인수 |
| 탭 → 녹음 | 네이티브 마이크, 모델 선택·다운로드·취소, 속도 6종, 설정 패널 열기, 자막 자동 따라가기 | WebKit 저장·반영·UID·모델·장치변경 **통과**. 실제 오디오/장시간은 **미검증** |
| 탭 → 화이트보드 | 격자·점·줄·빈 배경. 새 보드에 적용하고 기존 보드는 보존 | 원본 UI 저장 + 실제 repo 신규 점 배경 + 초기화 후 기존 배경 보존 **통과** |
| 탭 → 학업 보드 | 캘린더/칸반 시작 화면, 완료 항목 숨기기 | UI 저장·실패 + backend 재실행 + 원본 BoardPanel 목록 시작/완료 숨김·해제 시 실제 task 행 표시 **통과**. 실기기 시각·입력 검사는 남음 |
| 탭 공통 | 현재 탭 옆 열기·마지막 과목 복원, 단축키 변경 이동 | 두 toggle 저장·재실행, 실제 Dockview 그룹 탭 순서(현재 다음 삽입/끝 추가), 실제 coursesStore 마지막 과목 복원/비복원·종료 전 기록 **통과**. 실기기 프로세스 종료 후 복원 **미검증** |
| 위젯 | 투두·보드·메일 켜기/끄기, 순서·전체 끄기, 활성 위젯, 학교 메일/직접 URL | 실제 UI의 순서·전체 끄기·활성 대체·학교 메일 연동 및 backend 영속·잘못된 URL 거절 **통과**. 메일 OAuth **외부 설정 대기** |
| 알림 | 전체, 마감, 선행 1/3/7일, AI 완료, 다운로드, 플러그인, 소리, 포커스 억제, 시험 알림 | 실제 UI 토글·선행일·전체 끄기 시 disable·시험 알림/거부 안내, backend 영속 및 기존 네이티브 서비스 설정 반영 검사. OS 수신·권한 거부 후 복구 **미검증** |
| 단축키 | 각 액션 변경/해제/초기화·충돌, 앱/사이트 우선순위, 키보드 입력·텍스트 편집 충돌 방지 | backend 저장 + 기존 브라우저 단축키 서비스 검사. 모든 설정 조합 실제 키보드 **미검증** |
| 사용 통계 | 기간·제공자 선택, 실제 요청 후 사용량·토큰·시간, 빈 결과·오류 | 기존 ledger 검사. UI-실요청 연결 **미검증** |
| 시스템 권한 | 알림·마이크·캘린더 요청/상태/설정/복귀 갱신, 적용 불가 항목 설명 | 이번 WebKit 회귀 **통과**. OS 경계는 통합 실기기 검사 필요 |
| 개인정보·진단 | 진단 파일 생성·열기·공유·취소, 민감정보 가림, 오류 표시 | 기존 진단 정보 제한 검사 및 실제 UI 성공/네이티브 오류 안내·이전 결과 보존 **통과**. 계정 동기화·AI 전송 경로를 안내에 반영. Quick Look 자체와 공유 창 저장 왕복 **미검증** |
| 고급 | 자료 폴더 선택/취소/재접근, 로그 보기, 캐시 제거, 설정 초기화 확인/취소 | actual backend 초기화 시 자료·기존 보드 보존, 저장 실패 rollback 및 실제 UI 폴더 취소/실패·원래 경로 보존, 로그/캐시 요청, 초기화 확인/취소/실패 후 재시도 **통과**. Files·Quick Look·캐시 삭제는 해당 UI 검사에서 native IPC fixture이며 실제 외부 폴더 재실행 **미검증** |
| 실험실 | 지원 옵션 효과, 로컬 확장 런타임 설명·비활성, DEBUG PDF 비교 | 로컬 실행 **플랫폼 제한**. DEBUG 비교 toggle 조회/저장/복구/Release 숨김은 실제 UI+native fixture **통과**, 실제 PDF 재열기 효과 **미검증** |
| 과목 | 보관 항목 표시, 보관·복원, 선택 과목·자료·탭 연결 유지 | 실제 coursesStore 보관 시 활성 과목 대체·복원 후 정렬 유지 **통과**. 모든 과목 관리 UI·원본 자료 보존 왕복은 **미검증** |
| 정보 | 실제 버전·빌드 확인, 도움/라이선스 링크, iPad 배포 방식 안내 | 실제 UI가 native 경계에서 전달한 버전을 표시하고 KO/EN App Store·TestFlight·개발 빌드 안내를 표시, desktop update 호출 없음 **통과**. 실제 배포 채널 업데이트 **미검증**, desktop auto updater **플랫폼 제한** |

## 재현 가능한 검사

- `node DesktopRuntime/scripts/test-settings-controls.mjs`: 원본 컴포넌트 + iPad 변환을 실제 WebKit에서 실행. 네이티브 경계는 통제된 fixture이며 유료 제공자·사용자 계정은 호출하지 않는다. 원본 stores/탭 명령/BoardPanel와 실제 DockviewReact를 함께 실행해 저장 값을 소비하는 경로도 확인한다. AppearancePanel callback→settings bridge는 fixture이고 실제 DOM 적용 함수는 원본이다.
- `node DesktopRuntime/renderer/browser/test-default-zoom.mjs`: 실제 원본 BrowserGuestView/nativePageHandle/settingsSnapshot/store를 WebKit에서 실행. native IPC와 저장소는 fixture이며, 기본 배율 명령·100% 재적용·실패 시 미확정/안내·재시도·재실행을 확인한다. `BrowserDefaultZoomTests`는 실제 backend 설정 영속/재조회와 Swift 명령의 WKWebView.pageZoom 효과·문서 재탐색·기존 100% 보존을 검증한다. 서로 다른 두 경계 검사이며 앱 전체 실기기 시각 확대 검사를 대신하지 않는다.
- `node DesktopRuntime/backend/test-backend.mjs --settings-controls`: 현재 backend bundle을 임시 SQLite/파일 저장소에서 실행. 재시작·실제 신규 보드·쓰기 실패·초기화의 자료 보존을 확인한다. 달력은 실제 backend/원본 서비스/파일 저장을 실행하고 EventKit 결과만 fixture로 주입한다. 일정 생성/조회는 사용자 캘린더에 쓰지 않는다. 검사한 bundle SHA는 통합 빌드 증거와 함께 기록한다.
- `node DesktopRuntime/scripts/test-bookmark-import.mjs`: 실제 SQLite favorites repo와 원본 북마크 parser의 프로필 격리·안전 URL·중복·용량/항목 한도·쓰기 실패 일괄 rollback.
- `DesktopBookmarkImportTests`: 실제 Swift picker 서비스의 파일 타입·크기·인코딩·취소·프로필 삭제 race·진행중 프로필 삭제 guard. OS picker 자체는 주입 경계.
- `DesktopPermissionTests`: 실제 Swift IPC handler의 OS 호출 경계를 주입하여 허용/거부·설정 복귀·잘못된 ID·설정 열기 실패를 검사한다.
- `SettingsRoutesTests`: 20개 분류에 더해 6개 하위 탭을 실기기에서 열어 렌더러 오류를 확인한다. 이 검사는 컨트롤의 실제 효과를 대신하지 않는다.
- `node DesktopRuntime/scripts/test-workspace-mixed.mjs`: 원본 `descriptorFor`/검증기/workspace store/DockviewReact로 PDF 5·노트 5·브라우저 4·화이트보드 3·녹음 2·보드 1을 두 그룹에 열어 저장한다. WebKit 렌더러 재시작 후 저장한 레이아웃을 다시 읽어 ID·payload·제목·순서·활성 탭·브라우저 URL을 비교한다. 탭 본문은 비활성 테스트 경계이며 콘텐츠 엔진·실파일 저장·물리 기기 메모리 경고 통과를 뜻하지 않는다.
- `node DesktopRuntime/renderer/nativePDF/test-history.mjs`: 실제 원본 `useDrawings`와 native journal session을 함께 실행한다. canonical 저장 후 ACK 실패, undo/redo의 v2 메타데이터, tombstone/live 재생, 쓰기 실패 후 재시도, 두 표면 동시 재생의 단일 history를 검증한다. DB/OS 응답은 fixture이며 실제 SQLite receipt 검사는 `test-native-pdf-recovery.mjs`에서 별도로 한다.
