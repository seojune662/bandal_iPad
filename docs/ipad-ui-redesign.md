> **Historical / 과거 구현 기록** — 이전 빌드의 구현·검증 기록이며, 삭제된 웹 UI·JavaScriptCore 경로가 포함될 수 있습니다. 현재 Swift 앱의 구조·빌드·검증 범위는 [README](../README.md)를 우선합니다. 아래 결과는 현재 빌드의 검증 결과가 아닙니다.

# 반달 iPad UI·UX 개선 결과

2026-10-15. 실제 실행되는 React/Dockview 앱의 iPad 표현 계층에 적용했다.
기존 작업트리의 필기·브라우저·안정성 변경을 보존하며, 이번 UI 작업에서는
upstream 스냅샷, 공개 API/IPC, 문서·필기 저장 형식을 변경하지 않았다.

## 적용 내용

- 공통 색상·간격·모서리·글자·버튼 상태를 통일했다. 터치 영역은 44px,
  주요 버튼은 48px이며 작은 스위치는 보이는 크기와 터치 영역을 분리한다.
  밝음/어두움과 글자 크기 설정을 따르고 문서 본문·필기 색과 크기는 유지한다.
- 왼쪽은 이름이 보이는 2열 탐색, 과목·폴더, 하단 도움말·계정·설정으로 정리했다.
  자료의 더보기 동작은 호버 없이 사용할 수 있다.
- 왼쪽 336px, 자료 320px와 사용자 AI 폭을 유지하면서 공간에 맞춰 나란히 배치한다.
  요청한 열림 상태와 실제 표시를 구분하여 축소 시 최근 패널을 우선하고 확대 시 복원한다.
  700px 미만은 전체 폭 패널이다. 시작 시 패널은 닫혀 있고 직접 닫은 패널은 복원하지 않는다.
- 패널별 자동 배치/고정 해제 선호는 로컬 v2로 이행한다. 기존 명시적 AI 고정 해제를 보존한다.
  자료와 현재 문서 AI는 오른쪽을 교대로 사용하며 대화·초안과 편집기를 다시 만들지 않는다.
  분할 비율과 해당 문서의 AI 폭까지 계산해 문서당 560px을 확보한다.
- 설정 20개 경로와 6개 하위 탭에 카드·행·760px 본문 폭을 적용했다.
  좁은 화면에서는 설명과 입력을 세로로 배치한다. WebKit 선택 상자의 실제 높이와
  375px 단축키 화면의 가로 넘침을 보정했다.
- AI 상단에 현재 문서·페이지·선택 내용·첨부 범위를 표시한다.
  독립 채팅과 문서 AI에 같은 컨트롤 규칙을 적용하고 입력·첨부·모델·허용 범위·전송·중단,
  승인·오류·복구 상태를 구분했다. 폭 변경 시 긴 초안 높이를 다시 계산한다.
- PDF/화이트보드 도구, 문서·Office·이미지 헤더, 학습·문제·리더, 녹음,
  브라우저 보조 화면, 보드·달력·위젯, 계정·학교·동기화·플러그인·마켓·도움말과
  팝업·메뉴·알림에 공통 규칙과 화면별 스타일을 적용했다.
- 겹쳐 열린 패널/메뉴의 Tab·Escape·포커스 복귀와 화면 키보드의 visual viewport를 처리한다.
  기존 네이티브 화면 가림 및 입력 소유권 계약을 유지한다.

세부 적용 파일과 실제 컴포넌트 검사/스타일 검사 구분은
[화면별 검증 범위](ipad-ui-screen-coverage.md)에 기록했다.

## 전후 비교

아래 비교는 같은 컴포넌트/레이아웃 표본·데이터·화면 크기에 새 `ui` 계층의 적용 여부만 바꾼
통제된 캡처다. 기존 reset 및 iPad 어댑터를 유지한다. 전체 과거 앱의 스크린샷이나
모든 화면의 모든 상태를 촬영한 것으로 해석하지 않는다.
학습 화면은 실제 자료 선택 컴포넌트와 레이아웃 표본을 함께 사용한다.

| 화면 | 적용 전 | 적용 후 |
| --- | --- | --- |
| 설정 · 밝음 | ![설정 적용 전](fixtures/ipad-ui-redesign/before-light-settings.png) | ![설정 적용 후](fixtures/ipad-ui-redesign/light-settings.png) |
| 설정 · 어두움/큰 글자 | ![설정 어두움 적용 전](fixtures/ipad-ui-redesign/before-dark-settings.png) | ![설정 어두움 적용 후](fixtures/ipad-ui-redesign/dark-settings.png) |
| AI · 밝음 | ![AI 적용 전](fixtures/ipad-ui-redesign/before-light-ai.png) | ![AI 적용 후](fixtures/ipad-ui-redesign/light-ai.png) |
| AI · 어두움/큰 글자 | ![AI 어두움 적용 전](fixtures/ipad-ui-redesign/before-dark-ai.png) | ![AI 어두움 적용 후](fixtures/ipad-ui-redesign/dark-ai.png) |
| 과목 생성 · 375px | ![과목 생성 적용 전](fixtures/ipad-ui-redesign/dialog-375-light-before.png) | ![과목 생성 적용 후](fixtures/ipad-ui-redesign/dialog-375-light.png) |
| 녹음 재생 · 375px | ![녹음 적용 전](fixtures/ipad-ui-redesign/recording-375-light-before.png) | ![녹음 적용 후](fixtures/ipad-ui-redesign/recording-375-light.png) |
| 학습 · 834px | ![학습 적용 전](fixtures/ipad-ui-redesign/learning-834-light-before.png) | ![학습 적용 후](fixtures/ipad-ui-redesign/learning-834-light.png) |
| 화이트보드 도구 · 375px | ![도구 적용 전](fixtures/ipad-ui-redesign/canvas-375-light-before.png) | ![도구 적용 후](fixtures/ipad-ui-redesign/canvas-375-light.png) |

실제 과목·자료 컴포넌트를 사용하는 양쪽 사이드바 검사 화면:

![양쪽 사이드바](fixtures/ipad-ui-redesign/shell-wide.png)

중앙의 단순 입력창은 미저장 초안과 동일 DOM 유지 검사를 위한 편집기 대역이다.
네이티브 PDF를 포함한 전체 앱 검사는 아래에 별도로 기록한다.

## 자동 검증

| 검사 | 결과 |
| --- | --- |
| 스냅샷 무결성 | 1,021개 원본 해시 및 설정 20개 경로 일치 |
| TypeScript | 원본 및 실제 변환 후 strict 검사 통과 |
| `npm test` | 렌더러·IPC·키보드·파일 입력·수명·패키지·동기화 UI·라우팅·PDF 자원 통과 |
| `npm run test:settings` | 20경로·6하위탭·231개 컨트롤 선언, 미해결 컴포넌트 0개; 기존 기능/저장 실패/복구 검사 통과 |
| `npm run test:browser` | 브라우저 UI·복구·기본 확대·북마크 가져오기 통과 |
| `npm run test:workspace` | 실제 Dockview 혼합 문서·저장된 배치 복원 통과 |
| `npm run test:pencil` | 입력·필기·선택·배치·ACK·이력·복구 검사 통과 |
| `npm run test:ipad` | 실제 사이드바·포커스·중첩 메뉴·문서 초안·분할 복원·네이티브 가림·도구·자료 동작 통과 |
| `npm run test:ui` | 공통 UI·설정 20경로×4폭·6하위탭·AI 문맥/초안/상태/키보드·대표 화면 12조합 통과 |
| canonical renderer/backend/package build | 통과 |
| Xcode simulator build-for-testing | 통과 |
| 실제 앱 XCTest | 13인치 iPad 시뮬레이터에서 브라우저 2건·PDF 사용성 1건·자료 작업 3건·설정 전체 경로 1건·작업 공간 1건·양쪽 패널/AI/회전 1건 통과. 최종 UI 번들에서 브라우저 2건·작업 공간·패널 전환 4건을 재실행해 모두 통과 |

레이아웃은 375·507·699·700·759·760·834·900·1024·1194·1366px,
양쪽 고정 경계 1216px 및 2:1 분할을 검사한다. 설정은 20경로×4폭
(375·507·834·1194px), 나머지 대표 컴포넌트는 밝음/어두움·짧은 창·125% 글자
12개 조합을 검사한다. 버튼은 CSS 선언값이 아닌 실제 렌더링된 크기를 측정한다.

## 실제 앱 캡처

13인치 iPad Pro 시뮬레이터의 실제 WKWebView 앱과 네이티브 PDF를 캡처했다.
앱 프레임 캡처가 회전 직후 잘리는 XCTest 문제는 화면 전체 캡처로 보정했다.

| 상태 | 캡처 |
| --- | --- |
| 양쪽 사이드바 + 네이티브 PDF | ![양쪽 패널과 PDF](fixtures/ipad-ui-redesign/native-dual-pdf.png) |
| 자료에서 AI로 전환 | ![문서 AI와 PDF](fixtures/ipad-ui-redesign/native-dual-ai.png) |
| 세로 화면에서 자료 우선 | ![세로 자료 패널](fixtures/ipad-ui-redesign/native-portrait-materials.png) |
| 실제 일반 설정 | ![실제 일반 설정](fixtures/ipad-ui-redesign/native-general.png) |
| 필기한 PDF 위 설정 | ![PDF 위 설정](fixtures/ipad-ui-redesign/native-settings-over-pdf.png) |
| 브라우저 터치 메뉴 | ![브라우저 메뉴](fixtures/ipad-ui-redesign/native-browser-menu.png) |
| 브라우저 연결 실패 복구 | ![브라우저 복구](fixtures/ipad-ui-redesign/native-browser-recovery.png) |

시뮬레이터에는 AI 키를 등록하지 않았으므로 실제 앱 AI 캡처는 연결 안내 상태다.
대화·스트리밍·승인·첨부·오류 상태는 앞의 실제 ChatSurface 컴포넌트 검사로 검증했다.
초기 패널 XCTest는 WebKit이 노출하지 않는 `complementary` 컨테이너를 찾다가 실패했다.
눈에 보이고 조작 가능한 AI 고정 버튼을 검사하도록 수정한 뒤 같은 전환을 재실행해 통과했다.
후속 실행에서 이전 선택자를 사용하는 테스트 러너가 실행되어, 전용 시뮬레이터의 앱과
테스트 러너를 제거하고 다시 빌드·설치했다. 최종 로그에서 새 선택자의 실행과 4/4 통과를
확인했다. 최종 결과 묶음은 `/private/tmp/bandal-ui-redesign-verified.xcresult`이며,
해당 실행의 캡처를 위 이미지에 반영했다.

## 검증 한계와 별도 항목

외부 AI·계정·동기화·마이크 등은 테스트 IPC를 사용한 검사와 실제 서비스 검사를 구분했다.
모든 부가 화면의 모든 상태를 실계정으로 열어 검증한 것은 아니다.
실물 iPad의 Apple Pencil 촉감·물리 키보드·VoiceOver·실제 화면 키보드 애니메이션은
이번 자동 검사만으로 확인했다고 주장하지 않는다.

기존 장시간 안정성 및 필기 성능 작업은 별도 변경/검증이다.
[기존 안정성 기록](ipad-stability-audit.md)과 [필기 품질 기록](handwriting-quality.md)을 따른다.
이번 UI 테스트의 성공을 해당 장시간·실기기 항목 해결의 증거로 사용하지 않는다.
