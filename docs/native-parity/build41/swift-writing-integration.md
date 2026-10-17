# Build 41: PDF 필기 팔레트·도형 보정·텍스트 편집의 Swift 통합

작성일: 2026-10-17. 서명된 **Release 0.1.0 (41)**를 실제 iPad에 설치하고 테스트 인자 없이 실행했다. 관련 고유 단위·통합 94개와 실제 iPad UI 흐름 5개의 최종 결과가 통과했다.

참조 원본은 `/Users/iseojun/dev/bandal-iPad`의 다른 채팅에서 작업한 PDF 필기 개선본이다. 해당 원본은 읽기만 했다. 구현 작업 공간은 `/Users/iseojun/.codex/worktrees/native-ipad-rebuild/bandal-iPad`이며, PDF 화면은 SwiftUI·UIKit·PDFKit·Metal로 구성한다. React 팔레트나 웹 텍스트 편집기를 앱에 다시 넣지 않았다. 아래 매핑은 동작과 저장 계약을 옮긴 위치를 보여 주며, CSS 픽셀 배치가 완전히 같다는 의미는 아니다.

## 참조 구현과 Swift 파일 매핑

표의 참조 경로는 위의 읽기 전용 원본 루트를 기준으로 한다. Swift 경로는 이 저장소를 기준으로 한다.

| 참조 구현 | Swift 구현 | 옮긴 동작과 계약 |
|---|---|---|
| `docs/pdf-writing-experience.md`, `DesktopRuntime/renderer/ipad/input/PdfPalette.tsx` | `App/Native/NativePDFChrome.swift`, `NativePDFPalette.swift`, `NativePDFWorkspace.swift` | 펜·형광펜·지우개·올가미·선택·텍스트 도구, 선택한 펜/형광펜 다시 누르기로 서식 열기, 색·굵기·불투명도, 좁은 분할 창에서도 접근 가능한 컨트롤. 직접 도형 삽입 버튼은 기본 도구 줄에서 제거했다. |
| `DesktopRuntime/renderer/ipad/input/paletteStyle.ts` | `App/Native/NativePDFPaletteStyle.swift` | 저장 굵기는 기존 PDF 폭 대비 비율을 유지한다. 표시만 실제 페이지 폭(pt)으로 mm 변환한다. 형광펜의 `max(0.014, width × 4)` 굵기와 최대 0.34 불투명도를 반영한다. |
| `PdfPalette.tsx`의 최근 스타일·즐겨찾기 | `App/Native/NativePDFPaletteStyle.swift`, `NativePDFWorkspacePreferences.swift`, `NativePDFPreferenceScope.swift` | 즐겨찾는 펜 3개와 최근 펜/형광펜 설정, 보정 토글을 저장한다. 열린 pane의 현재 도구·스타일은 독립적으로 유지한다. 앱 Documents 컨테이너 경로 변경에 대비한 설정 범위와 이전 키 복원 경로를 둔다. |
| `App/Desktop/PDF/NativePDFShapeRecognition.swift`, `DesktopRuntime/renderer/nativePDF/shapeRecognition.ts` | `App/Desktop/PDF/NativePDFShapeRecognition.swift` | 측정점만 사용해 선, 축에 평행한 사각형, 타원, 삼각형과 지원하는 볼록 사각형을 보수적으로 인식한다. PDF 가로/세로 비율을 보정한 좌표에서 판정한다. |
| 원본 `NativePDFInkSurface.swift`, `NativePDFLiveInkGeometryCache.swift` | 같은 이름의 `App/Desktop/PDF` Swift 파일 | 끝점이 화면 3pt 안에서 0.55초 머무르면 접촉 중 미리보기. 다시 움직이면 원래 측정 획으로 돌아간다. 펜·형광펜 모두 지원하고 예측점은 인식·저장 원본에 포함하지 않는다. |
| 원본 `NativePDFCompletionBuffer.swift`, `NativePDFHost.swift`, `NativePDFTypes.swift` | 같은 이름의 `App/Desktop/PDF` Swift 파일, `NativePDFJournalQueue.swift` | 원래 측정점과 확정된 `heldShape`를 함께 보관한다. 늦게 도착한 UIKit 측정 보정은 raw 입력을 정제하고 사용자가 본 도형은 유지한다. Host는 저장 전에도 같은 도형으로 대기 중 획을 표시한다. |
| `DesktopRuntime/renderer/nativePDF/session.ts`의 도형 교체·history·erase alias | `App/Native/NativePDFPersistence.swift`, `App/Native/Storage/NativePDFRepository.swift` | Swift 저장 큐, 같은 필기 ID를 유지하는 원자적 도형 교체, 재시도 영수증, 도형→raw→삭제 Undo, 복원된 ID를 가리키는 지우개 연결. 원본의 별도 삭제/생성 교체보다 강한 원자성을 제공한다. |
| `DesktopRuntime/renderer/textEditing/TextFormatRow.tsx`, `textFormatStore.ts` | `App/Native/NativePDFTextEditor.swift`, `NativePDFTextDraft.swift`, `NativePDFWorkspace.swift` | UIKit 텍스트 편집, 글자 크기 직접 입력·단계 조절, 굵게/기울임/밑줄/취소선, 색·정렬·배경·불투명도, 기본 서식 저장, 완료·취소·삭제. UTF-16 범위의 `textRuns`를 유지한다. 한국어 조합 중 완료/취소 키가 오작동하지 않도록 처리한다. |
| 텍스트 상자 이동·크기·내보내기 계약 | `App/Native/NativePDFEditingGeometry.swift`, `App/Desktop/PDF/NativePDFObjectRenderer.swift` | 너비를 바꾸면 텍스트를 다시 줄바꿈하고 높이를 계산한다. 화면과 PDF 내보내기는 공통 텍스트 레이아웃을 사용한다. 저장한 상자를 선택·이동·크기 변경·다시 편집할 수 있다. |

## 저장 및 재시도 보장

도형 보정은 원래 측정 획을 먼저 기존 `drawings:create` 영수증으로 확정한다. `drawings:replace`는 현재 PDF revision과 대상의 과목·경로·페이지·기존 내용이 맞는지 확인한 뒤, **같은 `pdf_drawings.id`의 kind/data/style 변경과 `drawing_replace_receipts` 삽입을 하나의 SQLite transaction으로 처리한다.** 교체 영수증 삽입이 실패하면 행 변경도 롤백된다. 원래 `drawing_create_receipts`는 수정하지 않는다.

네이티브 입력 journal에는 raw 측정점과 도형 후보가 함께 남는다. 도형 교체가 커밋된 뒤 응답이 유실되어도 같은 작업 ID로 영수증을 읽고 ACK를 마칠 수 있다. 재시도가 최신 행을 다시 덮어쓰지는 않는다. 앱 재시작 전에 동기화가 같은 행을 바꾼 경우에는 영수증의 `after`와 현재 행을 대조하여 오래된 raw/shape Undo를 등록하지 않는다. 현재 행에 연결된 오래된 이력도 제거하여 최신 편집을 보존한다.

보정 직후 첫 Undo는 정확한 raw 측정점·필압·시간·기울기로 돌아가고, 두 번째 Undo는 그 획을 삭제한다. Redo 시 삭제된 획의 복원은 새 생성 UUID를 사용한다. 이후 이전 ID를 가리키는 대기 중 지우개는 복원된 ID로 해석한다. 일반 입력·교체·지우개·history는 같은 문서의 저장 조정자를 통과한다.

새 텍스트 상자는 `createObject(_:mutationID:)`로 저장한다. UI가 생성 시도별로 고정 UUID를 보유하고, `drawings:mutationStatus`가 해당 생성 영수증을 조회한다. 내용이 우연히 같은 다른 pane의 상자를 자신의 저장 결과로 간주하지 않는다. 실패한 pending history를 먼저 마친 뒤 같은 토큰으로 재시도하며, 이미 삭제된 생성 토큰은 상자를 부활시키지 않는다. 기존 `createObjects`와 Undo 복원은 계속 새 UUID를 사용한다. `nativePDF:mutationStatus`의 측정 잉크 전용 검증은 유지했다.

교체 영수증은 로컬 `bandal.db`에 있으므로 전체 DB 백업과 `VACUUM INTO` 백업에 포함된다. CommonSync는 현재 `pdf_drawings`의 정규 데이터만 투영하고 로컬 교체 영수증 자체는 전송하지 않는다. 동일 ID의 kind/data 변경은 기존 동기화 import 계약에서 허용한다. 페이지 변경·파일 이름 변경 후에도 과거 영수증의 원래 요청은 불변이다.

## 확인한 검증

### 시뮬레이터 단위 테스트

`/tmp/bandal41-writing-unit-final.log`: 선택한 10개 suite, **88 tests / 0 failures / TEST SUCCEEDED**. 이는 앱 전체 테스트 수가 아니다.

| Suite | 통과 수 |
|---|---:|
| `NativePDFEditingGeometryTests` | 4 |
| `NativePDFObjectRendererTests` | 4 |
| `NativePDFOperationLedgerTests` | 11 |
| `NativePDFPaletteTests` | 8 |
| `NativePDFPencilGestureTests` | 15 |
| `NativePDFPersistenceTests` | 15 |
| `NativePDFRepositoryTests` | 12 |
| `NativePDFShapeRecognitionTests` | 6 |
| `NativePDFTextEditorTests` | 9 |
| `NativePDFWorkspacePreferencesTests` | 4 |

`/tmp/bandal41-preference-migration-tests.log`의 최종 설정 검증도 **18개 모두 통과**했다. 위 12개 중복 검증과 새 `NativePDFPreferenceScopeTests` 6개를 포함하므로 이번 변경의 고유 단위·통합 테스트는 총 **94개**다. Documents 컨테이너 UUID 변경, 동일 문서의 여러 과거 키, `/private` 경로 별칭 충돌, 외부 저장소 격리, 두 번 업데이트하는 동안 열지 않은 문서의 설정 이관을 검사했다.

새 저장소 회귀는 임시 SQLite와 실제 repository를 사용한다. 교체 영수증 INSERT 실패 시 롤백, 응답 유실 후 재시작, raw 복원과 두 단계 Undo/Redo, 오래된 지우개 ID, 최신 원격 행 보존, 텍스트 생성 전·커밋 후·화면 갱신 중 실패 재시도를 검증한다. 텍스트 테스트는 동일 내용의 다른 생성 토큰을 가진 상자가 둘 다 보존되는지도 검사한다.

형광펜 hold 테스트의 초기 실패는 테스트가 불투명 PDF 배경 없이 입력을 시작해 production의 배경 준비 검증에 거절된 것이었다. PDFPage와 실제 UIWindow를 사용하는 fixture로 교정했으며, 해당 검증을 우회하거나 production guard를 제거하지 않았다.

### 화면 확인 중 수정한 문제

- 추가 서식과 키보드가 함께 표시되면 텍스트 입력 영역 높이가 0이 되는 문제를 실제 기기에서 확인했다. 추가 서식·상자 너비를 팝오버로 옮겨 입력 영역을 확보했다.
- CGFloat와 Double이 섞인 텍스트 상자 좌표가 화면·내보내기에서 누락되는 문제를 고쳤다. 저장 좌표는 Double로 통일하고 렌더러는 유효한 NSNumber를 일관되게 읽는다.
- 글자 크기 입력 완료 후 이전 소수 값이 돌아오던 문제를 고쳤다.
- 미리보기 획 굵기를 카드 폭이 아닌 PDF 원본 페이지 폭으로 계산하도록 바로잡았다.
- 앱 업데이트로 iOS 데이터 컨테이너가 바뀌면 문서 설정 키를 찾지 못하던 문제를 고쳤다. 앱 Documents 상대 경로로 안정적인 키를 만들고, 저장소 설정에서 확인한 이전 경로들을 순서대로 기억해 기존 키를 지우지 않고 이관한다.

### 실제 iPad의 XCTest UI 실행

`/tmp/bandal41-integrated-device-ui.log`에서 다음 네 흐름이 통과했다.

- `NativePDFWritingUITests.testPaletteFavoritesIndependentToolsAndNarrowPanesPersist`: 색·굵기·불투명도, 펜/형광펜 독립 스타일, 즐겨찾기, 재실행, 두 좁은 PDF pane의 조작 영역.
- `NativePDFWritingUITests.testHoldShapeUndoAndFormattedKoreanTextSurviveRestart`: 유지 동작으로 도형 보정, raw 복원·삭제·Redo, 한국어 서식 텍스트 생성·재편집·프로세스 재실행 후 보존.
- `NativePDFDocumentFlowTests.testDuplicatePDFPanesShareInkButKeepIndependentUndoToolsAndPages`: 동일 PDF 두 pane의 공유 저장과 독립 도구·페이지·Undo.
- `NativeWorkspaceFlowTests.testWhiteboardNativeInkEraseAndHistorySurviveCloseAndRelaunch`: 기존 노트의 필기·지우개·history·닫기와 재실행 보존.

같은 실행에 포함된 기존 `testNativeShapeLassoHistoryAndTextPersistAcrossRelaunch`는 테스트가 새 선분과 실제로 교차하지 않는 평행 sweep을 사용해 실패했다. 실제 geometry로 교차 경로를 검증하고, 이동 완료를 기다린 뒤 이동한 위치에서만 재선택되도록 검사를 강화했다. 최종 `/tmp/bandal41-final-device-ui.log`에서 이 흐름과 팔레트 흐름 **2개 모두 통과**했다. 따라서 검증한 고유 실기기 흐름 5개가 최종적으로 통과했다. 이는 앱 전체 UI 테스트를 재실행했다는 의미가 아니다. 앞선 테스트 실패는 숨기지 않으며 최종 대응 검사의 통과 결과를 우선한다.

UI 테스트의 입력은 `--native-pencil-dispatch-fixture`로 XCTest touch를 네이티브 필기 경로에 전달한다. 실제 iPad에서 production Swift 화면·PDFKit/Metal·저장·재실행을 확인하지만, 사람이 물리 Apple Pencil을 사용하여 필압·기울기·팜 리젝션·체감 지연을 평가했다는 증거는 아니다. 새 writing UI 흐름은 PDF 화면에 `WKWebView`가 없다는 것도 검사한다.

## 설치 및 실제 화면

최종 `generic/platform=iOS` Release 빌드와 `codesign --verify --deep --strict`가 성공했다. `devicectl`로 설치한 뒤 앱 목록에서 `0.1.0 (41)`을 확인했다. 일반 실행 → 백업을 위한 종료 → 일반 재실행 후 같은 설치 경로의 프로세스가 살아 있음을 확인했다. 앱을 삭제하거나 기존 저장소를 초기화하지 않았다.

[번들 감사](release-bundle-audit.json): 60개 파일, 93,884,462 bytes. React·Dockview·XCTest·HTML 앱 자산 없음. JavaScript는 브라우저 처리용 `article-extraction.js`, `browser-agent.js`, 현재 미연결인 `web-pip.js` 세 파일이다. [설치·검증 요약](installation-verification.json)도 저장했다.

아래는 실제 iPad XCTest에서 캡처하고 직접 확인한 화면이다.

- [펜 팔레트](native-pen-palette.png), [형광펜 팔레트](native-highlighter-palette.png)
- [좁은 두 분할 창의 즐겨찾기](native-favorites-in-split.png)
- [키보드와 한글 서식 편집](native-korean-text-editor.png)
- [저장된 텍스트·선택 핸들·보정 선](native-text-and-corrected-line.png)
- [올가미 이동·삭제·Undo 후 텍스트](native-lasso-move-history.png)

## 설치 전후 자료 보존

[정제 감사 보고서](data-preservation-audit.json)는 사용자 문서 내용·이름·설정 원문 대신 개수와 해시를 기록한다. 앱을 종료한 상태에서 설치 전후 Documents와 Preferences를 각각 호스트에 복사해 비교했다. SQLite 검사는 백업 원본을 변경하지 않는 임시 사본에서 수행했다.

- 비테스트 Documents 파일은 54개로 유지됐고 추가·삭제가 없다. 자료·보존 원본 17개의 byte 해시가 모두 동일하다.
- 기존 데이터베이스 행 삭제는 없다. PDF 필기 416행과 노트 필기 17행의 내용은 모두 동일하다. 3개 DB 모두 integrity/FK 검사를 통과했고, 2개 동기화 DB는 논리 내용 전체가 동일하다.
- 기존 DB 변경은 새 iOS 컨테이너 경로 반영 18행, 검색 ctime 캐시 3행, 목록·열람 시각 4행이다. 현재 저장소 경로 등록 1행과 예상한 빈 `drawing_replace_receipts` 테이블이 추가됐다. 설정 파일은 `dataRoot`만 새 경로로 변경됐다.
- 기존 UserDefaults 48개 값이 모두 그대로다. 여기에 이전 PDF 설정 키 22개가 포함된다. 새 키 17개가 추가됐다.
- 설치 직전 경로와 실제로 매칭되는 문서 1개에서 안정적인 새 설정 키가 생성됐고, 펜·형광펜·활성 도구·패널 설정이 보존됐다. viewport는 수직 progress만 정상 범위에서 달라졌으며 page/revision/zoom/수평 progress는 유지됐다.
- 설치 전에는 새 팔레트 즐겨찾기 키가 없었으므로 실제 기존 즐겨찾기를 이관했다고 주장하지 않는다. 새 즐겨찾기의 저장·재시작·다중 창 공유와 컨테이너 변경은 각각 실제 UI·단위 테스트로 검증했다.

## 범위와 검증 경계

- 이번 이식 대상은 다른 채팅의 **PDF 팔레트·그린 뒤 유지 보정·PDF 텍스트 상자**다. 일반 노트(whiteboard)의 팔레트까지 확대하지 않았다. 공유 ink surface의 보정은 기본 꺼짐이며 PDF Host가 설정값으로 명시적으로 켠다. 저장하지 못할 도형 preview를 기존 노트에 노출하지 않는다.
- 인식 가능한 도형은 위에 열거한 범위다. 임의 곡선·모든 다각형·자유형 필기를 강제로 도형으로 바꾸지 않는다. 짧은 점, 인식 실패, 빠르게 떼는 획은 raw로 남는다.
- 색은 기존 고정 7색이다. 사용자 HEX 색, 임의 색 슬롯, 여러 펜 촉, 사용자 필압 곡선·안정화 강도 설정은 이번 범위에 없다.
- mm 값은 PDF상의 물리 크기 표시다. 화면 확대율이 바뀌어도 저장된 굵기나 mm 값 자체를 바꾸지 않는다.
- 기기 간 Undo 이력 동기화나 모든 Undo 이력의 영구 보존을 추가한 것은 아니다. 정규 저장 데이터와 미완료 작업 복구를 보장하고, 기존 pane별 이력 수명은 유지한다.
- Release 컴파일에는 기존 actor isolation·UIKit deprecated API·Swift 6 mode 관련 경고가 남아 있다. 이번 프로젝트는 Swift 5 mode이며 빌드는 성공했다. 앱 전체 테스트를 새로 실행한 것은 아니다.
