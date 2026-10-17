# 데스크톱 소스와 Swift iPad UI 대조

기준일: 2026-10-17. 데스크톱 `/Users/iseojun/dev/bandal`은 참조만 하고 수정하지 않는다. iPad 수정은 `codex/native-ipad-rebuild`에서 진행한다. 스크린샷 유사성이나 기존 테스트 통과를 기능·구조 동일성의 증거로 대신하지 않는다.

최신 build 41은 별도 React 작업본의 PDF 필기 개선을 Swift 화면에 통합했다. 색·굵기·즐겨찾기, 그린 뒤 유지하는 보정, 텍스트 상자와 설치 검증은 [build 41 기록](build41/swift-writing-integration.md)을 참조한다. 아래 데스크톱 구조 대조와 플랫폼 차이는 계속 적용한다.

## 확인된 구조와 교정

| 항목 | 데스크톱 근거 | Swift 구현/검증 대상 |
|---|---|---|
| 가장 왼쪽 rail | `src/renderer/src/app/GlobalNavigation.tsx:32–130` | 과목, 학습, 학업 보드, 문맥 AI, 도구, 마켓플레이스, 도움말, 하단 계정·설정. 브라우저·녹음을 별도 global destination으로 두지 않는다. |
| 과목 펼치기 | `features/courses/CourseListItem.tsx:87–90`, `FavoritesSection.tsx` | 과목 자식은 저장된 favorites. 자료 트리는 오른쪽 MaterialsSidebar에만 둔다. |
| 학교 및 AI 웹 | `features/courses/CourseSidebar.tsx:341`, `UniversityShortcuts`, `AiShortcuts` | 과목 위 학교별 서비스와 ChatGPT·Gemini·Claude 웹 바로가기. 설정의 숨김·순서·외부열기 선택 적용. |
| 과목 그룹 | `CourseSidebar.tsx`, `CourseListItem.tsx` | 그룹 생성·이름·삭제와 과목 이동/색상/보관. 독립 학습 공간은 과목 목록에서 제외한다. |
| 학습/도구 왼쪽 패널 | `features/learning/LearningSpacesPanel.tsx`, `features/launcher/FeatureLauncherPanel.tsx` | 학습 공간 검색/만들기/열기와 저장소 연결, 문서 문맥을 유지하는 도구 실행. |
| 탭 생성 | `features/workspace/NewTabMenu.tsx:279` | 검색 popover: URL(입력 시), 새 마크다운, 새 브라우저 탭, AI, 학습 공간, 녹음, 새 노트, 학업 보드. 검색 시에만 PDF 최대 8개. 하단 링크 즐겨찾기 추가. |
| 탭 바로 아래 내용 | `features/workspace/WorkspaceHost.tsx:319–323` | Swift에서 추가했던 공통 문서 제목+AI 36pt bar 제거. 각 editor 고유 toolbar만 유지. |
| 같은 문서 여러 창 | `features/workspace/tabDuplication.ts`, `features/notes/noteDocChannel.ts` | 저장 문서 ID와 탭 instance ID 분리. PDF/Markdown 명시 복제, 독립 페이지·선택·Undo, 같은 문서 변경 전파. 일반 열기는 기존 탭 재사용. |
| PDF 연결 페이지 필기 | `features/notes/NoteTab.tsx:734–845`, `note-tab.css:212–315` | 원본 PDF 비율의 연속 종이와 페이지별 편집기, 별도 보존 부록, 나란히 열기, 탭별 스크롤 연결/독립. |
| Markdown 새 페이지 | `features/notes/NoteToolbar.tsx:176–208` | slash 명령에서 같은 폴더에 새 파일 생성, wikilink 삽입·저장 후 새 탭 열기. 기존 페이지 연결 picker와 구분. |
| 학습 결과 데이터 | `src/shared/types/learning.ts`, `main/features/learning/learningRepo.ts`, `model.ts` | portable article/artifact/card/quiz/run schema 유지. 결과 저장 성공 후 complete. 카드 간격과 서술형 자기평가 규칙 대조. |
| PDF 형광펜 | `features/ink/InkLayer.tsx:242–244` | opacity × .32 대신 min(opacity, .34). |
| PDF 문서 전환 | Swift lifecycle 대조 | 도구/색/굵기/불투명도를 문서별 저장, flush에서 실제 viewport를 즉시 읽기, 동일 revision의 scroll 복원. |

## 의도적으로 다르게 처리하는 사항

이 표는 데스크톱 결함으로 입증된 항목과 iPad 플랫폼 차이, 아직 구현되지 않은 기능을 구분한다. 확인하지 않은 차이를 데스크톱 버그라고 부르지 않는다.

| 구분 | 항목 | 근거와 처리 |
|---|---|---|
| 사용자의 명시적 이름 변경 | 화이트보드 → 노트 | 데스크톱 NewTabMenu/자료 생성은 아직 화이트보드라 표시한다. iPad 사용자 UI와 새 파일 기본 이름은 노트로 변경한다. 기존 파일명, `whiteboard` 데이터 kind, 채널명은 데이터 호환성 때문에 유지한다. Markdown은 마크다운으로 구별한다. |
| 사용자 요청 — build 40 | iPad 상태막대 | 시간·날짜가 차지하던 시스템 상태막대를 숨기고 작업 영역을 위로 확장한다. 앱 창의 안전 영역은 실제 iPad 화면으로 확인한다. |
| 사용성 개선 — 데스크톱과 다른 정책 | 문서별 PDF 도구 기억 | 데스크톱 `features/ink/inkToolStore.ts:84`의 도구·스타일은 전역, history만 fileKey별이다. iPad는 문서 전환 시 이전 펜/색을 잃지 않도록 문서별로 기억한다. 데스크톱도 같은 정책이라고 주장하지 않는다. |
| 데이터 보존 개선 — 데스크톱 소스 정책 변경 | 페이지 노트 공백 | 데스크톱 `src/shared/pdfPageNote.ts:124–125`의 `cleanPageContent`는 앞 빈 줄과 뒤 공백 전체를 제거한다. 이 정규화를 Swift 실시간 편집에 적용하자 space 입력이 즉시 사라졌다. Swift는 형식이 삽입한 경계 줄바꿈만 해제하고 사용자 공백·빈 줄·들여쓰기를 편집·페이지 재배열·삭제 후에도 보존한다. 데스크톱 실행 중 같은 입력 증상까지 재현했다고 주장하지 않는다. |
| 플랫폼 차이 | 터치 hit target / 좁은 창 | rail·분할 경계는 44pt 조작 영역을 확보한다. 탭 닫기·추가 등 일부 밀집 도구는 데스크톱 배치에 맞춘 32–36pt 폭이다. 좁은 창은 rail drawer와 활성 pane 선택을 사용한다. |
| 플랫폼 차이 | AI transport | 데스크톱 로컬 CLI 대신 iPad API/Keychain을 사용한다. 실제 키가 없으면 연결 오류를 표시한다. AI 웹 바로가기는 API 연결과 별개이다. |
| 플랫폼 차이 | 확장 프로그램·MCP·업데이트 | macOS 실행 파일/Node 런타임/Chromium extension을 iPad에서 실행했다고 표시하지 않는다. 해당 설정에서 가용성을 명시하고 휴대 가능한 설정 데이터는 보존한다. |
| 구현 차이 — 범위 제한 | 복제 가능한 탭 종류 | PDF/Markdown의 동일 파일 복제는 공유 저장 조정까지 구현했다. 다른 문서들을 나란히 도킹하는 기능과 별개로, 노트(whiteboard)·브라우저·AI·녹음의 같은 내용 복제는 아직 제공하지 않는다. 이들 탭의 공유 writer/content scope 설계가 추가로 필요하다. |
| 구현 차이 — 미완료 | 과목 사이 탭 드래그 | 데스크톱 `useWorkspaceCourseHover`·`CourseTabMoveOverlay`는 과목을 넘나드는 드래그를 제공한다. Swift 탭 드래그는 같은 과목의 영역 간 이동·합치기·재배열까지 지원하며, 다른 과목으로 끌어 옮기는 흐름은 아직 제공하지 않는다. |
| build 40 교정 | 열린 탭 목록 검색 | 각 도킹 영역의 검색 가능한 열린 탭 목록에서 선택·닫기를 제공한다. 폭은 `adaptiveTabs.ts`처럼 제목/종류와 무관하게 계산하고, 선택 탭은 항상 표시한다. iPad 최소 터치 폭 44pt와 데스크톱의 32px 차이는 유지한다. |
| 구현 차이 — 수명 | Markdown Undo | 같은 과목의 탭 전환·분할 이동·과목 전환에는 편집기 인스턴스와 Undo를 유지한다. 학습 홈·설정처럼 Dock 전체를 닫는 전역 화면 전환과 앱 재실행에서는 저장된 본문을 복원하며 UIKit Undo 이력은 유지하지 않는다. |
| 구현 차이 — 미완료 | 마켓 거래 | Swift 마켓은 실제 context, 학교·과목·자료 검색, 구매·판매 내역 조회를 연결한다. 거래 생성/결제/판매 번들 게시/구매 자료 가져오기 전체는 아직 동일하지 않다. 서버 준비 상태와 iPad 미구현을 혼동하지 않는다. |
| 구현 차이 — 미완료 | 학습 도구 inventory | iPad 내장 퀴즈·카드·요약·영어 읽기 연결. 데스크톱 사용자 pack 및 Node plugin 실행 전체를 대체하지 않는다. |
| 검증 한계 | 실제 Apple Pencil | 실제 iPad의 XCTest touch를 Pencil fixture로 전달하여 저장·전환 회귀를 검증할 수 있다. 물리 Pencil의 압력·팜 리젝션·체감 지연을 사람이 써봤다고 주장하지 않는다. |

데스크톱 소스의 페이지 본문 공백 정규화는 위와 같이 별도 기록했다. 이전 iPad의 sidebar 구성 오류와 공통 제목bar는 iPad 구현 오류이며 데스크톱 문제로 돌리지 않는다.

## 검증 기록

build 38의 이전 통과 결과는 새 구조의 동일성 증거로 사용하지 않는다. 아래는 build 39 검증이다.

- 전체 단위 850개 실행: 841 통과, 4 skip, Markdown typing Undo 등록 상태 오류로 5개 crash. 해당 오류를 고친 후 실제 `UITextView.insertText`·한글 조합·Undo 경계·복수 탭·복구·페이지 노트·페이지 편집·저장소를 포함한 관련 102개를 다시 실행하여 전부 통과했다. 이후 실기기에서 발견한 반복 문자 입력·초기 종이 레이아웃 회귀 3개를 추가한 최종 105개도 모두 통과했다. 전체 첫 실행을 성공으로 기록하지 않는다.
- 별도 Dock·Markdown 회귀 44개 통과. 이후 명시 복제 위치와 문맥 AI instance 회귀를 추가하여 위 102개 실행에 포함했다.
- 연속 PDF 페이지 Markdown UI: 두 페이지 입력, 띄어쓰기 보존, 원본 PDF 이동, 스크롤 연결 해제, 재실행 복원까지 simulator 및 실제 iPad 통과.
- 실제 iPad Pro 11인치(iPadOS 26.5): 학교 선택·재실행 유지, 설정 검색·가로세로 회전, PDF 페이지 재배열·삭제·Undo·재실행 복원 통과. 실제 화면은 `build39/ipad-school-sidebar.png`, `build39/ipad-settings-portrait.png`, `build39/ipad-pdf-page-editing.png`에 보관했다.
- 실제 iPad에서 사이드바·즐겨찾기·새 탭 메뉴·문맥 AI 패널, Markdown 표·수식, 같은 PDF 두 창의 필기 공유와 독립 도구·페이지·Undo도 통과했다.
- 초기 실기기 PDF 복제 테스트의 학습 화면 확인 실패는 `ScrollView`를 `Other`로 검색한 테스트 오류였음을 접근성 트리에서 확인했다. 수정 후 실기기에서 통과했다. 키보드 숨김 후 남는 접힌 accessory도 일반 키보드와 구분하도록 교정했다. Dock은 Undo 보존을 위해 숨긴 편집기를 유지하므로 테스트는 화면에 표시된 프레임만 센다.
- 실기기 녹화·저장 원문에서 복제 Markdown의 Undo 후 재입력 문자열이 `FFiinal…rst`로 깨지는 것을 재현했다. 동일한 줄바꿈·`F`·`i` 사이에서 최소 문자열 diff의 끝을 커서로 쓰던 것이 원인이었다. UIKit의 실제 편집 범위·치환 문자열·입력 전 선택으로 처리하고 fallback에서도 실제 UIKit 선택을 사용한다. 실제 `insertText`로 매 키의 원문·커서·다른 창 전파·Undo/Redo를 검사한다. Undo가 문서 중간의 원래 삽입 위치로 돌아가는 정상 동작과 이 입력 손상을 구분한다.
- 실제 화면에서 학습 sidebar의 새 학습 버튼 글자 대비, 좁은 페이지 노트의 저장 상태 잘림, 처음 입력한 종이의 줄바꿈·가로 여백·페이지 번호와 본문 겹침을 확인했다. 버튼 전경색, compact header, 제안된 종이 크기 및 UIKit text container 폭·inset을 수정했다.
- 최종 소스 관련 105개 단위/통합 검사 로그: `/tmp/bandal39-final-input-layout-unit.log`. 실제 iPad 도킹 재검증(4영역·드래그·크기 조절·합치기·재실행·세로 영역 선택) 및 두 PDF+Markdown의 필기·도구·viewport·탭 이동·재실행 복원은 `/tmp/bandal39-device-recheck-ui.log`에서 통과했다.

### 추가 소스 대조

- build 39 당시 Markdown의 파일명/저장 상태 줄은 데스크톱에도 있어 유지했다(`NoteTab.tsx:1634`). 이후 사용자가 이 줄도 명시적으로 제거하도록 요청하여 build 40에서는 파일명·상시 저장 상태를 없애고 페이지 이동·연결과 문서 작업을 기존 서식 도구막대 한 줄에 합친다. 데스크톱에 없는 변경이라고 구분한다.
- 편집기 확대는 전체 UI fontScale과 독립이다. 데스크톱 `noteZoom.ts` 값 `[0.875, 1, 1.125, 1.25, 1.5]`을 적용한다.
- 데스크톱 `assistantController.ts:67`은 현재 문서의 기존 대화를 드러낸다. Swift도 문서별 패널/대화 선택을 유지하고 현재 문서·선택 텍스트를 요청에 연결한다.
- AI/녹음 즐겨찾기는 탭 UUID가 아닌 실제 conversationId/recordingId를 보존한다.
- AI 웹 바로가기의 세 provider 로고는 `ProviderMark.tsx`의 벡터 도형을 native asset catalog에 넣어 표시한다. React component나 web renderer를 실행하지 않는다.
- skinny 학업 보드는 기존 문서 위 전역 overlay로 열고, `+`의 학업 보드는 과목 탭으로 연다.
- PDF viewport 응답의 CGFloat를 Double로 정규화했다. 직접 Swift 호출자가 scroll progress를 읽지 못해 실제 저장이 누락되는 오류였다.
- 실기기 설치 전 build38 데이터 백업: `/Users/iseojun/.codex/device-backups/bandal-before-build39-20261017/manifest.json`, 71개 파일·26,400,987 bytes, 6개 SQLite quick_check 정상.

- 학습 갱신 수정 전 실기기 4개 UI 검사는 자동 통과했지만, 학습 공간 생성 캡처에 “선택한 과목을 찾을 수 없습니다” 경고가 남아 있었다. 생성된 이름만 검사해 놓친 문제로, 학습 공간 열기와 재실행 복원·경고 없음까지 UI 검사를 강화했다. 원인은 생성 직후 `courses:changed` 갱신과 명시적인 선택 조회가 겹치면 token 검사 때문에 목록 반영 없이 먼저 반환하는 경쟁 상태였다. 조회부터 목록·선택 파일 반영까지 FIFO로 완료하도록 수정했고, 이전 동작의 결정적 재현과 수정 코드 100회 반복·실패 후 재시도를 검증했다. 이 초기 통과를 학습 공간 열기 성공으로 기록하지 않는다.
- 수정 후 복제 Markdown의 Undo→재입력→저장·재실행, 연속 페이지 Markdown의 여백·줄바꿈·페이지 연결, 표·수식은 실기기 재검증과 캡처 검토를 통과했다(`/tmp/bandal39-device-final-fixes-ui.log`).

- 학습 갱신 수정까지 포함한 최신 소스 관련 단위/통합 110개가 전부 통과했다(`/tmp/bandal39-final-learning-unit.log`). 초기 전체 실행의 5개 crash 기록은 그대로 남기며 전체 suite 재실행 성공으로 바꾸지 않는다.

- 강화한 사이드바·학습 UI 검사도 실제 iPad에서 통과했다(`/tmp/bandal39-device-learning-final-ui.log`): 새 독립 학습 공간이 오류 없이 실제 workspace로 열리고, 정확한 프로젝트 제목이 본문에 표시되며, 재실행 후 복원된다. 최종 캡처 `build39/ipad-learning-workspace.png`에서 경고가 없고 새 학습 버튼 대비가 정상임을 확인했다.


## Build 39 설치 — 2026-10-17

- 실제 **Hi의 iPad / iPad Pro 11형 3세대 / iPadOS 26.5**에 서명된 **Release 0.1.0 (39)**를 설치했다. 기존 앱을 삭제하지 않고 업데이트했다. 설치된 bundle version도 devicectl에서 39로 확인했다.
- 마지막 수정까지 반영한 빌드는 `/tmp/bandal39-final-learning-release.log`에서 성공했다. `codesign --verify --deep --strict` 통과. 번들 91,432,542 bytes, 테스트 번들 없음. 웹 자산은 외부 페이지 기능을 위한 `article-extraction.js`, `web-pip.js`, `browser-agent.js` 세 개이며 React/Dockview/HTML 앱 셸은 없다.
- 05:36:52 KST에 테스트 인자 없이 실행해 프로세스 유지 확인 후 안정된 데이터 사본을 가져왔다. 대조 후 05:39:14 KST에 다시 일반 실행했다(`arguments=[]`, PID 14382). 설치·실행 증거는 `/tmp/bandal39-install.json`, `/tmp/bandal39-installed-app.json`, `/tmp/bandal39-final-normal-launch.json` 및 설치 후 백업 폴더에 보관했다.
- 설치 전후 일반 파일 **50개 모두 존재**, 삭제·추가 파일 0, 자료 파일 해시 유지. SQLite 3개 모두 `quick_check=ok`, FK 위반 0. 전체 50개 중 42개는 바이트도 같고, 로그·설정 경로·화면 상태 신규 필드·DB와 WAL 등은 변경됐다. 모든 파일이나 DB 내용이 동일하다고 주장하지 않는다.
- `settings.json`은 새 iOS 데이터 컨테이너를 가리키는 `dataRoot`만 변경됐다. `native-workspace.json`은 빈 `pageNoteSourceTabIDs` 필드만 추가됐고 열린 문서·활성 문서·선택 과목·배치는 유지됐다.
- 설치 전후 사본: `/Users/iseojun/.codex/device-backups/bandal-before-build39-20261017` 및 `/Users/iseojun/.codex/device-backups/bandal-after-build39-20261017`. 비교 결과는 설치 후 폴더의 `bandal39-backup-verification.json`에 보관했다.

- DB 차이를 행 단위로 추가 검토했다(`bandal39-logical-change-audit.json`, 설치 후 백업 폴더). 기존 PDF 필기 390행·생성 영수증 351행은 모든 열이 유지됐다. 신규 필기 16개는 최종 Release 시작 전인 05:18 세션에서 생성 후 이미 삭제 표시된 기록이며, 동일 geometry의 중복은 없고 동기화의 삭제 ID 증가분과 정확히 일치한다. 그 외 차이는 iOS 컨테이너 경로·조회 시각·오래된 검색 캐시 갱신이다. 실제 노트 파일은 동일하며 갱신된 검색본문이 그 파일과 일치한다. 마이그레이션 복구 원본·sourceHash도 유지됐고 설명되지 않는 데이터 손실은 찾지 못했다.


## Build 40 — 작업 공간·브라우저 개선

- 사용자 요청에 따라 시스템 상태막대, PDF와 자유 필기 노트의 상시 저장 안내 footer, Markdown 중복 파일명·저장 상태 header를 제거했다. 저장 실패/복구처럼 실제 조치가 필요한 안내는 유지한다. 필기 저장 상태는 도구 버튼의 접근성 값에서도 확인할 수 있다.
- 작업 시작 전 실제 iPad 일반 자료를 `/Users/iseojun/.codex/device-backups/bandal-before-build40-20261017`에 별도 보관했다. 일반 파일 54개·25,118,438 bytes, 3개 SQLite quick_check 정상, FK 위반 0. 이 수치는 build 39 이후 사용자의 변경을 포함한 새 기준이다.
- 실기기 UI 검증 직전 앱을 종료하고 `/Users/iseojun/.codex/device-backups/bandal-before-build40-ui-20261017/Documents`에 최종 비교 기준을 다시 보관했다. 일반 파일 54개·24,611,721 bytes, SQLite 3개 모두 무결성 정상이며 FK 위반은 없다. UI 검사는 별도 자료 루트를 사용한다. 이전 build 39의 결과로 새 소스의 검증을 대체하지 않는다.


### 브라우저 소스 대조와 연결

| 데스크톱 코드 | Swift 처리 |
|---|---|
| `features/browser/BrowserPanel.tsx`, `BrowserToolbarOverflow.tsx` | 뒤로/앞으로/중지/새로고침/홈, 현재 프로필·비공개 전환, 즐겨찾기, 방문 기록, 페이지 찾기, 확대/축소, 웹사이트 표시 모드, 공유를 실제 WebKit 작업과 연결. 좁은 분할은 주소와 프로필을 유지하며 나머지 작업을 메뉴에 둔다. |
| `BrowserAddressInput.tsx`, `useAddressSuggestions` | 열린 탭·즐겨찾기·학교 서비스·프로필별 방문 기록 추천. 한글 정규화, 안전한 URL, 비동기 결과 이후 선택 URL 보존, 좁은 영역 스크롤. |
| `BrowserFindBar.tsx` | 타이핑 검색, 일치 수·현재 위치, 이전/다음, Enter/Shift+Enter/Escape. 각 검색 요청에서 현재 본문을 다시 검사하고 오래된 문서/검색어 응답을 무시한다. 검색창을 다시 열면 남아 있던 검색어를 다시 검색한다. |
| `BrowserDownloadsPanel.tsx` | 다운로드 상태·진행률, 일시 정지/재개/취소/다시 받기, 과목 저장·열기/내보내기/목록 지우기. 비공개 파일은 임시 위치에 두고 일반 기록/자동 과목 저장에서 제외한다. |
| `useBrowserProfiles.ts`, `BrowserProfilePicker.tsx` | 생성·변경·삭제를 모든 열린 브라우저에 반영. 전환 전 검증·준비가 실패하거나 작성 중 경고를 취소하면 기존 WebView와 입력을 유지한다. 전환 후 새 프로필의 웹사이트 로딩 성공까지 보장하는 것은 아니다. |
| `BrowserContextMenu.tsx` | 기존 iPad 메뉴를 유지하면서 링크 새 탭·주소 복사·다운로드, 이미지 복사, 선택 텍스트 검색 연결. 기존 delegate의 nil 응답 때문에 메뉴가 표시되지 않던 오류를 교정했다. |
| `BrowserLoginPrompt.tsx`, 기존 Swift `DesktopCredentialsService` | 누락됐던 Swift 서비스 라우팅을 연결. HTTPS·현재 프로필·정확한 문서 세대에 묶어 사용자가 명시적으로 확인한 로그인만 Keychain에 저장하고 수동 채우기는 자동 제출하지 않는다. 비공개 페이지는 차단한다. 데스크톱의 자동 감지 배너와 달리 명시적인 로그인 관리 메뉴로 제공한다. |
| 데스크톱 `popupLimiter.ts`/popup 보안 정책 | 생성 프레임의 실제 출처에 맞는 blob 보고서와 about:blank 상속 출처를 허용하고, 동시/짧은 시간 팝업 한도 적용. POST popup의 쿠키·opener를 보존한다. |

이번 범위의 남은 차이: Chromium 확장·DevTools, 다른 앱의 브라우저 DB 직접 가져오기, 별도 PiP 버튼, 다운로드 상세 전용 탭, 웹페이지 문맥 메뉴의 학습 추가 shortcut은 제공하지 않는다. iPad 기본 동영상 컨트롤, 다운로드 sheet, 기존 학습 URL 추가 경로와 구분한다. 실제 계정 로그인·카메라/마이크 사이트 권한·물리 입력까지 검증했다고 주장하지 않는다.

### 화면 및 회귀 검증

- 상태막대만 숨기면 32pt의 safe-area 여백이 남는 것을 검사에서 확인했다. 위쪽 container safe area까지 제거해 실제 iPad에서 탭 줄의 y=0을 검증했다. 키보드 safe area는 유지한다.
- 데스크톱 `adaptiveTabs.ts`의 동일 폭 축소·활성 탭 유지·전체 탭 목록 방식을 Swift로 구현했다. 최대 208pt, iPad 최소 터치 영역 44pt이며 104/56pt에서 표시 밀도가 바뀐다. 문서 종류와 제목 길이는 폭 계산에 참여하지 않는다. 브라우저 내부 팝업 탭에도 같은 규칙을 적용했다.
- 실제 iPad에서 6개 브라우저 탭의 동일 폭·긴 제목·선택·닫기와 16개 혼합 문서 탭의 축소·넘친 탭 검색·선택·닫기를 통과했다. 확인한 화면은 `build40/ipad-browser-inner-tabs.png`, `build40/ipad-adaptive-document-tabs.png`, `build40/ipad-browser-address-suggestions.png`에 보관했다. 이 브라우저 캡처는 아래의 최상단 헤더 60pt 조정 전이며, 최종 헤더 배치는 도킹·PDF·노트 최종 캡처에서 확인한다.
- 최초 브라우저 UI 실행은 비공개 다운로드 창의 빈 상태까지 통과했지만, 전역 파일명 검사에서 일반 자료실에 정상 저장된 파일도 찾아 실패했다. 검사를 다운로드 창 내부로 한정한 뒤 주소 추천·확대·검색창 재열기·다운로드·비공개 프로필 흐름이 실제 iPad에서 통과했다(`/tmp/bandal40-final-device-ui.log`, `NativeBrowserParityUITests`). 같은 실행의 도킹은 이후 설명하는 시스템 창 드래그 때문에 실패했으므로 해당 실행 전체를 성공으로 기록하지 않는다.
- 실제 WKNavigationAction이 전달하는 NSURL의 `about:blank` 경로가 Swift로 새로 만든 URL과 다르게 해석되는 오류를 재현했다. 절대 주소의 URLComponents로 정규화하고, 실제 about:blank → 동일 출처 Blob 보고서 팝업과 기존 POST·쿠키·opener 경로를 검증했다.
- 브라우저·다운로드·프로필·로그인 라우팅·동일 폭 탭 관련 36개 단위/통합 검사가 통과했다(`/tmp/bandal40-browser-complete-unit.log`). 이후 다운로드 완료와 과목 저장 사이의 열기 경로를 별도로 보완했다. 최종 추가 검사 결과는 아래에 기록한다.
- 검색창을 다시 열면 기존 검색어로 재검색하며, 이미 열린 창도 Cmd+F로 포커스를 받는다. 다운로드 명령 오류는 다운로드 창 내부에도 표시한다. Markdown 도구는 폭에 맞는 완전한 버튼만 표시하고 나머지 기능은 메뉴로 제공한다. PDF·화이트보드의 좁은 도구 스크롤 높이는 44pt로 제한한다.
- 다운로드가 자료실에 저장되는 순간의 열기는 최신 다운로드 상태를 다시 조회한다. 조회 뒤에도 저장이 완료될 수 있으므로 엔진의 자료 열기 콜백까지 native 문서 이벤트로 연결했다. 추가 회귀 2개를 포함한 관련 12개 검사가 통과했다(`/tmp/bandal40-download-open-verified.log`). 이 12개는 위 36개와 10개가 중복되며 고유 검사는 총 38개다. 초기 새 이벤트 검사는 비동기 전달을 기다리지 않아 실패했으며, 실제 이벤트를 기다리는 expectation으로 수정했다.
- 실제 iPadOS 창 관리 모드에서는 y22의 최상단 탭 드래그를 시스템이 창 이동으로 처리했다. 상단 제스처 유예와 공개 창 드래그 실패 관계를 각각 검증했지만 효과가 없어 제거했다. 최상단 탭 영역만 60pt로 두어 44pt 버튼을 16pt 아래에 배치하고, 하단 pane·영역 선택기 아래는 44pt를 유지한다. 별도 시간·날짜 줄은 없다. 문서와 드롭 영역도 같은 pane별 헤더 높이를 사용한다. 짧은 실기기 재현에서 탭 이동과 창 위치·크기 불변을 통과했다(`/tmp/bandal40-top-inset-device-ui.log`). 전체 도킹 흐름의 최종 결과는 별도 기록한다.
- 최종 헤더 수정 후 도킹 모델 11개·탭 크기 4개, 총 15개 검사가 모두 통과했다(`/tmp/bandal40-final-dock-unit.log`). 최상단/하단/영역 선택기 아래의 문서 투영과 헤더 높이를 함께 검증한다.
- 실제 iPad에서 최종 도킹·복제 PDF·연속 페이지 Markdown·표와 수식·자유 필기 저장의 5개 흐름이 자동 검사를 통과했다(`/tmp/bandal40-final-documents-device-ui.log`). 도킹은 탭을 끌어도 시스템 창 위치·크기가 변하지 않는 조건도 검사한다. 최종 헤더가 적용된 `build40/ipad-four-pane-docking.png`, `build40/ipad-pdf-markdown-compact.png`, `build40/ipad-pdf-independent-panes.png`를 직접 확인했다.
- 그러나 같은 실행의 자유 필기 캡처에서 종이 전체가 빨갛게 표시되는 오류를 찾았다. 저장 개수·Undo·재실행 검사만으로 렌더링 색상을 보장할 수 없었다. 이 실행을 자유 필기의 시각적 정상 검증으로 기록하지 않는다. 설치 전에 텍스처 경로와 실제 화면 색상 검증을 보완한다.
- 원인은 UIKit의 회색조 종이 CGImage가 Metal R8 텍스처로 올라가 흰색을 `(1,0,0,1)`로 샘플링한 것이다. 기본 종이 업로더에서 회색조 입력만 sRGB BGRA로 확장하며, 원본 이미지·필기 데이터는 변경하지 않는다. 기존 캐시와 RGB 입력 경로를 유지한다. 실제 GPU에서 흰색 `(1,1,1,1)`과 투명도 보존을 확인했다. 화면 회귀는 방향을 정규화한 실제 canvas 캡처에서 흰 종이·노란 형광펜·펜 지우기 색상을 확인하도록 강화했다. 이전 빨강 캡처는 194,400개 표본 모두 빨강으로 판정되어 실패한다.
- 색상 수정 후 Metal/텍스처 복구/retained renderer 29개 중 28개 통과, simulator presentation timestamp 1개 skip, 실패 0이다(`/tmp/bandal40-paper-color-unit-verified.log`). 새 회귀는 실시간·저장 필기의 흰 종이/노란 형광펜/지우기와 회색조+알파 이미지의 채널·행 방향을 검사한다. 최초 실행은 실시간/저장 합성의 8비트 반올림 차이 127/128을 같다고 기대해 1개 실패했으며, 해당 blue 채널만 ±1 허용하고 나머지 채널의 정확 비교는 유지했다. 제품 코드를 바꾸어 기대값에 맞추지 않았다.
- 수정한 최종 소스로 실제 iPad의 두 PDF 창 흐름과 자유 필기 색상 회귀가 모두 통과했다(`/tmp/bandal40-color-final-device-ui.log`). 빈 종이·검정 펜·노란 형광펜·지우기·Undo·Redo·재실행 7단계의 실제 canvas 픽셀도 검사한다. `build40/ipad-whiteboard-colors.png`와 `build40/ipad-whiteboard-restored-canvas.png`에서 흰 종이·회색 격자·노란 필기가 정상이며 하단 저장 안내 줄이 없는 것을 직접 확인했다.

### Build 40 설치 — 2026-10-17

- **Hi의 iPad / iPad Pro 11형 3세대 / iPadOS 26.5**에 서명된 **Release 0.1.0 (40)**를 기존 앱 업데이트로 설치했다. 설치된 bundle version 40을 devicectl로 확인했다.
- 최종 색상 수정까지 포함한 `/tmp/bandal40-color-final-release.log` 빌드 및 `codesign --verify --deep --strict`가 성공했다. 번들은 92,843,774 bytes이며 테스트 번들·React/Dockview/HTML 앱 셸이 없다. JavaScript 자산은 웹페이지용 3개로, `article-extraction.js`·`browser-agent.js`가 연결되고 `web-pip.js`는 미연결 보관 자산이다.
- 07:00:08 KST에 테스트 인자 없이 일반 실행했으며 07:00:14에도 PID 14529가 유지됐다. 비교용 사본은 07:00:22 앱을 종료한 뒤 `/Users/iseojun/.codex/device-backups/bandal-after-build40-20261017/Documents`에 받았다. 빌드·테스트·서명·설치 증거는 같은 폴더의 상위 `verification` 디렉터리에 보관한다.
- 설치 전후 일반 파일 54개가 모두 존재하며 추가·삭제 파일은 없다. 자료 파일 해시가 유지됐고 전체 54개 중 46개는 바이트도 동일하다. SQLite 3개 모두 `quick_check=ok`, FK 위반 0이며 변경된 로그·설정·DB를 동일하다고 취급하지 않는다. 비교 기준은 위의 `bandal-before-build40-ui-20261017` 사본이며 결과는 `bandal40-backup-verification.json`에 기록했다.
- 비교 사본을 확보한 후 07:02:29 KST에 다시 일반 실행했다(`arguments=[]`). 07:02:52에도 최종 Release 프로세스 PID 14530이 유지됐다.
- 행 단위 독립 감사 결과, 자료·보존 원본 17개는 모두 SHA-256이 같고 기존 PDF 필기 413행·생성 영수증 374행·노트 도형은 모든 열이 유지됐다. 기존 PK 삭제는 없다. 추가 필기 3행은 06:51:17–27 KST에 생성 후 삭제된 기록으로 최종 Release 설치 전이며, 기존 필기와 geometry/XY 중복이 없다. 생성 주체는 사본만으로 판단하지 않는다. 동기화 변경도 기존 object/highlight를 유지하면서 이 3개의 삭제 ID와 대응 outbox 1개만 추가했다.
- `settings.json`의 의미상 변경은 새 iOS 컨테이너를 가리키는 `dataRoot`뿐이고 `native-workspace.json`은 의미상 동일하다. DB의 폴더/복구 원본 경로·source 메타데이터는 같은 컨테이너 경로 변경이며, 검색 캐시는 파일 식별 시각만 달라졌다. PDF는 같은 페이지를 유지하고 06:51:33에 배율이 바뀐 기록이 있다. 설명되지 않는 기존 자료 손실은 찾지 못했다. 독립 감사는 `sqlite-row-diff.json`·`logical-audit-explanation.json`에 보관했고, 감사 전후 두 백업의 파일 manifest도 그대로였다. 이 대조는 Documents 범위이며 Keychain·Library 설정의 동일성까지 주장하지 않는다.
