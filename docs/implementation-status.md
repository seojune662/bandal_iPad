> **Historical / 과거 구현 기록** — 이전 빌드의 구현·검증 기록이며, 삭제된 웹 UI·JavaScriptCore 경로가 포함될 수 있습니다. 현재 Swift 앱의 구조·빌드·검증 범위는 [README](../README.md)를 우선합니다. 아래 결과는 현재 빌드의 검증 결과가 아닙니다.

# iPad 구현 현황과 검증 기록

## 2026-10-16 사용자 확인 — 필압·끝 모양 개선과 속도 유지

사용자는 새 v5 필압·획 끝의 자연스러움과 연속 필기·지우개 반응을 묻는 질문에 **“자연스러워졌고 필기·지우개도 빠름”**이라고 답했다. 해당 실사용에서 품질 개선과 속도 유지를 확인했으며, 아래의 사용자 확인 대기 상태를 갱신한다. 질문 표기는32, 이 채팅의 마지막 설치는 동일한 v5 필압·끝처리의33이다. 실제 시험 빌드·시각은 응답만으로 확정하지 않는다. 스크롤·확대나 경쟁 앱 동등성까지 확인한 답변은 아니다. 문서만 갱신하고 코드·설치물·자료·봉인된 검증 아카이브는 유지한다.

## 2026-10-16 빌드 33 — v5 필압·자연스러운 끝과 최신 UI 통합

**Simulator 관련 native 275개 중 274 pass·1 skip·0 fail(70.600초), 13인치 실제 앱 UI 2개 모두 pass(79.827초), 실제 iPad 최종275개 전부 pass·skip0·fail0(78.065초). 자료 보존 확인 후 빌드33을 2026-10-16 01:12:29 KST 일반 실행했다(PID12196, args=[]).** 사용자 빌드31 지우개 인수에 이어 새 v5 필압·끝 모양과 필기·지우개 속도도 위의 2026-10-16 답변으로 확인했다.

새 펜 획을 `inkVersion: 5`로 생성한다. 최신 원본4점의 짧은 시간 필압 필터, 최대12% 속도 폭 보정, 이동 거리에 국한된 시작/끝 taper를 적용한다. 정지점은 렌더 전용 anchor로 묶되 원본 위치·필압·시간·기울기와 저장 순서를 보존한다. 긴 두 점 선의 본문 전체가 가늘어지거나 정지 샘플이 쌓여 끝이 다시 두꺼워지는 초안 반례를 수정했다. 기존 v2/v3/v4 저장 획은 자동 변환하지 않으며 v5 형광펜은 v4 polygon과 정확히 같다. live/완료/웹/export는 같은 버전 기하를 사용하고, 기존 완료 GPU mesh·네이티브 지우개·ordered 저장 경로를 유지한다.

Swift/TypeScript 35개 fixture·182,905개 수치에서 최대 차이2.22e-16, 447 live prefix를 확인했다. 2,400점 뒤4점 append는 factor/구간21개·전체231,930개 중2,784개 정점만 재계산했다. 기하의 bounded tail은 검증했지만 raw-prefix 대조 O(N)과 오래된 보정의 suffix 재계산은 남는다. 이 CPU/기하 검사를 물리 Pencil 전체 지연이나 경쟁 앱 동등 품질로 해석하지 않는다. 상세 수식·정지/희소 입력 계약·수치·한계는 [필기 품질](handwriting-quality.md)의 빌드33 절에 있다.

최신 다른 작업도 후보에 포함했다. 원본 기준2,233파일의 이후 변경0개를 확인했고 대표 UI/상호작용68파일·브라우저36파일의 원본/기준/후보 SHA가 일치했다. 56px 상시 아이콘 rail+280px 본문, 설정 뒤로 이동, sidebar swipe, touch tab drag/native ACK 장벽, 브라우저 탐색·복구와 네이티브 창·저장 안정성 수정을 유지한다. 보고서 `/private/tmp/bandal-ink32-integration-review.json`은 소스 포함 확인이며 모든 동작의 인수나 설치 확인은 아니다. 새 웹 v5/export/backend 버전 지원을 같은 후보에 통합했다.

빌드32 전체 Simulator native598(594 pass·4 skip·0 fail,353.989초), 실제 iPad271(271 pass·0 skip·0 fail,77.273초)는 통과했으나 넓은 UI8은6 pass·2 fail(414.275초)이었다. 첫 실패는 세로에서 설정 버튼이 숨겨져야 한다는 옛 테스트 전제로, 상시 rail과 본문 패널의 AX 상태를 분리해 바로잡았다. 두 번째는 실제13인치 mixed undo에서 저장206행은 복구됐지만 새 큰 객체의 밀도8 texture 작업 예약이64MiB 예산을 넘어 GPU 유지가 해제된 제품 경계였다. 단순히 테스트 기대를 낮추지 않았다.

빌드33은 accepted texture와 메모리 계정을 보존하며 새 객체를 예산에 맞는 낮은 밀도로 먼저 준비한다. 기존 고해상도 자원은 내리지 않고 동일 요청을 반복 raster하지 않으며, 가능한 경우 후속 upgrade를 허용한다. 실제 글상자 회귀에서 요청33,551,624byte 대신8,712,368byte texture로4개객체 GPU지원에 복귀했고, 삭제→새ID undo·생존자 identity·순서/multiply·예산·동일update 추가raster0을 검사했다. 밀도/메모리 제약 아래 글상자·이미지 등 객체 texture가 요구 해상도보다 낮을 수 있다는 한계는 명시한다. 완료 잉크의 mesh나 원본 필압을 낮추는 변경은 아니다. 수정 후 관련 native275와 위 실패를 겨냥한13인치 UI2가 통과했으며, 이들 결과를 중복 합산한 고유 검사 수로 표현하지 않는다. Simulator skip1은 실제 drawable presentation timestamp 미지원이다.

검증 로그: `/private/tmp/bandal-ink32-sim-native.log`, `/private/tmp/bandal-ink32-device-native.log`, `/private/tmp/bandal-ink32-ui.log`, `/private/tmp/bandal-ink33-sim-native.log`, `/private/tmp/bandal-ink33-sim-ui.log`. 이전 실패는 보존하며 새13인치 결과로 당시 실행을 통과로 변경하지 않는다.

- **실기기 최종:** 275/275 pass, skip0·fail0, 78.065초. `/private/tmp/bandal-ink33-device-native.log`와 `.xcresult`에 보존했다. Simulator의 실제 presentation 제외는 실기기 실행에서 통과했다.
- **자료 보존:** 최신 중지 상태의 검사 전→검사 후 사본은 61개 테이블·PDF/Markdown14개 변경0, pending journal0, 양쪽 quick_check=ok(`/private/tmp/bandal-ink33-postcheck/comparison.json`). 그보다 앞선 설치 전 운영 중→중지 비교의 `materials_index` 한 행 `mtime`·`updated_at` 차이는 별도로 남기며, 모든 백업 사이가 동일하다고 합쳐 표현하지 않는다.
- **설치·통합 자원:** 빌드33 설치 확인 및 일반 실행은 `/private/tmp/bandal-ink33-normal-launch.json`/`.log`에 기록했다. 복사형 패키지459파일이 candidate·원본 통합본·Simulator 앱·device 앱 사이에 같고 고정 웹 소스29개도 SHA 일치(`/private/tmp/bandal-ink33-packaged-resources.json`). 플랫폼별 `Assets.car`는 바이트 동일성을 주장하지 않는다.
- **사용자 확인:** 필압·끝 모양이 자연스러워졌고 필기·지우개도 빠르다는 답변을 받았다. 확대 반응과 전체 품질 목표까지 완료 처리하지 않는다. UI 전체 캡처3장·실제 PTS12개 영상 표본의 삭제/undo/relaunch 관찰에서 명백한 새 clipping은 없었으나 재실행 로드 전 공백 프레임은 보존했다. 선택 표본으로 물리 지연이나 전 프레임 연속성을 보장하지 않는다(`/private/tmp/bandal-ink33-ui-review/review.md`).

## 2026-10-16 사용자 확인 — 빌드 31 지우개

사용자는 빌드31에서 여러 획을 쓴 뒤 연속으로 지우는 확인 요청에 **“즉시 지워지고 다시 나타나지 않음”**이라고 답했다. 해당 실사용에서 지우개 반응 지연과 삭제 획 재등장이 해결된 것으로 확인했다. 아래 2026-10-15의 지우개 사용자 확인 대기 상태를 갱신한다. 스크롤·확대, 전체 필기 지연, 필압·속도·끝 taper, 비정상 종료 시 삭제 보존이나 경쟁 앱과의 품질 동등성까지 확인한 답변은 아니다. 이번에는 사용자 결과만 기록하며 앱 코드·설치물·데이터와 봉인한 빌드31 검증 아카이브를 변경하지 않는다.

## 2026-10-15 빌드 31 — 혼합 페이지까지 GPU 유지·네이티브 지우개 적용

완료 잉크 mesh와 글상자/이미지/도형/구형 잉크 텍스처를 원래 순서대로 한 Metal pass에서 합성한다. 변경 없는 객체는 native token으로 재사용하고, 지우개는 네이티브에서 즉시 대상을 제외한 뒤 기존 ordered operation 저장·undo 경로로 전달한다. 준비 중 로컬 완료 획·ACK 식별자·정지 중 자원 복구·obsolete worker 예산 재admission을 검사했다.

최종 변경 영역 63개, 실제 UI 3개, 실제 iPad 195개 검사 모두 통과. 초기 소스의 기존 PDF 회귀 360개(357 통과/조건부 3 skip)는 별도 결과다. 혼합 UI에서 206→199→undo206 및 non-ink3→2→3, relaunch 보존을 확인했다. 설치 전후 61개 테이블·PDF10/Markdown4·journal0 동일, quick_check=ok. 빌드31은 20:13:47 KST 일반 실행(PID11873, args=[]) 상태다.

고정 후보는 `/private/tmp/bandal-ink31-build5`; 원본17파일 통합과 다른 작업26개 소스 해시 보존을 확인했고 원본 합본 Simulator 빌드도 통과했다. 원본의 최신 UI 합본과 설치된 고정 후보를 구분한다. 녹화 표본에서 삭제·undo를 확인했으나 1.952초 녹화 공백이 있고, 기존 Simulator 검정 상단 탭 줄도 남아 있다. 실사용 Pencil 체감은 사용자 확인 대기이며, 지원 불가/메모리 초과 호환 경로·필압/속도/taper·삭제 crash durability는 남은 범위다. 상세 검증과 한계는 `docs/handwriting-quality.md`의 빌드31 절을 참고한다. 증거는 `/Users/iseojun/.codex/artifacts/bandal-ink31-20261015`에 보존한다.


## 2026-10-15 필기 빌드 30 — 완료 GPU 잉크·네이티브 지우개·비동기 저널

지원되는 ink-only 페이지에서 완료 획도 Metal에 유지하고, 지우개 hit와 첫 표시 삭제를 네이티브에서 처리한다. 웹은 순서가 있는 삭제 operation으로 기존 저장·undo를 담당하며 fsync는 serial worker로 이동했다. 혼합 객체 페이지의 기존 fallback과 비정상 종료 전 메모리 접수분/미완료 삭제의 내구성 한계는 남는다. 상세 계약·실패 이력은 `docs/handwriting-quality.md`의 빌드30 절에 기록했다.

최종 Simulator native332(329 pass·3 skip·0 fail), Host 증분51(50 pass·1 private-fixture skip·0 fail), 실제 앱 지우기/undo/relaunch 및 pan/pinch UI2 pass. 실제 iPad150개는 한 번의 실행에서 전부 pass, skip0·fail0이다. 200획 삭제10회에서 네이티브 행 전달→GPU 제출은7.775–10.039ms였으며 물리 Pencil 전체 지연 측정은 아니다. 설치 전후61개 테이블·14개 PDF/Markdown·journal 동일성을 확인하고 빌드30을 인자 없이 일반 실행했다. 사용자의 실제 지우개 반응 확인은 대기 중이며 전체 품질 목표는 완료 처리하지 않았다.

원본 source/test/config40개를 통합할 때 다른 채팅의 전용 변경30개를 보존했고 합본 웹 패키징과 Simulator 빌드를 통과했다. iPad에는 frozen29 UI+최종30 잉크로 검증한 바이너리가 설치되어 있다. 합본의 후속 UI를 설치한 것은 아니다. 증거 경로: `/Users/iseojun/.codex/artifacts/bandal-ink30-20261015`.

## 2026-10-15 브라우저 — 앱 내부 탐색·복구와 터치 도구

활성 `DesktopBrowserHost`와 iPad renderer 어댑터에 구현했다. iOS 오류 도메인·코드, 탐색 ID, 요청 메서드, 실패 주소, 실제 WebKit 진행률을 연결한다. 최초 실패와 A→B 실패 모두 B를 재시도하며 늦은 오류·중지·다운로드 전환은 다른 페이지의 실패로 표시하지 않는다. 엔진·페이지 생성 실패는 같은 탭에서 다시 준비할 수 있다. POST는 자동 재전송하지 않고 원래 폼으로 돌아가는 경로를 제공하며 303의 GET 전환과 307의 POST 유지도 구분한다. 실패한 탭은 메모리 절약용 해제로 복구 주소가 사라지지 않게 보존한다.

도구막대는 주소·연결 상태·실제 진행률, 뒤로/앞으로, 중지/새로고침, 공유·다운로드·더보기로 정리했다. 700pt 미만에서는 앞으로·공유·다운로드를 메뉴로 옮기고 다운로드 배지는 유지한다. 이름 있는 메뉴 그룹, 44pt 터치 영역, HTTP·비공개 표시, 방문 기록·즐겨찾기 제안과 한글 조합 중 Enter 보호를 포함한다. 외부 브라우저 열기는 더보기의 선택 기능이다. 공통 네이티브 화면 가림을 재사용하며 브라우저 upstream 소스는 수정하지 않았다. ATS 예외는 `NSAllowsArbitraryLoadsInWebContent`에만 적용하고 URLSession 정책과 인증서 검증은 유지한다.

최종 검증은 별도 iPad Simulator(iOS 18.3.1)에서 **네이티브 38개·UI 2개, 0 fail**이다. 실제 WKWebView로 정확한 재시도, 초기화 복구, 오래된 콜백, 중지·크래시, HTTP·리디렉션, POST 로그인 팝업의 쿠키·`window.opener`, multipart 업로드, 다운로드 재시도·과목 저장, 프로필 격리를 검사했다. 가로 메뉴와 세로 오류 화면·화면 키보드의 실제 앱 UI도 통과했다. renderer 회귀는 360·600·1024pt 및 키보드가 차지한 360×420 영역, IME·Enter·Escape, 진행률·초기화 경쟁·복구 거부를 검사한다. raw/adapted strict TypeScript, 브라우저 전체 회귀, 공통 네이티브 표면 회귀, 전체 renderer/backend/font 패키지 빌드도 통과했다.

공개 사이트 검사는 Google·Naver·Wikipedia·서울대 포털 `my.snu.ac.kr`을 각각 자동/데스크톱/모바일 표시로 열어 **12개 모두 HTTP 200·로딩 완료**를 확인했다. 실제 계정의 SSO 로그인, 운영체제 파일 선택창 조작, 물리 하드웨어 키보드·실기기 수동 검증은 별도 범위로 남는다. 이번 변경은 실제 iPad에 설치하지 않았다. 최초 팝업 fixture의 `_blank` 기본 noopener 문제는 이름 있는 로그인 창으로 바로잡고 opener 검증을 유지했다. 한 중간 실행의 다운로드 전송 시간 초과와 연쇄 assertion 실패는 로그를 보존했으며, 해당 검사 자체를 바꾸지 않은 최종 전체 실행에서는 통과했다. 일시 중단의 근본 원인은 확정하지 않았다.

최종 결과 `/tmp/bandal-browser-upgrade-delivery.xcresult`, 공개 사이트 결과 `/tmp/bandal-browser-upgrade-ui-public.xcresult`. 로그·공개 사이트 JSON·폭별 메뉴 및 실제 앱 스크린샷 사본은 `/Users/iseojun/.codex/artifacts/bandal-browser-20261015`에 보존했다.

## 2026-10-15 11:12 사용자 확인 — 빌드 18 잔여 지연

사용자는 **획 그리기 지연은 많이 줄었지만 스크롤에서 획이 뒤따라오고 지우개 등 도구 전환이 늦다**고 확인했다. 빌드 18을 완전 통과로 판정하지 않는다. 11:13:43 KST에 기기 로그만 읽기 복사했으며 앱·자료는 변경하지 않았다. 기존 08:36 파일이 정확한 byte prefix이고 새 506줄은 11:11:13–11:12:23 사용 구간이다. 처음 20개 입력 전달은 5–89ms, 첫 제출 표본은 0–33ms였다. 지우개 구간에서는 입력 전달 대기 3,076ms·1,395ms와 객체 89개의 전체 배경 재생 1,372ms를 확인했다. 이 전체 재생은 앞선 대기보다 뒤에 기록되므로 한 번의 재생으로 대기 전체를 설명하지 않는다. 도구 버튼 수신 시각과 스크롤 전용 timing은 없어 해당 체감 지연을 직접 계산할 수 없다.

`mutableBoundary`는 필압 문제만을 뜻하지 않는다. 현재 캐시는 안정된 전체 이미지보다 객체 수가 줄어든 정상 삭제도 이 분기로 기록하며, 고정 20에도 settled 삭제·이전 획 수정의 메인 스레드 전체 재생이 남아 있다. 이를 별도 수정 대상으로 삼는다. 분석은 `/private/tmp/bandal-ink18-user-feedback-1115-analysis`에 있다. 아래의 19·20 자동 검사나 별도 회귀를 실제 사용자 문제 해결로 대체하지 않는다.

## 2026-10-15 빌드 20 별도 사본 — 이동 중 형광펜과 화면 배치

**`/private/tmp/bandal-ink20-candidate`의 최종 전체 Simulator 단위 370개는 368 pass·2 skip·0 fail, UI 15개는 15 pass·0 fail이다. 같은 제품 바이너리의 7,200초 반복 검사는 3,827.405초에 UI query timeout으로 실패했으며 장시간 통과가 아니다. 실제 iPad에는 설치하지 않았고, 빌드 18은 위 사용자 피드백에 따라 잔여 문제를 조사한다.** 원본 19의 UI·7,200초 검사와 충돌하지 않도록 제품·회귀·프로젝트 변경은 이 사본의 13파일에만 있다. 복사 기준 원본 700파일 SHA가 그대로이고, 빌드된 20 앱의 웹 자원 452개도 고정 19 manifest와 일치한다. 차이와 검증 목록은 `/private/tmp/bandal-ink20-qualified.patch`, `/private/tmp/bandal-ink20-qualification.json`에 있다.

성공적으로 설치한 불투명 배경의 정확한 픽셀·좌표·획 앞부분을 보존한다. 이동 중에는 이 배경과 그 뒤 완료 획·현재 획을 원래 순서로 합성한다. 처음 형광펜과 그 뒤 일반 펜이 정지 후 전체 crop을 기다리던 경로를 바꿨다. 기존 crop 밖으로 나가면 그 안쪽은 계속 표시하고, 새 영역의 정확한 배경은 100ms 및 손가락 이동 종료 대기를 우회해 즉시 비동기로 요청한다. 실행 하나·최신 대기 하나 제한은 유지한다. 아직 그리지 않은 복잡한 PDF 영역의 raster 비용을 없앴다는 주장은 하지 않는다. 화면 밖으로 잘린 프레임은 해당 입력이 표시됐다는 통계로 계산하지 않고 원래 입력 시각을 보존한다.

Metal의 다음 렌더 크기와 현재 보이는 뷰의 배치를 분리했다. 새 drawable이 실제로 제출될 때만 배치·배율·완료 UIImage를 같은 transaction에서 바꾼다. 테스트는 `MTKView.drawableSize` setter가 이전 뷰의 scale까지 즉시 3.75로 바꾸는 결함을 잡았다. 준비 단계는 `CAMetalLayer` 크기만 요청하도록 수정했고 기존 bounds·scale 유지 및 확대 후 drawable 준비 검사가 같은 기준으로 통과했다. 다음 표시 목록을 준비하는 것만으로 tile base를 먼저 승격하지도 않는다. 이로써 clear가 지연될 때 동일 완료 획을 타일과 Metal에 중복 표시할 수 있던 경계를 제거했다.

배경 작업 중 필압이 보정되면 캡처한 불변 visual token과 ID로 기존 raster의 캐시를 설치한 뒤 보정된 뒷부분을 다시 그린다. 앞부분·순서·이미지 자원·하이라이트·PDF 자체가 바뀐 결과는 거부한다. 모든 보정 때 전체 작업을 거부해 연속 필기에서 완료가 무한히 미뤄지는 방식을 피한다. pressure·style·kind 세 변화의 실제 SceneCache 검사에서 전체 재생 0회·tail 재생 1회·최종 RGBA 완전 일치를 확인했다.

검사는 실제 Surface 8개, Metal 배치 6개, 배경 소유·작업 결과 검증 12개와 기존 Metal·SceneCache·실제 WK/SQLite 왕복·navigation을 포함한다. 첫 60개 배치는 scale 및 확대 후 drawable 준비에서 실패했고 `/private/tmp/bandal-ink20-focused.log`에 보존했다. 수정 후 `/private/tmp/bandal-ink20-focused2.log`, `/private/tmp/bandal-ink20-DD/Logs/Test/Test-Bandal-2026.10.15_07-54-49-+0900.xcresult`에서 79개가 위 결과로 완료됐다. 제외 2개는 비공개 사용자 자료 opt-in과 Simulator가 지원하지 않는 실제 drawable 표시 시각이다. 실제 화면에 남은 이전 텍스처 픽셀의 전환 및 물리 Pencil 지연은 실기기 확인이 남아 있다. 첫 UI 실행에서 200획 문서 이동·확대는 통과했고, 20획 연속 입력은 세 번째 획의 `sceneAppend` 진단 값이 2에 머물러 실패했다. 실패 로그는 `/private/tmp/bandal-ink20-ui.log`와 `bandal-ink20-ui1-app.log`에 보존했다. 실제 Host·Surface 회귀를 추가해 최종 이미지 RGBA 완전 일치·clear 제출·실제 append=1이 모두 완료돼도 AX 값만 0인 경로를 RED로 확인했다. 성공한 scene 설치 callback에서 AX를 갱신하자 같은 회귀가 GREEN이 됐다. 입력 timing 이벤트를 만들거나 UI 기대값을 낮추지 않았다. 별도로 offscreen 복귀 시 새 크기를 stage하기 전 unhide가 구 drawable 요청을 시작하던 순서를 고쳤다. 실제 Surface 첫 요청 크기·generation 유지·최종 crop/clear 완료까지 검사했다. DisplayState 1·Lifecycle 1·Metal 배치 6 통과 뒤 아래의 최종 전체 단위·UI 재검증도 완료했다. 최신 변경 전의 79개 결과와 구 8파일 manifest는 현재 소스의 전체 검증으로 계산하지 않는다. 로그는 `/private/tmp/bandal-ink20-display-state-red.log`, `bandal-ink20-display-lifecycle-green.log`; 최신 소스 SHA는 `/private/tmp/bandal-ink20-prequalification-source-manifest.json`이다.

첫 전체 단위 로그 `/private/tmp/bandal-ink20-native-final.log`는 08:09:09 KST에 156.65초로 끝났다. Viewport 검사의 실제 UIImage 800px와 scene·Metal·selection 위치는 통과했으나 `MTKView.drawableSize`의 내부 구 값 200을 새 800과 비교한 두 assertion이 실패했다. Pencil 보정 검사도 이 구 getter의 크기로 offscreen readback을 요청해 nil이었다. 실제 `CAMetalLayer.drawableSize`, 준비·제출 geometry, live 픽셀, 최종 RGBA와 journal 계약을 확인하도록 테스트를 보완했다. Pencil의 기존 200ms 제출 한계·저장 순서·202획 최종 RGBA 조건은 유지한다. Viewport의 150ms 고정 sleep은 최대 3초의 의미상 완료 대기로 바꾸므로 이 검사는 기능적 handoff 검증이며 150ms 성능 통과로 표현하지 않는다. `renderedPixels`는 같은 encoder로 별도 texture를 다시 그리는 검사이며 실제 front buffer 표시 증거는 아니다. 같은 제품 바이너리의 UI 14개와 200획 이동 1개를 별도로 실행해 아래 결과를 얻었다.

수정된 제품 바이너리의 UI 15개는 **15 pass·0 skip·0 fail**, 08:20:24 KST에 593.962초로 완료됐다. 같은 14개 UI 범위에 200획 navigation 1개를 추가했다. 20회 UIKit 합성 접촉은 drawings=20·pending=0·sceneFull=0·sceneAppend=20, 제출 P95 16.81ms였고 실제 표시 시각은 Simulator에서 측정하지 않는다. 200획 문서는 확대·축소·스크롤·재실행 후 200개를 보존하고 메인 viewport 갱신 최대 0.94ms였다. 이는 펜촉→픽셀 지연 수치가 아니다. 종료 화면 두 PNG에서도 20개 완료 획과 이동 후 정지한 기존 획을 확인했으며 동작 중 front buffer의 표시 증거로 확대하지 않는다. 로그 `/private/tmp/bandal-ink20-ui-final.log`, 결과 `Test-Bandal-2026.10.15_08-10-27-+0900.xcresult`, 목록 `/private/tmp/bandal-ink20-ui-qualification.json`.

최종 전체 단위 재실행은 테스트 파일만 보완한 13개 변경 SHA를 확인한 뒤 진행했으며 기존 71획 로컬 사본의 private replay 두 개도 명시적으로 활성화했다. 실제 기기에는 읽기 로그 복사만 했다. 08:34 조회 로그는 08:15:31 로그와 바이트가 같고, 빌드 18 일반 실행 이후 새 Pencil 입력·render 진단은 여전히 0개다. 실행하지 않은 사용 구간을 성능 통과로 계산하지 않는다.

최종 단위 재실행은 08:23:41 KST에 **370개 중 368 pass·2 skip·0 fail**로 완료됐다(166.404초). 환경 제외는 공개 외부 웹 접속 opt-in과 Simulator의 실제 drawable 표시 시각뿐이다. 기존 71획 private scene·host 재생 두 개도 통과했다. 반복 host layout의 전체 재생 0·mapper 변화 1로 고정됐다. 첫 전체 검사에서 nil이었던 readback은 MTK 구 getter가 0×0인 반면 실제 layer·pending·submitted가 모두 1200×800이어서 잘못된 0×0 요청을 반환한 것으로 확인했다. 실제 크기 읽기·live alpha·202획 최종 RGBA·journal 순서·200ms 제출 한계가 통과했다. 로그 `/private/tmp/bandal-ink20-native-final2.log`, 결과 `Test-Bandal-2026.10.15_08-20-41-+0900.xcresult`.

소스 707파일·변경 13파일·앱 bundle 503파일·웹 자원 452파일을 `/private/tmp/bandal-ink20-final-freeze.json`으로 고정했다. 앱 실행 파일·debug dylib·Info.plist가 UI 15개 실행 때와 정확히 같다. 변경 소스·패치·SHA·결과 요약의 영구 사본은 `/Users/iseojun/.codex/artifacts/bandal-ink20-20261015-0824`에 있다. 원본 19는 그대로 유지한다. 20의 7,200초 반복은 C443·DD20에서 `fullRun=1`, 짧은 duration 변수 없이 시작했다. 로그 `/private/tmp/bandal-ink20-soak7200.log`, 결과 `/private/tmp/bandal-ink20-soak7200.xcresult`. 이 실행은 09:28:40 KST에 3,827.405초로 실패했다. 마지막 완료는 44회·필기 45개·pending 0·재실행 14회이며 이후 45회차 Markdown 입력 뒤 탭 목록의 AX query가 timeout됐다. 216.53초와 508.62초의 로그 공백을 확인했지만 호스트·실제 앱·사용자 중단 중 원인은 아직 특정하지 못했다. 실패 감사는 `/private/tmp/bandal-ink20-soak-failure-audit`, 기존 앱 Documents 35파일의 읽기 사본과 before/after/copy SHA 일치 기록은 `/Users/iseojun/.codex/artifacts/bandal-ink20-soak-failure-data-20261015-1125`에 보존했다.

후속 호스트 전원 로그 감사에서 09:16:17 Clamshell Sleep→09:19:55 DarkWake(218초), 09:20:08→09:28:39 절전(511초)이 두 검사 공백과 일치했다. 호스트 실행 중단의 직접 증거이며, 원 실행들을 제품만의 hang이나 데이터 유실로 단정하지 않는다. 원 실패 결과는 유지하며 7,200초 통과로 바꾸지 않는다. 근거 `/private/tmp/bandal-soak-host-audit.md`; 다른 사용자 승인 작업에서 전원 조건을 유지한 고정 20 재검사를 준비한다.

별도 코드 검토에서 이전 빌드에도 있던 texture upload 실패 경로를 찾았다. `MTKTextureLoader`가 실패하면 multiply 목적지 texture 없이 일반 alpha 합성으로 진행할 수 있으며 같은 이미지 identity는 재업로드를 막는다. 실제 발생 빈도와 GPU 메모리 압박 조건은 측정하지 않았다. 이 오류 복구 정책은 이번 정상 경로 수정과 별도이며 아직 해결되지 않았다. fail-closed·제한된 재시도·입력 통계/이전 화면 보존에 대한 제안은 `/private/tmp/bandal-ink20-texture-review.md`에 기록한다.

## 2026-10-15 별도 복구 사본 — 배경 텍스처 실패

`/private/tmp/bandal-texture-recovery`는 고정 20의 별도 후속 사본이며 **19·20 제품 및 실제 iPad에는 적용하지 않았다.** 정상 32×32 CGImage에 texture loader 실패를 주입하자 수정 전에는 multiply 획이 alpha 115의 일반 합성으로 반환됐고, 같은 이미지의 후속 업로드도 생략됐다. 독립 Catalyst offscreen RED 7개 중 대조 5개 통과·계약 2개 실패 후, Metal 수정으로 강화한 34개 검사가 전부 통과했다. 실패한 destination은 그리기를 거절하고 같은 이미지에는 즉시·50ms 뒤·그로부터 200ms 뒤의 최대 3회만 시도한다. nil 전환은 실패 예산을 초기화하지 않으며, clear·배경 없는 일반 펜은 계속 동작한다. 새 배경 복구 RGBA와 입력의 최초/최신 시각 보존도 확인했다.

Surface는 입력·보정·저장을 유지하면서 실패 중 continuous frames를 끄고 최대 한 개의 예약으로 복구하도록 별도 사본에서 연결했다. 실제 iOS Simulator SDK의 22개 관련 소스 module 컴파일과 Metal 6개·Surface 7개 XCTest typecheck는 통과했으나 **새 XCTest 및 실제 Surface 동작은 아직 실행하지 않았다.** Catalyst module 시도는 기존 `UIUpdateLink`가 해당 플랫폼에서 미지원이라 실패했고, 실제 iOS SDK로 확인했다. 별도 검토에서는 이동 중 crop 밖의 첫 stationary 형광펜이 업로드에 실패하면 urgent crop 요청까지 막히는 새 경계를 찾아 해당 실패 분기에서도 세대당 긴급 crop 한 번을 요청하도록 수정하고 회귀를 추가했다. 실제 Surface 검사에는 raw 저장, 늦은 필압 보정, 다음 pen의 순서, 움직이지 않는 첫 점, 모든 업로드 실패 때 무한 crop 방지, detach 및 새 페이지의 옛 예약 차단이 포함된다. 이 offscreen 결과는 실제 drawable 표시나 사용자의 두 번째 획 지연 해결 근거가 아니다. RED/GREEN 소스·실행 파일·로그·SHA는 사본의 `red-evidence/`, `green-metal-evidence/`에 보존했다. 독립 iOS blank host `/private/tmp/bandal-texture-recovery-harness`는 08:43에 generic Simulator `build-for-testing`을 마쳤고 신규 13개와 기존 30개, 총 43개 검사를 컴파일했다. 이 명령은 Simulator 설치·실행을 하지 않았으며 실제 XCTest 실행 수는 0이다. 앱 bundle SHA는 `BUILD-ONLY-RECEIPT.json`, 영구 사본은 `/Users/iseojun/.codex/artifacts/bandal-texture-recovery-20261015-0842/ios-harness`에 있다.

11:22 KST C443에서 실제 43개를 실행해 41 pass·1 skip·1 fail이었다. 실패는 동일 배경의 마지막 dependency review를 요청한 뒤 고정 5ms만 기다려 idle을 단언하던 검사였다. 제품은 그대로 두고 별도 fixture에서 실제 review 횟수 증가와 idle 도달을 최대 2초 조건 대기로 확인하고, 이후 250ms 동안 업로드·drawable 획득·geometry·render attempt·retry wake·submission 증가가 모두 없는지도 검사했다. 기존 저장·재시도 예산·새 배경 복구·최종 RGBA 조건은 유지했다. 11:30 재실행은 **43개 중 42 pass·실제 drawable 표시 시각 1 skip·0 fail**이며 제품 22파일이 첫 실행과 byte-identical이다. 첫 실패와 수정 fixture·사후 SHA·결과는 `/Users/iseojun/.codex/artifacts/bandal-texture-recovery-runtime-20261015-1130`에 보존했다. 고정 5ms 경합 가능성을 기능적 대기로 분리한 것이며 5ms 지연 통과나 실기기 검증 결과로 사용하지 않는다.

## 2026-10-15 동시 손가락·Pencil 입력 — 별도 재현 준비

고정 20의 읽기 감사에서 pan/pinch 시작이 모든 Surface의 `flush()`를 호출하는 경로를 확인했다. 이 함수는 아직 보정 대기 중인 완료 획을 강제 확정하고, 활성 Pencil을 비운다. recognizer가 같은 접촉을 계속 소유하면 후속 move/end는 Surface에서 무시된다. 같은 페이지 안에서 Pencil과 손가락이 겹치는 경우의 입력 보존 문제이며, 사용자가 보고한 0.5초 지연의 원인으로 아직 입증하지 않았다. Doxens에는 별도의 finger-begin flush hook이 없지만 UIKit 기본 touch-type exclusivity를 사용하므로 실제 동시 입력 허용까지 동일하다고 해석하지 않는다.

별도 사본에서 navigation 준비와 종료·저장 flush를 분리하는 회귀를 준비한다. 늦은 보정은 샘플별 원래 좌표 문맥과 보정 대상 속성을 보존하고, 같은 index가 coalesced 입력으로 재전달될 때와 lift 후에도 같은 규칙을 적용해야 한다. 일반 종료·background·페이지 화면 이탈의 기존 flush 정책은 이 수정 범위에서 바꾸지 않는다. RED/GREEN 실제 실행은 아직 없으며 제품 19·20 및 실제 iPad 18은 변경하지 않았다. 기존 동작을 유지한 RED seam의 별도 앱은 09:08:48 KST `build-for-testing`에 성공했다. 실제 Host를 포함한 제품 소스 30개와 신규 Surface 10개·Host 5개·기존 19개, 총 34개 검사를 arm64 Simulator용으로 컴파일했으며 실행 수는 0이다. 실제 Host의 앱 자체 navigation selector와 실제 임시 journal을 쓰지만 UIKit 다중 입력 판정이나 물리 Pencil 시험은 아니다. 경로는 `/private/tmp/bandal-ink-navigation-input-harness-red`, 영구 사본은 `/Users/iseojun/.codex/artifacts/bandal-ink-navigation-input-red-20261015`이다. 장시간 검사 중인 Simulator를 사용하지 않았다.

GREEN의 별도 앱도 09:11:46 KST generic Simulator `build-for-testing`에 성공했다. 같은 34개 검사를 컴파일했으며 실제 실행은 아직 0이다. 최종 소스·검사 7개와 harness 입력 37개의 SHA 일치, 별도 정적 검토를 마쳤다. force-only 보정에는 좌표 변환 캡처를 추가하지 않고, location/azimuth 보정에만 샘플 당시 변환을 보존한다. 영구 사본 `/Users/iseojun/.codex/artifacts/bandal-ink-navigation-input-green-20261015`에는 후보·새 검사·검토 기록·빌드 로그·bundle SHA 및 적용 전 diff를 보존했다. RED/GREEN 실행은 기존 장시간 검사가 끝나서 반환된 Simulator에서 순서대로 진행한다. 이 빌드 성공은 UIKit 동시 입력이나 물리 Pencil 지연 검증 결과가 아니다.

11:15 KST에 반환된 ABF Simulator에서 별도 bundle로 실제 실행했다. 첫 명령은 `-test-iterations 1`이 허용되지 않아 exit 64·실행 0이었고 로그를 보존했다. 해당 옵션을 제거한 RED 15개는 사전 예상과 같은 12 fail·3 pass(33 assertion 실패)로 조기 종료·샘플 누락·보정 손실을 재현했다. 같은 검사인 GREEN은 신규 15개 모두 통과했고 전체 34개는 33 pass·비공개 입력 opt-in 1 skip·0 fail이었다. 사후 source/bundle SHA도 그대로다. 로그·개별 결과·기대표·SHA의 영구 기록은 `/Users/iseojun/.codex/artifacts/bandal-navigation-input-runtime-20261015-1122`다. 제품 19·20·실제 iPad에는 적용하지 않았으며 실제 UIKit 동시 제스처 판정이나 펜촉 지연 검증은 아니다.

이전 숫자 전송 journal의 호환 복구는 현재 pending이 없었던 관측과 사용자 지연 우선순위를 고려해 설계 상태로 보존했다. 원본 7파일은 불변이며 구현하지 않았다. native/backend 계약과 실패·재시작 검사 계획의 영구 사본은 `/Users/iseojun/.codex/artifacts/bandal-legacy-recovery-design-20261015-0859`에 있다. 신규 획마다 전체 journal을 다시 읽는 비용을 추가하지 않는 것이 구현 전제다.

## 2026-10-15 빌드 19 후보 — 배경 픽셀과 타일 재사용

**제품 수정·독립 코드 검토와 C443 Simulator의 관련 71개 검사(69 pass·2 private opt-in skip·0 fail)를 마쳤다. 별도 ABF Simulator의 전체 단위 342개(338 pass·4 skip·0 fail)와 UI 14개(14 pass·0 fail)도 마쳤다. 같은 19 앱을 고정한 새 7,200초 혼합 사용 검사는 진행 중이며 완료로 계산하지 않는다. 실제 iPad는 빌드 18로 사용자 확인 중이며 19를 설치하지 않았다.** 동일한 71개 불변 표시 목록을 100회 전달하면 이전 builder는 revision을 100번 늘리고 타일 레이어도 100번 교체했다. 새 코드는 순서대로 같은 모습인 내부 token, 이미지 identity, 하이라이트의 실제 표시 필드, PDF paper 세대가 유지될 때 같은 snapshot을 반환한다. 타일 view는 snapshot identity·변환·화면 scale 변경만 반영한다. 실제 객체 추가·수정·순서·삭제와 이미지·하이라이트 변경은 새 snapshot을 만든다. 페이지 CropBox·회전·annotation 표시 변경도 paper를 갱신하며, 준비된 곡선의 aspect가 새 페이지와 다르면 다시 검증한다. PDFAnnotation 내용의 직접 편집에는 기존 명시적 invalidate 계약을 유지한다. 정지 후 타일을 숨기는 별도 변경은 포함하지 않는다.

초기 navigation raster의 9,695채널·최대68/255 차이는 분수 크기 배경 이미지의 `draw(in:)` 재샘플링과 마지막 픽셀의 불완전한 불투명 채움으로 정확히 재현했다. 새 코드는 할당한 전체 픽셀을 흰색으로 채우고 paper와 완료 이미지를 본래 픽셀 크기로 복사한다. 별도 Catalyst 실험은 48개 회전·CropBox·분수 viewport·투명도·형광펜 순서 조건에서 직접 전체 재생과 차이0·모든 alpha255였다. 이는 실제 앱 XCTest의 통과 기록을 대신하지 않는다. 증거 `/private/tmp/bandal-navigation-pixel-audit/README.md`.

영구 회귀는 `NativePDFFractionalRasterTests` 2개와 `NativePDFNavigationReuseTests` 8개다. 기존 `NativePDFCanonicalHandoffTests`도 초기·최종 화면을 중간 배경 이미지 없이 PDF와 객체를 한 번에 그린 독립 참조와 완전 일치하도록 강화했다. `NativePDFCommittedSceneCacheTests`의 옛 reference도 paper를 논리 bounds에 다시 축소하지 않도록 바로잡았다. 새 10개를 포함한 관련 71개 실행은 07:32:21 KST에 실패 없이 끝났다. 100회 동일 장면의 타일 교체 0회·revision 1개, 실제 WK/SQLite/Surface 경로의 초기 및 ACK 추가 픽셀 차이 모두 0이었다. 회전·잘린 페이지·분수 배율 24조건의 초기 화면·추가 획·늦은 필압 보정도 직접 전체 재생과 RGBA 완전 일치했다. 로그 `/private/tmp/bandal-ink19-simulator-focused.log`, xcresult `/private/tmp/bandal-metal-burst-DD/Logs/Test/Test-Bandal-2026.10.15_07-30-08-+0900.xcresult`. 100회 호출 합계 CPU 벽시계는 7.90ms였고 이를 물리 입력 지연 개선률로 표시하지 않는다.

네이티브 소스·검사·프로젝트 10개 SHA는 `/private/tmp/bandal-ink19-native-freeze.json`에 고정했다. 최종 웹 자원은 `/private/tmp/bandal-ipad-ux-final19-resources-manifest.json`의 452개이며 빌드된 Simulator 앱의 버전 19와 모든 자원 SHA 일치를 확인했다. ABF 전체 단위 로그와 결과는 `/private/tmp/bandal-ipad-ux-final19-native.log`, `/private/tmp/bandal-ipad-ux-final19-native.xcresult`다. 실행은 165.74초였고 기존 Metal 스트레스 기준을 바꾸지 않고 통과했다. 앞선 간헐 실패의 원인이 해명됐다는 뜻은 아니다. UI 및 장시간 혼합 사용 결과는 별도로 기록한다.

### 고정 빌드 19의 후속 결함 재현

제품을 바꾸지 않고 실제 19 앱·모듈을 별도 test host로 복사해 전체 SHA를 검증했다. 실제 Surface 5개 검사 중 대조 2개는 통과했고, 예상한 3개 결함의 assertion 5개가 실패했다. 이동 중 첫 형광펜과 완료 형광펜 뒤 일반 펜은 drawable이 준비돼 있어도 배경 crop을 기다리며 제출되지 않는다. 기존 불투명 형광펜 drawable은 새 viewport에 먼저 배치되어 pan 100pt·zoom 24.842pt의 anchor 오차를 보였다. 이는 제출·좌표 재현이며 실제 화면의 표시 지연 측정은 아니다. 최종 비동기 handoff를 기다린 뒤 모든 RGBA는 독립 전체 재생과 정확히 같았다. 최초 추가 픽셀 실패는 clear가 deferred된 상태에서 이전 UIImage를 읽던 fixture 조건으로 분리했으며 허용 오차나 고정 sleep으로 통과시키지 않았다.

같은 host의 별도 Metal 진행 검사는 50회 잉크→clear 전환이 모두 완료됐다(1 pass·실제 화면 표시 검사는 simulator skip). 제출 호출 최대 1.492ms·95th 0.464ms였으나 전체 phase 최대 200.577ms였으며 앞선 간헐 지연 원인이나 물리 Pencil 품질이 해결됐다는 의미는 아니다. 증거와 폐기한 중간 harness 실행은 `/private/tmp/bandal-ink-followup-harness/RESULTS.md`, 실제 host/bundle 경로·SHA는 `execution-artifact-receipt.json`에 기록했다. 19의 UI·장시간 검사는 고정 소스를 유지하고, 후속 수정은 별도 `/private/tmp/bandal-ink20-candidate` 사본에서 진행한다.

## 2026-10-15 빌드 18 — 저장 왕복의 숫자 표현과 전체 재생

**빌드 18은 07:18:16 KST 실제 iPad에서 테스트 인자 없이 일반 실행했다. 물리 Pencil 사용자 인수는 아직 대기 중이다.** 빌드 17 사용자 로그의 `appearance.71/73/74` 전체 재생은 숫자 왕복에서 재현됐다. Swift Codable → Foundation의 NSDecimalNumber → JavaScript → backend JSON 응답 → Foundation → WebKit → native snapshot 경로에서 소수 표기만 달라지는 경우와 binary Double 자체가 몇 ULP 달라지는 경우가 모두 있었다. 단순 NSNumber 비교뿐 아니라 전달 경계도 고쳐야 했다. 공개 `i/12345` 필압 1,000개 조사에서는 15개가 이전 전달 경로에서 renderer Double이 달라졌다.

입력 payload는 측정 Double을 직접 담고, `DesktopJSON`은 Foundation decimal token의 문자열을 정확한 Double로 파싱한다. backend 완료 응답과 이벤트에 같은 변환을 사용하며 snapshot store는 JSON을 다시 파싱하지 않고 컨테이너를 분리한다. 비교용 bytes와 실제 renderer가 같은 값을 사용한다. 캐시 비교는 boolean 타입을 구분한 뒤 유한한 Double을 정확히 비교한다. 좌표·필압을 양자화하거나 epsilon으로 변경을 숨기지 않는다. JavaScript 표준 `JSON.stringify(-0)`가 `0`을 반환하는 경계는 별도 검사로 명시했다.

실제 Host·Surface의 늦은 필압 보정부터 WKWebView, DesktopRuntime, SQLite, JSON 응답, WKWebView, native snapshot/ACK까지 연결한 공개 회귀에서 수정 전 `1/12345`와 `17/12345`는 기존 71개와 새 1개를 모두 재생했고 `2/12345`도 저장 정밀도 검사가 실패했다. 수정 후 세 경우 모두 journal·SQLite·renderer의 원본 숫자가 일치하고 전체 재생 0회, ACK 전후 동일 UIImage 및 모든 RGBA byte 유지, 다음 접촉의 live GPU 제출을 확인했다. 숫자 경계 1,020개 점과 준비된 경로, mutable container 분리, boolean/integer 구분, 비유한 값 거부도 검사했다.

Simulator 61개 검사 중 59개 통과·비공개 자료 opt-in 2개 skip·실패 0개다. 숫자 4, 실제 backend/Surface 2, scene cache 19, drawing store 5, host 8, navigation 9, runtime 10, sync 4를 포함한다. 로그 `/private/tmp/bandal-ack-backend-green.log`, 수정 전 실제 backend 실패 `/private/tmp/bandal-ack-backend-red.log`. 빌드 18은 빌드 17의 웹 Resources 452개를 바이트 단위로 유지한 채 위 native 수정만 포함한다. 직전 읽기 백업 `/private/tmp/bandal-ink18-immediate-backup/Documents`는 전체 필기 102행/활성 76개, 61개 테이블, 원본 PDF·Markdown 7개, pending journal 0개, SQLite quick_check=ok다. 다른 채팅의 후속 웹 UI 수정은 이 빌드에 포함하지 않는다.

실제 iPad에서도 같은 단위 61개(59 pass·2 private opt-in skip·0 fail), 연속 20획 UI와 200획 문서 확대·스크롤 UI 2개가 통과했다. 20회 합성 UIKit 접촉은 모두 손을 떼기 전에 표시됐고 `sceneFull=0`, `sceneAppend=20`, `pending=0`, 첫 표시 P95 77.94ms였다. 실제 WK→SQLite→WK 회귀에서도 세 필압 fixture의 전체 재생은 0회였다. 이 수치는 물리 Pencil의 펜촉→픽셀 지연이 아니다. 로그 `/private/tmp/bandal-ink18-device-qualification.log`, 결과 `.derivedData-device/Logs/Test/Test-Bandal-2026.10.15_07-14-13-+0900.xcresult`.

검사 후 읽기 백업과 직전 백업을 별도 DB 작업 복사본에서 비교했다. 전체 102행/활성 76개를 포함한 60개 테이블의 모든 값과 PDF·Markdown 7개 SHA가 같고 quick_check=ok, pending journal 0개였다. 나머지 `materials_index`는 `.bandal/__materials_index_state__` 센티널의 `mtime`·`updated_at`만 갱신됐다. 실제 자료 행은 같았다. `/private/tmp/bandal-ink18-post-test-preservation.json`에 정확한 차이를 보존했으며 61개 테이블 전체가 바이트 동일하다고 표현하지 않는다.

별도 품질 제한도 기록한다. 초기 비동기 navigation raster와 독립 UIKit 전체 재생에는 입력 전부터 9,695개 채널·최대 68/255 차이가 있었고, 새 획의 저장 ACK가 추가한 차이는 0이었다. 별도 Catalyst 재현에서 분수 픽셀 크기의 배경 이미지를 `draw(in:)`으로 다시 맞추며 리샘플하는 것과 가장자리의 불완전한 불투명 채움이 같은 차이를 만들었다. 별도 수정 후보를 검증 중이며 빌드 18에 포함하거나 해결됐다고 표시하지 않는다.


이전 버전의 미확인 journal 호환성도 별도로 조사했다. 이전 숫자 전달로 이미 SQLite receipt가 기록된 뒤 ACK만 유실된 경우, 원본 journal과 receipt fingerprint가 달라 새 실행의 복구가 거부될 수 있음을 합성 실제 backend에서 확인했다. 원본 journal과 기존 행은 보존되지만 해당 PDF 열기가 막힐 수 있다. 현재 기기의 업그레이드 직전·직후 pending은 0개여서 이 경우에 해당하지 않았다. 단순 ULP 허용이나 mutation UUID만으로 승인하면 서로 다른 원본을 합칠 수 있으므로 적용하지 않았다. 원본 journal bit-exact 대조·이전 전달의 정확한 재현·내구성 있는 원본 보관 후 ACK를 요구하는 후속안은 `/private/tmp/bandal-legacy-receipt-audit/PROPOSAL.md`에 있으며, 아직 제품 구현이 아니다.

## 2026-10-15 빌드 17 — 좌표 반올림에 따른 전체 잉크 재생

**06:50:30 KST 빌드 17 일반 실행 후 물리 Pencil 사용자 인수 실패.** 사용자는 두 번째 획 이후 지연이 여전히 남는다고 답했다. 06:56 실제 로그에서 첫째·셋째·넷째 완료 획의 appearance 변경으로 72/74/75개 전체 객체를 1,162/1,153/1,185ms 동안 재생했고 다음 입력 전달이 1,074/1,043/1,120ms 늦었다. 로그는 `/private/tmp/bandal-ink17-user-failure.log`에 보존했다. 새 읽기 백업은 `/private/tmp/bandal-ink17-user-failure-backup/Documents`이며 작업용 DB 복사본의 quick_check=ok, 전체 102행/활성 76개를 확인했다. 아래 합성 입력 통과를 사용자 인수로 대체하지 않는다. 개인정보가 담긴 PDF·JSON·스크린샷은 저장소나 릴리스에 넣지 않는다.

추가 조사에서 Swift Codable → Foundation JSON → JavaScript → Foundation JSON의 숫자 왕복을 재현했다. 같은 binary Double을 담는 두 NSDecimalNumber의 소수 표기가 다르면 기존 `NSNumber ==`는 false여서 확정된 마지막 획이 바뀌었다고 처리했다. 실제 첫째·셋째 획과 공개 합성 필압 `2 / 12345`에서 재현했다. 기존 검사는 최종 canonical 사전을 직접 재사용해 이 왕복을 빠뜨렸다. 유한한 binary Double의 정확한 동일성과 boolean 타입을 구분하는 후속 수정·실제 Host/Surface 통합 회귀를 진행 중이다. 좌표·필압을 반올림하거나 epsilon으로 변경을 숨기는 수정은 아니다.

Doxens는 완료된 획을 PDFPage annotation으로 붙이고 현재 획만 별도로 그린다. 현재 앱은 완료 잉크의 별도 화면 캐시를 쓰므로, 화면 좌표 변환의 사소한 변화가 전체 재생을 유발하지 않게 해야 한다. 실제 PDFKit의 분수 좌표 배치에서 mapper `a=1 → 1.0000000000000009` 변화와 캐시 무효화를 재현했다. 그 재생은 viewport 변경도 동반했으므로 원래 사용자 1초 반복 멈춤 전체를 직접 재현했다고 주장하지 않는다. 별도의 공개 회귀에서는 viewport를 고정한 채 같은 오차를 반복해 기존 동기 전체 재생 경로를 겨냥한다.

전체 페이지 bounds의 세 꼭짓점으로 변환을 구하고, 페이지 네 모서리의 역투영 차이가 1/1024 물리 픽셀 이하일 때만 기존 변환을 유지한다. 비교는 고정된 기존 mapper를 기준으로 하므로 오차를 누적하지 않는다. 실제 이동은 비동기 navigation crop으로 전환하며, 진짜 2pt 변환 후 최종 픽셀은 독립 전체 재생과 일치했다. 회전 CropBox 4방향과 배율 4개에서 진짜 이동을 무시하지 않는 것도 확인했다. 동일한 web layout의 중복 전송과 동일 aperture mask 재생성도 줄였다.

실기기 Host 1개·Navigation 9개·NativeSurface 5개와 실제 자료 UI 1개가 통과했다. 71개 위에 12획을 추가해 83개로 저장하고 재실행한 뒤 zoom 1→1.5와 세 번 스크롤했다. 전체 scene 재생은 0회, append는 12회였다. 합성 UIKit 접촉의 전달 대기는 `[9,8,11,12,6,7,5,6,12,8,10,6]ms`, 첫 표시 P95는 78.54ms였고 12획 모두 손을 떼기 전에 표시됐다. navigation refresh 455회 중 async crop 4회, refresh 최대 2.02ms, 경계 밖 pinch anchor 오차 0pt였다. 새 실행 로그에 1초 전체 재생은 없었고 느린 append CPU는 최대 37ms였다. 로그 `/private/tmp/bandal-ink17-actual-replay.log`, 결과 `.derivedData-device/Logs/Test/Test-Bandal-2026.10.15_06-37-41-+0900.xcresult`. 이 수치를 실제 Pencil 체감이나 Goodnotes/Notability 동등성으로 대체하지 않는다.

**검사 자료 복사 중 운영 실수와 복구:** 06:33 KST `devicectl device copy to --remove-existing-content true`를 UI-test 하위 폴더 대상으로 실행했으나 상위 Documents의 다른 내용까지 없어졌다. 즉시 사용자에게 알리고 앱을 종료한 뒤 06:24 전체 백업을 삭제 옵션 없이 복구했다. 백업의 33개 파일은 모두 바이트 단위로 일치했고 61개 테이블 전부 동일, 필기 전체 97행/활성 71개, SQLite quick_check=ok를 확인했다(`/private/tmp/bandal-ink17-recovery-verification.json`). 실기기 검사 후에도 정상 사용자 루트의 61개 테이블·97행·원본 PDF 해시는 그대로였다(`/private/tmp/bandal-ink17-post-test-preservation.json`). 복사 도구가 만든 UID 0 폴더는 앱 자체가 새 디렉터리에 파일을 재생성하고 모든 상대 경로·SHA-256·소유 UID·쓰기 권한을 확인한 뒤 rename으로 교체했다. 이전 복구본은 Library/Caches/BandalDeviceCopyRecovery에 남겨 두었다. 정상 BandalDesktop 38개 항목과 legacy Bandal 11개 항목의 복구는 성공했다. 마지막 별도 PrivateReplay 시험 폴더 이동만 EACCES로 실패했으므로 해당 두 시험 파일은 그대로 보존했다. 전체 복구 테스트 성공으로 표시하지 않는다. 이후 다시 복사해 정상 루트 18개 파일의 해시 및 61개 테이블 모두 백업과 동일하고 active71/quick_check=ok임을 확인했다(`/private/tmp/bandal-ink17-owned-preservation.json`). 기존에 켰던 native PDF 개발 설정도 복원했다. 임시 복구·설정 테스트 메서드는 저장소에서 제거했고 감사 소스·로그만 `/private/tmp`에 보존했다. 이 삭제 옵션은 다시 사용하지 않는다.

**백업 이후 편집은 보존 여부 미확정이다.** 다른 채팅의 Markdown 시험 요청은 06:24:02, 사용자 정상 응답은 06:27:55였고 백업은 06:24:50경이라 시험 도중 작성한 내용이 백업에 없을 수 있다. 06:24–06:33 사이 작성·수정 여부에 사용자는 “잘 모르겠음”이라고 답했다. 일반 실행 전에 Library 전체를 추가로 읽기 백업했다. 정상 WK store는 보이지 않고 테스트 store에는 펜 설정 하나만 있었다. 캐시 Markdown 4개도 기존 백업과 동일했고 CommonSync 기록은 없었다. SplashBoard 화면 8개도 압축 블록과 디코딩 픽셀을 검사해 검정/흰색 단색임을 확인했으며 추가 텍스트는 없었다. 코드의 Markdown 초안은 JS 메모리 전용이고 800ms 뒤 Documents에 자동 저장하므로, 현재 보존 자료에서 이후 편집을 복구할 사본은 찾지 못했다. 삭제 영향이 Documents에 한정됐다고 보장하지 않는다. 상세 감사 `/private/tmp/bandal-ink17-markdown-recovery-audit.md`, `/private/tmp/bandal-ink17-snapshot-audit/README.md`, Library 캡처 `/private/tmp/bandal-ink17-library-recovery/Library`. 별도 채팅의 읽기 전용 SQLite 감사에서도 SHM mtime 변경 가능성을 관찰했으므로 백업 전체 메타데이터 불변은 주장하지 않는다. 이후 DB 조사는 별도 작업 복사본에서만 한다. 사용자에게 이 한계를 알렸으며 무손실 복구라고 주장하지 않는다.

## 2026-10-15 빌드 16 일반 실행 — 필압 보정과 탐색 전체 재생

**06:22:12 KST 일반 실행·표시캐시 초기화 완료 후 사용자 검증 실패.** 사용자는 확대·스크롤이 버벅이고 필기가 뒤늦게 따라와 떠 있는 느낌이라고 보고했다. 06:23:42 로그에서 `render.cpu.1111ms.backdrop.1111ms`/`scene.full.objects.67` 직후 두 번째 접촉의 `input.delivery.1089ms`를 확인했고 이후71개객체가 같은상태에서도948–1,141ms 전체재생을반복했다. journal/fsync는0–5ms여서 이구간의주요병목은전체배경재생이다. 원인추가조사중이며 자동200획검사를사용자인수로대체하지않는다. 실제자료재현복사본은 `/private/tmp/bandal-ink16-user-failure-20261015/Documents/BandalDesktop`, 로그 `/private/tmp/bandal-ink16-user-feedback.log`이다. 개인필기재현자료는저장소/릴리스에포함하지않는다.

캐시 초기화 자체는 `render-cache.reset code=pdf.web.url`와 `runtime.started`를 정상 사용자 저장소 로그에서 확인했다. 백업 `/private/tmp/bandal-after-ink16-cache-reset-20261015/Documents`와 직전 백업을 대조해 필기92행의모든열, 캐시를제외한PDF3개경로/SHA-256이동일하며 SQLite quick_check=ok였다. 기록 `/private/tmp/bandal-ink16-preservation.json`. DB·원본PDF·보류필기·설정·로그인 저장소를 지우지 않았다.

빌드15 일반 실행 후 로그에서 아홉 번째 접촉의 첫 제출까지 677ms가 확인됐다. 이전 `prepare` 676ms는 접촉부터 성공한 제출 시도까지의 **벽시계 시간**이므로 이를 CPU 처리시간으로 해석하지 않는다. 새 진단은 renderPreview의 실제 CPU 구간(배경/기하/제출), 시도 사이 시간, drawable 미획득 횟수를 분리한다.

별도 동일 입력 재현에서 200획×96점의 최신/직전 획 필압 하나가 바뀌면 전체200획을 재생해 1x에서506–530ms, 2x에서929–950ms가 걸렸다. 최근4획을 제외한 체크포인트를 유지하는 수정 후 같은 입력은8.77–9.81ms/16.58–16.81ms, 재생4획으로 줄었다. 독립 전체 CoreGraphics 재생과 픽셀이 일치한다. ACK와 보정이 같은 프레임에 도착하는 경우도 clientMutationId를 통해 같은 꼬리로 판별한다. 오래된 획 수정은 전체 재생이 남는다. 이 수치는 시뮬레이터 재현이며 실제 Pencil 인수 결과가 아니다.

체크포인트 경계는 최근4획 고정에서 **아직 UIKit 보정이 끝나지 않은 가장 앞선 획**으로 확장했다. 200획 뒤8획이 보정 대기인 실제기기 검사에서 접미부8획만 재생했고(41.85ms), 모두 확정된 뒤 기존 이미지를 승격하는 데0.172ms가 걸렸다. 확정된 오래된 획을 편집하면 전체 재생이 필요하다.

추가 통합 검사: 200획×96점이 이미 저장된 실제 Surface에서 첫 접촉을 뗀 뒤 두 번째 접촉을 유지하며 네 차례 estimated-pressure 보정을 전달했다. 실제기기에서 보정 콜백2.247/2.087/2.245/3.962ms, 두 번째 첫 제출0.140ms, 전체재생1회 유지/보정당1획 재생을 확인했다. 매 보정마다 NativePDFJournal을 다시 열어 원본필압을 검증하고 최종202획 순서와 독립 전체재생 RGBA 일치를 검사했다. 두 번째 접촉을 떼기 전에 Metal 화면이 표시되는 조건도 실제기기에서 통과했다. 합성 UITouch를 사용하므로 물리 Pencil 인수와 구분한다.

실제기기 단위50개(Scene16·Metal15·Navigation7·Pencil10·CacheReset2)는 통과했다. 완료200획 위에서30회viewport변경, 이동 직후20회펜접촉, CropBox·90도회전된 페이지의 실제CATiledLayer 표시와 최종픽셀 정합을 포함한다. 로그 `/private/tmp/bandal-ink16-device-unit.log`. Markup=false 후보의 저장/undo/redo/재실행 및 연속20획 UIKit UI도 통과했다(20획/240원본점, 전체재생0·추가재생20, firstPresentP95 76.82ms). 이 UI도 물리 Pencil 입력은 아니다.

**손가락 확대 실기기 UI 실패를 재현한 뒤 수정했다.** PDFKit 기본pinch로 복원하고 pen/highlighter를reading mode로 설정하는 것만으로는 부족했다. 실제iPad에서 pinch.scale1.926→3.274, isZooming=true·zoomView존재·스크롤활성 상태인데 PDF/scroll배율은1.926으로 남았다. 같은 recognizer에서 서로 다른 배율 요청에도 native배율이 그대로인 경우에만 공개PDFView.scaleFactor로 보완한다. 정상 native배율 변화가 한 번이라도 있으면 그 gesture는 PDFKit에 맡긴다. 취소·새gesture·회전/분할크기변경·navigate·숨김·close는 비동기 관찰을 무효화한다. 비동기 배경 교체 뒤 AX진단값이 갱신되지 않던 별도 문제도 상태콜백으로 수정했다.

최종 actual Host7+heavy UI는 통과했다(`/private/tmp/bandal-ink16-device-navigation-final.log`). 200획 위 첫scroll, zoom1→1.7→3회pan→zoom1.1237, 재실행200획보존, viewport최대1.46ms였다. 보완배율적용10회 중 경계에 걸리지 않은8회에서 손가락 아래PDF좌표의최대오차0.0000pt였다. 같은최종소스의Simulator는보완적용0회로 native확대를유지하며통과했다(`/private/tmp/bandal-native-pinch-distinct-sim.log`). 캐시초기화와사용자일반실행은아래보존확인후별도로기록한다.

Doxens 비교에서 현재 앱의 custom pinch와 매 viewport 변경마다 PDF/완료획 전체래스터를 만드는 구조가 확인돼 PDFKit 기본 손가락 탐색 및 페이지 좌표 타일 표시로 바꿨다. 캐시 초기화 전 최신 사용자 데이터 백업은 `/private/tmp/bandal-before-ink16-final-20261015/Documents`이며 필기92행, 캐시를 제외한PDF3개, SQLite quick_check=ok를 확인했다. `--reset-render-caches`는 시작 시 NativePDFCache·WK 리소스 캐시·URLCache만 초기화한다. 완료 확인은 위 일반 실행 기록을 따른다.

실제화면도 XCUIScreen.main.screenshot으로 확인했다(`/private/tmp/bandal-ink16-final-screen/57EA42B5-B931-4D6F-A67A-BC764C3B9CC3.png`). 같은 시점 app.screenshot은 회전·잘림과 검정대역을 포함했지만 전체display capture는 가로창1194×834와 PDF본문1194×766이 정상 표시됐다. 이 캡처 오류를 제품의 검정화면으로 오인하지 않는다. 관련 로그 `/private/tmp/bandal-ink16-device-screen.log`.

공통소스 snapshot은 현재0.84.5(`b05ae406763659c8ce1ecc92b46e1cd6e7136d92`)이며1,021개 파일을 해당커밋과 byte-for-byte 확인했다. Windows에서 읽기전용 사본을 fsync하려던 문제는 PDF originals뿐 아니라 sync journal/conflict 복구의 private-copy 경로까지 수정했고 실제bundle durability5검사, 관련CI1,071검사, Windows 패키지E2E41검사가 통과했다. macOS 패키지도41검사와arm64/x64공증에 통과했다. 05:58:16 KST에 v0.84.5를 공개했으며12개산출물의SHA-256/크기, 공개다운로드, latest API와양쪽자동업데이트피드까지확인했다. 릴리스: https://github.com/seojune662/bandal/releases/tag/v0.84.5. 이전0.84.3/0.84.4 실패·취소이력은 변경하지 않았다.

## 2026-10-15 빌드 15 — 짧은 연속 획의 drawable 대기

**05:37:23 KST에 일반 실행했으나 물리 Pencil 사용자 검증은 실패했다.** 첫 획은 따라오지만 두 번째부터 약0.5초 지연되고 손가락 확대·스크롤도 제대로 되지 않는다는 피드백을 받았다. 자동 검사 통과를 실사용 품질 개선의 완료 근거로 삼을 수 없다. 설치 전후 사용자 필기80행의모든열·PDF4개의경로/해시가일치하고SQLite무결성검사도통과했다. 보존기록은 `/private/tmp/bandal-ink15-preservation.json`이다.

빌드 14 실제 사용에서 “줄었지만 여전히 남음”이라는 피드백과 1031/1024ms 첫 제출을 확인했다. 하나의 Core Animation transaction 안에서 ink/clear 8회를 제출하는 burst 회귀에서 수정 전 **1001.414ms**, autoreleasepool만 추가했을 때 **1002.550ms**로 실패했다.

발표되지 않은 drawable을 2개로 제한하는 방식도 폐기했다. Simulator에서는 최대8.953ms로 통과했지만 실제 iPad에서는 **1003.890ms**로 실패했다. presentation callback을 MainActor로 옮겨 자원 반환을 늦춘 방식도 실제 iPad **1003.003ms**로 실패했으며, 그중 **drawable 획득1002.374ms**, 인코딩0.164ms, 스케줄 대기0.387ms였다. presentation callback은 실제 버퍼 재사용 가능 시점을 보장하지 않았다.

현재 후보는 전용 직렬 큐에서 `CAMetalLayer.nextDrawable()`로 화면 버퍼만 사전 획득한다. 요청1개·준비된 버퍼1개로 제한하며 UIKit에서는 준비된 버퍼를 즉시 가져온다. 준비되지 않으면 `submitFrame()`이 false를 반환하고 Surface가 다음 화면 갱신에서 최신 획을 다시 계산한다. 오래된 geometry나 이미지 변경 closure를 작업 큐에 저장하지 않는다. `MTKView.draw/currentDrawable/currentRenderPassDescriptor`를 통한 메인 스레드 재획득 경로는 제거했다. 크기 변경·숨김·분리 때는 generation으로 이전 응답을 폐기하고, 획득 실패 때는 다음 갱신까지 기다려 idle 무한 재시도를 막는다. UIImage 전환은 성공적으로 인코딩한 clear와 같은 Core Animation transaction에서만 실행한다.

`MTKView.draw()` 우회 뒤 크기 변경 회귀가 실패하여 추가 원인을 확인했다. `MTKView.drawableSize=(96,80)`일 때 backing `CAMetalLayer.drawableSize=(128,128)`가 남았으며 MetalKit은 draw 안에서 수동 크기를 지연 적용했다. 따라서 메인에서 layer의 크기를 명시적으로 동기화한 뒤 백그라운드 획득을 요청한다. 이 수정 전 후보는 실제 PDF의 첫 표시 검사도 실패했으므로 사용자 일반 실행에 제공하지 않았다.

크기 동기화 포함 최종 후보의 검증:

- 실제 iPad Metal **15개 통과**. 50burst/200접촉/400제출 시도에서 최대CPU **0.725ms**, 실제제출64·다음갱신으로연기336·동기화이미지7. 이전 약1초 정지를 재현한 동일 경로다. 크기 변경·숨김·분리·작업 중 무효화·nil 획득·실제 표시 시각·투명도/픽셀 회귀 포함.
- 실제 UIKit UI **3개 통과**: 스타일/손가락확대, 선·점·undo/redo·저장·재실행, 연속20획. 연속20획은 모두 펜을 떼기 전에 표시됐고 pending0·sceneFull2고정·sceneAppend20이었다. 첫표시P95 **73.19ms**, 전체표시P95 **64.11ms**. 약2초 간격의 UI 자동화이며 빠른 물리 Pencil 결과로 간주하지 않는다. `/private/tmp/bandal-ink15-ui-final/C7C92ABC-1FF5-434D-9DD7-32D9011060D1.png`에서20획 표시도 확인했다.
- 실제 iPad 접촉 유지 검사: 첫표시 **29.83ms**, 펜을 떼기 전14회 제출. 마지막 점의 위치·압력·시각까지14개 원본 샘플을 정확히1회 저장하며, 이전 이미지 유지 후 최종RGBA가 정적 전체 재생과 일치한다.
- Simulator Metal15개 중 **14개 통과·실제 하드웨어 표시1개 제외**. 최종 burst 최대4.619ms·제출68. 직전 실행은CPU1.418ms였지만진행횟수19<25로1회실패했고, 코드와 기준을 바꾸지 않은 재검사에서 통과했다. 해당 변동도 기록하며 기준을 완화하지 않았다.

빠른 합성20획 검사에서1회58/60샘플 실패도 별도 조사했다. 계측으로 UIKit의 지연 reset이 다음 가짜 접촉을 취소하는 테스트 수명 문제를 재현했다: 이전 접촉을 직접 reset한 뒤에도 state가ended(3), 다음 가짜 begin 뒤에도3이며 `_UIGestureEnvironmentUpdateGestureGraph → _resetGestureRecognizer → reset → cancelPencilGesture`가 첫점만 저장했다. 합성 호출은 UIKit의 추적touch가0개이므로 실제 이벤트 상태 전이를 대신하지 못한다. 같은 Surface/Metal/Store와24ms접촉·8ms간격·60점 보존 검사를 유지하고, 합성 접촉마다 새 production recognizer를 사용하도록 회귀를 보정했다. 창 활성화는 최대1초 내에서 기다리며 활성화되지 않으면 실패한다. 수정 후 실제 iPad3회와Simulator3회가모두통과했다. 실제iPad60접촉/180원본점에서begin최대0.640ms·end1.186ms·첫제출15ms이며, 저장·마지막점·최종RGBA검사는그대로유지했다. 최종로그는 `/private/tmp/bandal-ink15-rapid-fixture-final2.log`다. 관련기기단위검사는서로독립적인15개Metal+9개gesture로합계24개이며, 마지막rapid검사만별도3회실행한결과를합산한것이다. 실제 UIKit의 반복 recognizer는 위20획 UI 검사가 검증한다. 제품 입력 코드를 우회하거나 저장 검사를 느슨하게 하지 않는다.

실제 기기 로그는 `/private/tmp/bandal-ink15-async-device-final.log`, Simulator 최종 로그는 `/private/tmp/bandal-metal-resize-verify.log`, 합성 reset 원인 로그는 `/private/tmp/bandal-rapid-fixture-instrumented.log`다. [Apple drawable 문서](https://developer.apple.com/documentation/quartzcore/cametallayer/nextdrawable%28%29)는 pool 고갈 시 최대1초 대기를 명시한다. 로컬 iOS26.5 SDK의 `UIKit.framework/Headers/UIUpdateActionPhase.h`도 메인 스레드의 nextDrawable 대기를 피하고 백그라운드에서 획득하도록 권한다. 진단은 준비·인코딩/제출·백그라운드 획득을 나누며 `waitUntilScheduled()`도 제출 시간에 포함한다. 물리 Pencil 사용자 인수는 아직 필요하다.

## 2026-10-15 빌드 14 — 여러 획 이후 누적되는 지연과 Doxens 곡선

**05:07:56 KST에 일반 실행했으며 물리 Pencil 인수는 실패했다.** 사용자는 설치 후 “줄었지만 여전히 남음”이라고 답했다. 이어 확인한 실제 Pencil 로그에서 짧은 연속 8획 중 6번째·8번째의 첫 제출이 1031·1024ms, 일부 첫 표시가 펜을 뗀 뒤 1082ms였다. XCTest의 약 2초 간격 20획 통과로 빠른 실제 필기를 대체할 수 없음을 확인했으며, drawable 수명·대기 경로와 빠른 연속 입력 회귀를 후속 조사 중이다.  빌드 13 자동 검사 이후 사용자는 “첫번째 드로우에선 문제가 없는데 그 뒤에 계속 쓰면” 문제가 생긴다고 했고, 추가 확인에서 **“획을 여러 번 쓸수록 펜 끝을 늦게 따라옴”**을 선택했다. 따라서 첫 획 검사 통과를 사용자 문제 해결로 판정하지 않는다. 사용자 저장소의 실제 빌드 13 로그에서도 04:41 KST 연속 필기 중 제출 지연 282·307·309·311ms와 첫 표시 445·450ms(펜을 뗀 뒤)를 확인했다. 같은 세션의 빠른 획은 제출 약 1ms·표시 12~14ms였다. 이 기록은 앱 수신 이후 내부 계측이며 외부 카메라로 측정한 펜촉→픽셀 지연은 아니다.

완료 획마다 전체 화면의 기존 CGPath를 다시 그리던 경로를 확인했다. 첫 수정은 이전 opaque 화면에 새 획만 합성하고, 저장 ACK의 ID/시간 변경은 화면 변경으로 취급하지 않는다. 보정·삭제·undo·순서·배경·viewport 변경은 전체를 갱신한다. Simulator의 200획×96점에서 전체 재생 약 504ms가 증분 합성 약 37.7ms로 감소했으나, 모든 원본 점을 재귀 비교하는 ACK만 약 37.2ms로 남았다. 이 수치를 해결 완료로 보지 않고 불변 객체 토큰과 변경 객체 전달을 추가했다. 최종 Simulator에서는 200획 append 2.23ms / 전체 재생 526.52ms / metadata ACK 0.12ms였다. 실제 iPad Debug에서는 50·100·200획의 append가 각각 3.23·3.23·3.26ms로 유지됐으며, 200획 전체 재생은 763.27ms, metadata ACK는 0.15ms였다. 새 획의 토큰 생성은 96점 기준 약 0.12ms이고 기존 원본 점 비교 횟수는 0이다. 이는 고정 viewport 합성 연산의 측정이며 물리 Pencil 지연 개선률은 아니다. Native drawingPatch는 새 획 1개만 전달하고 UI-only 갱신은 0개를 전달한다. 틀린 revision/ID의 갱신은 상태를 변경하지 않고 거부하며 응답 유실은 다음 전체 reset으로 복구한다. 방문한 모든 페이지의 경로를 보유하지 않도록 Row의 준비 경로는 weak 참조다.

Doxens의 centripetal 제어점은 v4로 이식했다. 원본 위치·필압·시간·기울기는 그대로 보존하고 측정 압력을 한 번만 필터링한다. 첫 점·두 점·마지막 점은 미래 입력을 기다리지 않으며 예측은 측정 곡선의 제어점에 넣지 않는다. Swift/TypeScript 공통 21개 fixture의 95,037개 수치 최대 차이 3.33e-16, 원16/32 전체 최대 중심선 오차 약 39% 감소를 확인했다. [설계·측정 범위](handwriting-quality.md)를 따른다.

중간 검증: Simulator의 기하·경로 캐시·저장·host 34개 통과 후 scene/입력/viewport/기하 28개 통과(겹치는 검사는 합산하지 않는다). 새 scene 합성은 1×/2× fractional viewport의 반투명 펜·형광펜 교차 전체 픽셀이 전체 재생과 정확히 일치했다. 웹 v4 입력·Scribble·세션·선택·포인터·배치·undo·복구 및 strict TypeScript 통과. 웹 측정·예측 교체 24개 전체 alpha mask와 저장 전환 전체 RGBA 차이는 0이다.

v2/v3/v4의 4방향 CropBox 회전 동기화, 원본 metadata, 같은 ID 충돌 보존·복구, 실제 저장 영수증/재실행과 PDF 내보내기(4회전 픽셀 불일치 0)를 확인했다. Electron ABI projector도 v2/v3/v4 읽기 및 기존 교환 저장소 보존 검사를 통과했다. `--sync`와 `--projector`를 한 fixture로 합친 첫 실행은 앞 검사가 노트 본문을 바꾸어 뒤 검사의 텍스트 검색 전제가 깨졌다. 개별 `--pdf --projector` 실행으로 통과했고, 제품 실패로 은폐하거나 첫 실행을 통과로 계산하지 않는다.

데스크톱 공통 소스는 `b2f7932`에 구현했고 최종 snapshot은 `da3dc42`/0.84.3이다. 0.84.2 CI에서 기존 rename callback/점 표시 테스트 기대값 3개가 실패하여 이력을 유지한 다음 0.84.3에서 기대값을 보완했다. 0.84.3의 CI 1,064개 관련 검사와 별도 backend 통합 검사/타입 검사가 통과했으며 공개 릴리스는 별도 검증 중이다. snapshot 1,021개 원본 파일이 canonical 소스와 일치한다. 기존 package의 사용자 reel 스크립트는 유지했다. 설치 전 사용자 백업 `/private/tmp/bandal-before-ink14-20261015/Documents/BandalDesktop`의 SQLite `quick_check=ok`, 필기 67행을 확인했다. 최종 설치 전후 사용자 `pdf_drawings` 67행 모든 열과 PDF 4개 경로/SHA-256 동일, 양쪽 SQLite quick_check=ok를 확인했다. 최신 설치 직전 백업은 `/private/tmp/bandal-before-ink14-final-20261015/Documents`다. 불변 Row/scene/host/입력/저장 관련 Simulator 39개와 실제 iPad 필기 단위 52개가 통과했다. 첫 UI 실행 2개는 새 팔레트/사이드바의 aria-pressed가 접근성 Button 대신 Switch로 노출되어 PDF 열기 단계에서 실패했으며, 관측한 접근성 ID로 fixture를 수정해 다시 실행 중이다. 제품 입력 검사 성공으로 계산하지 않는다. 수정한 UI 2개는 통과했다(선·점/undo/redo/저장/재실행, 연속20획). 연속20획은 모두 펜을 떼기 전에 표시됐고 sceneFull=2 고정·sceneAppend=20·pending=0이었다. 첫 제출은 각0~2ms였지만 수신→첫 표시p95=83.27ms로, 물리 Pencil이나 빠른 문자 작성 인수 결과가 아니다.

## 2026-10-15 빌드 13 — 펜 끝을 뒤따르는 지연 개선

사용자는 필기 품질 목표를 다시 요청했고, 가장 불편한 증상으로 **“펜 끝보다 획이 늦게 따라옴”**을 선택했다. 연결 기기에서 개발용 네이티브 PDF가 켜진 빌드 12를 사용 중임을 확인했다. 기존 작업 중 변경을 보존한 채 네이티브와 웹 경로를 모두 개선했다. **빌드 13은 04:31 KST에 테스트 인자 없이 일반 실행했으며 네이티브 설정을 유지했다. 물리 Pencil 체감 인수와 경쟁 앱 비교는 아직 완료되지 않았다.**

- **입력 시점:** CADisplayLink만 기다리던 렌더링을 UIUpdateLink의 일반/저지연 이벤트 전달 직후로 옮겼다. UIKit이 더 늦은 Pencil 전달을 보장할 때는 그 배치까지 받아 한 번 제출한다. 보이지 않는 페이지는 dirty 상태만 보존하고 지속 갱신을 멈춘다. 즉시 표시 요청(`wantsImmediatePresentation`)은 켜지 않았다. [Apple의 저지연 이벤트 설명](https://developer.apple.com/documentation/uikit/uiupdatelink/wantslowlatencyeventdispatch)을 따른다.
- **긴 획:** 기하뿐 아니라 삼각형 정점도 유지한다. 연속 revision의 변하지 않은 접두부를 재사용하고, 프레임 누락·예측 교체·이른 측정 보정에서는 안전하게 필요한 부분을 다시 계산한다. 최대 3개 GPU 버퍼를 빌려 쓰며 사용 중인 버퍼를 덮어쓰거나 메인 스레드에서 완료를 기다리지 않는다.
- **진단·보존:** 필기 중 통계 정렬과 접근성 갱신은 매 프레임 대신 제한된 빈도로 발행한다. journal은 실제 파일을 매번 검증하되, 동일 바이트와 파일 식별자가 이미 성공한 내구성 장벽과 일치할 때만 중복 동기화를 생략한다. 바뀐 보정값·완료 표시·새 journal·교체된 파일은 계속 동기화한다. 뒤 획의 보정값도 앞 획의 완료 실패 전에 디스크에 보존한다.
- **웹 필기:** 입력 이벤트 안에서 직접 미리보기를 갱신하고 측정 기하/경로 문자열을 증분 계산한다. 예측은 별도 임시 데이터로 유지하며 마지막 측정 필압을 사용한다. 측정·예측은 하나의 compound SVG path로 그린다. 최종 모양과 달라지는 청크별 안티앨리어싱을 피하기 위한 선택이며, WebKit의 전체 경로 파싱 비용은 남아 있다. 저장 응답 전에는 원본 optimistic row와 같은 layout commit에서 미리보기를 넘긴다.
- **Doxens:** 실제 입력·미리보기·저장 경로를 조사했다. 구심형 Catmull–Rom과 펜 종류 구분은 재사용 후보지만, coalesced 시간 왜곡·작은 글씨 샘플 제거·필압 위치 재배분·마지막 점 누락은 가져오지 않는다. **이번 빌드에 Doxens 곡선 알고리즘을 이식한 것은 아니다.** 원본 샘플을 유지하는 다음 버전 설계와 실기기 비교 방법은 [필기 품질 조사](handwriting-quality.md)에 기록했다.

| 검사 | 결과 |
|---|---|
| `InkLatency13NativeFinal` 실제 iPad | 단위 **58개 + UI 2개 통과**. 메시/버퍼, journal, 입력, PDF 확대/회전, Metal 픽셀 비교, 선·점·undo/redo·재실행, 색/폭 메뉴·손가락 확대 |
| `InkLatency13Telemetry` 최종 진단 변경 | 단위 **8개 + UI 1개 재통과**. 일반 실행 전에 canonical 웹 번들도 함께 포함 |
| `InkLatency13MinimumFinal` iPadOS 18.3.1 | **57개 통과·1개 제외**. Simulator Metal에는 실제 drawable 표시 시각 API가 없어 해당 검사만 제외하며 가짜 표시 시각을 만들지 않음 |
| 웹 | 전체 Pencil suite와 원본/변환 TypeScript 통과. 640점 입력에서 RAF 요청/React commit 0회. 펜·형광펜, 곡선·교차, 측정/예측 교체, 1×/2×의 전체 alpha mask 24개와 지연 저장 전환 전체 픽셀 비교 차이 0 |
| PDF·저장 | 네 방향 CropBox/회전 내보내기 픽셀 불일치 0. 실제 backend의 v2/v3 저장·파일 교체 거부·이동·idempotent 복구 검사 통과. canonical 빌드·패키지 검증 통과 |

실제 iPad Debug의 2,400점 획 마지막 4점 갱신에서 **230,394개 대신 384개 정점**을 다시 계산·업로드했다. 증분 메시+업로드는 약 **0.033ms**, 기존 전체 CPU 삼각형 계산은 약 **16.8ms**였다. 이는 특정 연산의 측정이며 입력→표시 지연 개선률이 아니다. 최종 UIKit UI fixture에서는 첫 실제 표시 53.72ms, 수신→표시 p95 62.05ms를 기록했고 펜을 떼기 전 48프레임 표시를 확인했다. 이 수치 역시 XCTest 손가락·자동화 환경이며 물리 Pencil의 필기감이나 Goodnotes/Notability 대비 결과로 해석하지 않는다.

초기 실기기 배치에서는 scene에 연결되지 않은 구형 UIWindow 시험 fixture가 UIUpdateLink를 깨우지 못해 1개 실패했다. 실제 앱과 같이 활성 UIWindowScene에 연결하도록 시험을 수정한 뒤 관련 15개와 최종 전체 60개를 통과했다. 웹의 초기 청크 방식은 전체 가장자리 비교에서 차이가 발견되어 제거했으며, 최종 단일 경로만 픽셀 일치 검사와 canonical 패키지에 포함했다.

**사용자 자료 보존:** `/private/tmp/bandal-before-latency13-20261015`와 `/private/tmp/bandal-after-latency13-20261015`의 SQLite `quick_check=ok`, `pdf_drawings` **57행 모든 열 동일**, 사용자 저장소 PDF **4개 경로·SHA-256 동일**을 확인했다. 테스트 자료는 별도 `BandalDesktop-UI-Tests` 저장소를 사용했다.

## 2026-10-14 빌드 11 — 쓰는 동안 두께가 불규칙해지는 문제

사용자는 빌드 10에서 **“획이 잘 그려져”**라고 확인했지만, 잉크가 번지는 느낌과 부드럽지 못한 필기감을 보고했다. 추가 확인에서 **“쓰는 동안 선 두께가 불규칙하게 바뀜”**을 지목했다. 입력 전달 성공과 필기 품질 인수 실패를 구분하고, 이번 변경은 이 증상에 집중했다.

**설치 상태:** 빌드 11을 2026-10-14 16:36 KST에 연결된 iPad에 업데이트하고 테스트 인자 없이 일반 실행했다. 개발용 네이티브 PDF 설정은 켜진 상태를 유지했다. 실제 Pencil로 새 획을 썼을 때의 품질은 사용자 확인 대기다. 기본값 꺼짐·Release 제외 정책은 유지하며 Goodnotes/Notability 수준을 달성했다고 표시하지 않는다.

- **두께:** 공통 v3 렌더러에서 시간 기반 필압 필터(24ms)와 완만한 두께 응답을 사용한다. 입력 좌표·원본 압력·시간·기울기는 그대로 저장한다. 예측점은 마지막 측정 압력을 사용해 미리보기 끝의 두께가 예측 압력에 흔들리지 않으며, 저장에는 포함하지 않는다.
- **윤곽:** 인접 원의 외접선으로 연결하고 둥근 가장자리를 세분화했다. Metal은 지원 기기에서 4배 MSAA를 사용하며 2배/1배로 대체할 수 있다. 획 내부 겹침은 하나의 커버리지로 합성해 반투명 펜·형광펜이 중첩 구간에서 반복해서 진해지지 않는다.
- **긴 획:** 바뀐 점 이후만 필압과 윤곽을 다시 계산하며, 페이지 좌표 변환은 GPU에서 한다. 예측점 교체·뒤늦은 측정값 보정·점 배열 축소를 검사했다. 한 입력 이벤트에 들어온 보정은 완료 순서대로 획당 한 번 복구 기록에 저장한 뒤 원본 저장소로 넘긴다.
- **호환성:** 새 네이티브·iPad 웹 필기는 `inkVersion: 3`을 저장한다. 기존 v2/legacy 획을 변환하지 않으며 버전별 표현을 유지한다. 데스크톱 커밋 `a7500f4`는 표시·선택·보드/PDF 내보내기·검증 계약을, `58f4cf6`은 동기화 변환기 패키지를 반영했다. 설치된 데스크톱 앱 바이너리를 재빌드·설치한 결과는 아니므로 이전 앱이 v3를 지원한다고 간주하지 않는다.

### 검증 결과와 한계

| 검사 | 결과 |
|---|---|
| `InkQuality11b` 실제 iPad | **32개 통과**: 단위 30개 + UI 2개. v2/v3 기하·캐시·Metal 커버리지/투명도/좌표 변환·일괄 보정 저장, 실제 UIKit 선·점 입력→원본 undo/redo→ACK→재실행 복원, 도구·색·두께 메뉴·손가락 확대 |
| `InkQualityMinimum11` iPadOS 18.3.1 시뮬레이터 | **20개 통과**: v3 기하·캐시·Metal·보정 처리 |
| Swift/TypeScript 공통 계산 | 동일 golden 입력의 357개 수치 최대 차이 0. 기존 v2와 새 v3의 혼합 저장·회전·충돌 사본을 검사 |
| PDF 내보내기 | v3를 포함한 네 방향 CropBox/회전 fixture에서 PDF.js 래스터 비교 불일치 0픽셀 |
| 원본 연결 | canonical 빌드·패키지 무결성·strict TypeScript, WebKit Pencil/Scribble/세션/선택/포인터/배치/undo/복구, 실제 SQLite `--ink-v2 --pdf-binding --pdf --sync`, Electron ABI `--pdf --projector` 통과 |

실제 iPad Debug에서 2,400점 중 마지막 4점 갱신의 **기하 계산만** 전체 재계산 16.045ms→증분 계산 0.213ms였다. 전체 입력→표시 지연이나 p95 측정값이 아니다. 사용자 기존 10획의 원본 압력으로 계산만 비교하면 인접 두께 변화 RMS는 약 79% 작고 중앙 두께는 약 1.5% 굵다. 이는 오프라인 계산 결과이며 실제 필기감 개선률로 해석하지 않는다.

초기 포인터 fixture는 수동 v2 입력의 기대값을 v3로 바꿔 실패했다. 입력 그대로 v2를 기대하도록 고친 뒤 후속 suite를 통과했다. backend 통합 검사의 첫 실행은 같은 프로세스에 공존하는 재시작 fixture의 학습 outbox 재생과 파일 이름 변경이 잠금을 경합했다. fixture가 실제 재생 완료를 기다리도록 수정한 뒤 전체 명령을 다시 통과했다. 제품 잠금을 우회하거나 실패한 실행을 통과로 합산하지 않았다.

### 사용자 자료 보존

설치 전 `/private/tmp/bandal-ink-quality10-20261014`와 설치 후 `/private/tmp/bandal-after-quality11-20261014` 모두 SQLite `quick_check=ok`다. `pdf_drawings` **37행 모든 열이 동일**하며 활성 필기 10개·사각형 1개와 삭제 상태 26행을 보존했다. `welcome.pdf`는 18,872바이트와 SHA-256 `7bc28e901ea2a82b84ba4bf84ef2169afbfbc952c489e28a7f5a9948120d6698`가 동일하다. 일반 실행 이후 확인 시점까지 새 renderer 오류는 없었다. 실제 Pencil 품질·팜 리젝션·장시간 사용 인수는 별도다.

## 2026-10-14 빌드 8의 획 미표시 조사와 빌드 10

사용자가 빌드 8에서 **“아무 획도 나타나지 않음”**이라고 확인했다. `/private/tmp/bandal-build8-stroke-failure-20261014` 백업의 실제 로그에는 15:48 KST `pen.pencil.target`은 있지만 `begin/end/checkpoint/commit`은 없다. 따라서 PDF의 Pencil hit-test는 도달했지만 UIView 입력 콜백에 들어오지 않은 실패다. 특정 PDFKit 내부 제스처를 원인으로 단정하지 않는다.

PDFView에 공개 `UIGestureRecognizer`를 붙여 첫 Pencil 접촉부터 입력을 소유하도록 수정했다. 다른 recognizer가 이 경로를 취소하지 못하며, UIView의 중복 Pencil 콜백은 무시한다. 측정점·예측점 구분, 뒤늦은 필압 보정, 원본 journal/저장/undo는 기존 단일 경로를 유지한다. 일반 입력은 Pencil만 받으며 손가락 이동·확대는 유지한다.

- `PencilDispatch10a`: iPadOS 18.3.1 시뮬레이터 **8개 통과**. 7개 단위 검사와 실제 UIKit dispatch UI 검사 1개다.
- UI 검사는 격리된 `BandalDesktop-UI-Tests`와 명시적 DEBUG 실행 인자에서만 recognizer가 XCTest 손가락을 받도록 한다. 실제 UIKit 중재를 거쳐 선·점 생성 → 원본 undo/redo → 저장 ACK → 앱 재실행 후 2객체 복원을 확인했고 첨부 화면에서도 선과 점을 확인했다.
- 이전 빌드 8의 fixture는 `window.hitTest` 뒤 UIView 메서드를 직접 호출했다. UIKit이 UIView 전달을 막는 실패를 검증하지 못한 것이므로 이전 통과를 물리 Pencil 성공으로 해석하지 않는다.
- `PencilDispatchDevice10b`: 실제 iPad UI 검사 **5개 통과**(선·점/undo/redo/저장/복원, 도구 메뉴/확대, 이미지→화이트보드, 찾기, 분할 활성화). 7개 단위 검사 중 1개는 iPadOS 26.5가 `.failed` 상태를 즉시 `.possible`로 되돌려 fixture 단정이 실패했다. 제품 코드를 바꾸지 않고 임시 상태 대신 ignored-target 진단·입력 미전달·다른 제스처 비간섭을 검사하도록 보완했다.
- `PencilDispatchDevice10c`: 보완한 단위 검사 **7개 모두 통과**. 10b에서 통과한 동일 제품 코드의 UI 검사와 합쳐 기기 검사 12개를 통과했다. 실제 기기 첨부 화면에서 선과 점의 표시도 확인했다.
- 실제 Pencil의 압력·시스템 Scribble·팜 리젝션·필기감은 여전히 미검증이다. 개발용 네이티브 PDF의 기본값/Release 제외 정책은 유지한다.
- 별도 미해결 입력 항목: 기존 hit-test는 `event.allTouches`에 Pencil이 하나라도 있으면 Pencil 경로를 선택한다. 다른 분할의 Pencil과 PDF의 손가락을 동시에 쓰는 혼합 입력은 전용 회귀와 수정이 필요하다. 이번 단일 Pencil 미표시 수정의 통과 범위에 포함하지 않는다.


기준일: **2026-10-14**. 현재 기본 앱은 반달 데스크톱의 실제 React·Dockview renderer를 실행한다. 초기 SwiftUI 시제품 UI가 아니며, 원본 화면을 가져왔다는 이유로 전체 기능이나 출시 계획이 완료됐다고 표시하지 않는다.

**빌드 10 설치 당시:** 2026-10-14 16:10 KST에 업데이트 설치하고 테스트 인자 없이 일반 실행했다. 이후 사용자는 실제 Pencil로 획이 그려지는 것을 확인했으나 두께와 필기감 문제를 보고했다. 후속 품질 수정은 위의 빌드 11 기록을 따른다. 빌드 9의 검증된 브라우저 확대·SQLite·학습 출처 복구 수정도 포함했다.

설치 전 백업 `/private/tmp/bandal-build8-stroke-failure-20261014`와 설치 후 `/private/tmp/bandal-after-build10-20261014` 모두 SQLite `quick_check=ok`다. `welcome.pdf` 18,872바이트와 SHA-256 `7bc28e901ea2a82b84ba4bf84ef2169afbfbc952c489e28a7f5a9948120d6698`, `pdf_drawings` **27행의 모든 열이 동일**하다. 활성 사각형 1개와 삭제 상태 26행을 보존했다. 실행 후 새 renderer 오류도 기록되지 않았다. 설치 후 사용자가 추가 작업하면 이 수량은 달라질 수 있다.


**이전 사용자 확인: 빌드 6 설치 후 사용자가 “지금은 상자가 안 뜸”이라고 확인했다.** PDF 자체는 열린다. 같은 오류가 나는 입력 경로를 재현해 수정하고 실기기 검사 2개를 통과했다. 실제 사용자 오류의 스택은 확보하지 못했으므로 원인까지 확정한 결과와는 구분하며, 재발 시 코드 위치를 확인할 진단 기록을 유지한다.

## 빌드 8 입력 수정 검증

PDFKit의 `isInMarkupMode` 활성화와 실제 오버레이로의 Pencil hit-test 경로를 추가했다. 네이티브 PDF/필기 표면은 Scribble을 거부하고, 앱 WebKit의 실제 `UITextInput` 하위 뷰에도 공개 `UIScribbleInteraction` 정책을 붙여 좌표를 변환한다. 원본 색·두께 메뉴 `.pdf-tool-popover`의 누락된 보호 영역을 추가하고, 메뉴 전체를 화면 모달로 처리해 PDF를 숨기던 조건도 수정했다. 명시적 텍스트 도구의 편집기만 Pencil 자동 텍스트 변환을 허용하며, 선택 모드의 기존 텍스트 키보드 편집·페이지 번호·일반 검색 입력은 유지한다.

- `PencilRouting8a`: 실제 iPad **6개 통과**. 공개 UITouch/UIEvent fixture를 window hit-test부터 실제 필기 콜백에 전달해 선·0압력 점·형광펜이 journal에 남는지, 분할 활성화/텍스트 편집 구멍/로딩 중 차단을 확인했다. 실제 WKWebView의 UITextInput 하위 뷰와 좌표 변환, native JavaScriptCore에서 노트 제목·자기 링크·재실행도 확인했다. 이 fixture는 물리 Pencil과 시스템 Scribble 인식기를 생성하지 않는다.
- 원본 WebKit 필기 회귀: 도구별 합성 Pencil 100회, 실제 포털 색/두께 메뉴, 포인터 이동 소유권, 선택 모드 키보드 편집, text 전용 Scribble 영역, SVG 변환 후 영역 재계산 통과. 실제 `useNativePDF`와 원본 스타일/주석 팝오버의 native 유지·정확한 구멍·실제 모달 전환도 통과했다.
- `PencilWorkspace8b`: 페이지 이미지→화이트보드·시스템 PDF 찾기·분할 복귀 **3개 통과**. 새 스타일 메뉴 검사는 WebKit의 popup/switch 접근성 항목을 일반 Button으로 찾는 선택자 오류로 실패했다. 선택자를 수정해 8c에서 PDF 유지·파랑 선택은 확인했지만 XCTest의 WebKit range 직접 조절 API가 실패했다. 전체 배치를 성공으로 세지 않는다.
- `PencilFinal8d`: **네이티브 2개 + UI 1개 통과**. 메뉴 구멍은 HTML에 남기고 보이는 본문 시작만 전달하며, UIKit 획/점/형광펜 저장을 재확인했다. 실제 iPad에서 색 선택 반영·터치 드래그로 두께 변경·본문 탭 후 메뉴 닫기·100%→142% 두 손가락 확대·도구 전환 후 획 0건을 확인했다. 물리 Pencil 결과와 구분한다.
- `PencilMinimumOS8`: iPadOS 18.3.1 시뮬레이터에서 실제 WebKit 하위 뷰 Scribble 정책·PDF 입력 구멍·UIKit 획 저장/재생 등 **6개 통과**. 최소 지원 OS 계열 확인이며 물리 Pencil 인수와 구분한다.
- 전체 canonical 빌드, strict TypeScript, SQLite backend의 PDF binding/공통 획/이동 보존 및 별도 Electron ABI projector 왕복 통과. 노트 복구 공통 커밋은 `2cf3ab0`, 동기화 변환기 반영은 `0a0e469`다.

새 기기 진단은 입력 종류·도구·시작/종료/거절 횟수·저장 단계와 Scribble 허용/거부 숫자만 기록한다. 문서 경로·본문·획 좌표는 기록하지 않는다. 사용자 최신 백업 `/private/tmp/bandal-before-build8-20261014`에서 27개 필기 행(새 활성 사각형 1개 포함)과 원본 PDF를 보존했다. 물리 Pencil 인수 실패는 수정본을 사용자가 재확인하기 전까지 해소로 표시하지 않는다.

## 빌드 9 후속 구현 검증 — 빌드 10에 포함해 설치

빌드 9 검증 당시에는 빌드 8의 물리 Pencil 확인을 중단하지 않도록 연결된 iPad를 그대로 두었다. 아래 변경은 코드와 시뮬레이터·격리 저장소에서 검증한 뒤 빌드 10에 포함해 설치했다. 빌드 9 자체의 PDF/Pencil 입력 코드는 빌드 8과 같았으며, 입력 전달 수정은 빌드 10 기록을 따른다.

- **브라우저 기본 확대:** 설정과 표시만 바뀌고 실제 웹페이지는 100%였던 결함을 수정했다. 새 탭의 기본값을 WebKit에 적용하고 성공 후 확정한다. 기존 탭·명시적 100%·재탐색·재마운트는 보존한다. 실패 안내/재시도와 사용자 변경 뒤 늦게 도착한 실패 응답을 검사했다. 원본 WebKit 회귀와 strict TypeScript 통과.
- **학습 경로 복구:** 파일 이동의 SQL 확정과 함께 outbox를 남긴다. 학습 JSON에 처리 ID를 저장하므로 종료 후 재시도와 ACK 실패에도 같은 변경을 다시 적용하지 않는다. 원본 변경·읽기 불가·저장 실패를 덮지 않는다. 공통 `a0bc44b`의 16 suites / 209 tests에서 SIGKILL·외부 수정·중복 재생·과목 병렬 접근·프로세스 잠금을 검증했다.
- **동기화:** 학습 저장과 자료 이동에 같은 잠금을 사용하며, 명시적으로 빌린 저장소로 동기화한다. 빈 기기로 과목과 학습 프로젝트를 함께 처음 받기, 두 과목 갱신, AI 작업 취소/충돌 보존/사용자가 고른 사본 복원, 손상 JSON 보존을 검사했다. 잘못된/중복 요청은 진행 중인 AI를 취소하기 전에 거부한다. 실제 계정 서버 통신 검증과는 구분한다.
- **실제 SQLite 연결 차이:** `LearningBrowser9a`에서는 브라우저 검사는 통과했지만 학습 목록이 `Unknown SQL parameter: readingMinutes`로 실패했다. 원본 저장소는 객체의 여러 속성을 넘기며 데스크톱 better-sqlite3는 SQL에서 쓰지 않는 속성을 무시한다. iPad 연결부를 같은 방식으로 수정하고, 필요한 이름이 없으면 쓰기 전 오류로 처리한다.
- **`LearningBrowser9b`: iPadOS 18.3.1 시뮬레이터 11개 통과.** 실제 JavaScriptCore/SQLite로 두 과목 학습 목록·단어 출처 이름 변경·재실행·처리 ID 유지, 노트 H1/자기 링크·네이티브 파일/잠금/SQL을 확인했다. 브라우저 설정 저장→실행부 재생성→실제 WKWebView.pageZoom·재탐색·기존 탭 100% 보존도 통과했다.
- 최종 canonical 빌드/패키지 검증, strict TypeScript, 원본 1,019개 파일 검증, 실제 backend `--pdf --sync --learning-paths` 및 별도 Electron ABI `--pdf --projector` 왕복 통과. 데스크톱 projector 패키지 커밋은 `79ad9e4`다.

학습 프로젝트가 손상되거나 접근할 수 없으면 경로 변경 기록을 남기고 전체 경로 재생을 보류한다. 일반 학습 접근도 오류를 표시하며 원본 복구를 기다린다. 부분 성공을 전체 완료로 처리하거나 손상된 원본을 자동 교체하지 않는다.

## 빌드 7의 입력·브라우저·설정 검증

아래는 새 구현의 검증 범위다. 개발 빌드의 자동 검사를 실제 Pencil 필기감이나 모든 외부 계정의 동등성으로 확대하지 않는다. 최종 설치·자료 대조 결과는 별도 기기 실행 기록을 따른다.

- **설정:** 원본 20개 분류·탭 6개 하위 화면과 231개 컨트롤 선언을 추출했다. 저장 값의 실제 소비 경로, 실패·취소·재실행 결과는 [설정 동작 검증표](settings-behavior-acceptance.md)에 각각 기록한다. 모든 행이 최종 인수를 통과했다는 뜻은 아니다.
- **브라우저:** iPad 전용 56pt 도구막대·44pt 조작 영역·16px 주소 입력·도메인/전체 URL 전환·정돈된 더보기 메뉴를 적용했다. 엔진이 제공한 WebKit 버전으로 Safari 식별 토큰을 구성하며 고정된 옛 UA를 사용하지 않는다. 연결된 iPad에서 Google과 학교 포털 공개 페이지를 자동·데스크톱·모바일 세 방식으로 검사했다. 학교 SSO 로그인은 별도다.
- **기본 PDF·화이트보드 입력:** 도구와 본문의 Scribble 영역을 분리하고 펜 도구 선택 후 지연된 텍스트 입력을 차단한다. 점·정지 필압·첫 압력 0을 보존하며 입력을 버퍼에 모아 프레임마다 표시한다. 실제 WebKit의 원본 InkLayer/도구 400회 합성 Pencil 선택 검사는 물리 Pencil 100회씩 검사를 대신하지 않는다.
- **개발용 PDF 비교:** 원본 React 탭·도구·주석과 저장·undo를 유지한 PDFKit/UIKit/Metal 본문을 추가했다. `설정 → 실험실`의 DEBUG 전용 비교 옵션으로 PDF를 닫고 다시 열어 전환한다. Release에서는 옵션을 표시하지 않으며 호환성·물리 Pencil 인수가 끝나기 전 기본값은 꺼짐이다.
- **공통 필기:** 새 획은 `inkVersion: 2`와 선택적 시간·기울기 정보를 저장하고 데스크톱도 같은 압력 윤곽을 표시한다. 기존 획을 일괄 변환하지 않는다. 4방향 회전·CropBox PDF 내보내기를 실제 PDF.js 래스터와 대조했으며 데스크톱 필기·저장·보드/PDF 내보내기 회귀 82개를 통과했다.
- **복구·undo:** 같은 완료 획의 journal 재생, 잃어버린 ACK, 수정/삭제 후 재생, 두 PDF 표면의 동시 재생에서 중복 생성과 중복 undo를 방지한다. 저장 실패는 완료로 보고하지 않고 복구 기록을 유지한다.
- **혼합 탭:** 실제 Dockview와 원본 저장 형식으로 PDF 5·노트 5·브라우저 4·화이트보드 3·녹음 2·보드 1의 두 그룹·순서·선택·URL을 WebKit 재시작 후 대조했다. 콘텐츠 엔진의 20탭 동시 메모리 압박 검사와는 구분한다.

아직 실제 Pencil 선택 100회씩·점 100개·팜 리젝션·작은 한글/수식·Goodnotes/Notability 체감 비교·2시간 복합 녹음은 통과 근거가 없다. Google iOS OAuth·PPT 서버 설정과 실제 사용자 키/계정이 필요한 기능은 외부 설정 대기 또는 미검증으로 유지한다.

### 새 PDF 본문의 검증 경계

PDF 본문과 필기는 PDFKit의 같은 페이지 좌표계에서 움직인다. UIKit의 실제·coalesced 입력을 저장하고 예측점은 미리보기에만 사용한다. 완료 획의 복구 기록은 파일·디렉터리 fsync 후 원본 저장소에 전달하며, 추정 필압/기울기 보정이 늦으면 완료 순서를 유지한 채 갱신한다. 원본 실행 취소와 PDF 내보내기는 이 전달을 먼저 기다린다. 따로 생성한 필기 저장소나 실행 취소 이력을 사용하지 않는다.

- `NativeIntegration7h/7i` 실기기: 본문 확대·원본 도구막대 고정·페이지 이미지 메뉴·화이트보드 전달·PDF 찾기, 배경 위 형광펜 합성, 복구 기록/보정 순서 검사를 통과했다. 7i 도형/viewport 실패는 `NativeShapeViewport7j`에서 수정 후 5개 모두 통과했다.
- `NativeShapeViewport7j` 실기기: 세로 PDF의 도형 두께·둥근 끝·4방향 회전을 실제 WK SVG 픽셀과 비교했다. 4배 확대한 PDF의 서로 다른 두 가시 영역에서 글자 선명도·필기/선택 위치를 확인했다. 큰 페이지 전체를 확대 해상도로 할당하지 않고 가시 영역을 다시 그린다.
- 실제 WebKit + 원본 편집기: 도형/텍스트 편집·재편집·확대 후 텍스트 위치, 아직 전송되지 않은 획의 Undo/Redo 및 내보내기 순서를 검증했다. 화면 입력 이벤트를 주입한 검사이며 물리 Pencil 압력 검사와 다르다.
- 미검증: 물리 Pencil 선택 100회씩·점 100개·빠른 획·작은 한글/수식·팜 리젝션·입력 수신→프레임 제출 지연 p95·Goodnotes/Notability 비교. 혼합 페이지 크기는 PDFKit의 공통 물리 배율을 사용하므로 원본 PDF.js의 페이지별 동일 폭 배치와 화면상 차이가 있을 수 있다.

## 현재 기본 구조

`App/BandalApp.swift`는 `DesktopShell`을 연다. 앱 WKWebView에 원본 `main.tsx`, AppShell, Dockview, SettingsApp을 포함하고, JavaScriptCore에서 원본 데스크톱 저장소·서비스를 실행한다. Swift가 SQLite·파일·네트워크·Keychain·AVFoundation·EventKit 등 플랫폼 API를 제공한다. 외부 브라우저 WKWebView에는 앱 IPC를 설치하지 않는다.

원본 기준은 **데스크톱 0.84.1 / a7500f4**와 [manifest](../DesktopRuntime/upstream/manifest.json)이다. 공통 필기 v3 호환성 수정까지 포함한 1,020개 파일의 해시와 바이트 수를 검증하며, 원본 CSS·로고·Pretendard·화면 구성을 사용한다. iPad 배포 버전은 별도 0.1.0이다. 지원 대상은 iPadOS 18 이상, iPad 전용이다.

원본 파일을 직접 수정하지 않고 검사되는 빌드 변환으로 Pencil·손가락 입력, Command 키, WK 파일 선택, API 키, 녹음, 계정 동기화 및 지원 불가 플랫폼 항목을 연결한다. 이전 `App/WorkspaceView.swift`, `App/PDF/`, `WebEditor/` 등에 남아 있는 초기 검증 코드는 현재 기본 UI의 구현 근거로 사용하지 않는다.

주요 진입점: [셸](../App/Desktop/DesktopShell.swift), [JavaScriptCore 실행부](../App/Desktop/DesktopRuntime.swift), [원본 backend 연결](../DesktopRuntime/backend/index.ts), [원본 기능 감사](../DesktopRuntime/docs/feature-parity-audit.md).

## 앱에서 연결된 기능

여기서 “연결”은 실제 실행·저장 코드가 있다는 뜻이다. 모든 실서비스 사이트·문서·장치에서 동등하게 작동한다는 인증은 아니다.

| 영역 | 현재 구현 | 남은 검증·제한 |
|---|---|---|
| 작업 공간 | 원본 과목·자료 탐색, Dockview 다중 탭·분할·배치, 원본 탭 종류와 자료 열기 분기 | mini부터 13형까지 터치 드래그·좁은 창·회전·외장 키보드 조합, 혼합 자료 20탭의 장시간 실기기 검증 |
| PDF·필기 | 원본 PDF.js·주석·필기 도구·공통 객체 저장·내보내기. 로컬 CMap·표준 글꼴·decoder 자산, Pencil 압력·coalesced 이벤트 어댑터. 실기기에서 기존 한글 PDF·7획 표시와 두 손가락 확대 검증. 빌드 6에서 사용자가 오류 배너 미발생 확인 | 실제 Pencil 필압·지연·팜 리젝션·긴 필기 세션. 합성 압력 이벤트나 손가락 UI 테스트가 물리 Pencil 검증을 대신하지 않음. 배너 재발 시 실제 오류 프레임으로 추가 조사 |
| 노트·화이트보드 | 원본 Markdown/Milkdown·수식·표·화이트보드 편집 화면과 저장소. 노트·잉크 저장 큐를 함께 기다리는 lifecycle barrier | 복잡한 실제 문서 및 종료·동기화·메모리 압박을 조합한 장시간 사용 |
| 브라우저 | 원본 toolbar 위에 별도 WK 페이지, 프로필·일반/비공개 쿠키·팝업·업로드·다운로드·검색·권한·캐시 관리 | 학교 SSO·POST 팝업·DRM/영상·실제 업로드 사이트 호환성. 다운로드 목록·중단 상태·재개 데이터는 재실행 후 복원. 서버가 재개를 거부하면 명시적 재다운로드 필요 |
| 브라우저 메모리 | 비활성 읽기 전용 페이지를 WebKit interactionState와 같은 data store를 유지한 채 해제·복원. history·스크롤 보존, 폼·미디어·iframe·팝업 등은 보호 | 보호할 탭이 많으면 메모리 사용이 계속 높을 수 있음. iPadOS가 웹 프로세스를 강제 종료한 경우 미저장 외부 폼 보존은 보장하지 않음 |
| 브라우저 AI 도구 | 원본 승인·권한·감사·참조 세대 검사와 WK 읽기·탐색·클릭·입력·승인된 제출·파일 첨부·handoff. Canvas 읽기 recipe | 교차 출처 iframe 조작과 신뢰된 OS 입력을 요구하는 사이트는 제한. semantic key는 하드웨어 키 입력이 아님. 실제 LMS 계정 검증 필요 |
| AI·학습 | 원본 세션 관리자·승인·도구·사용량·퀴즈·카드·복습·읽기·단어장·학습 팩. OpenAI·Claude·Gemini 네이티브 API 연결과 취소 | 실제 사용자 키·과금·모델별 인용 및 도구 실행. fixture 성공을 외부 제공자 응답 성공으로 보지 않음 |
| 자료 뷰어 | 원본 PDF·이미지·영상·Office·HWP 뷰어와 미리보기 parser worker, 실제 영상 PiP 연결 | 복잡한 Office 서식·글꼴·HWP 원본 수준의 미리보기·보호 영상 검증. 구형 `.ppt`는 별도 서버 필요 |
| 보드·달력·알림 | 원본 보드·기한·위젯, EventKit 읽기·내보내기, 로컬 기한/완료 알림과 설정별 차단 | 실제 캘린더 계정·권한·시간 변경·백그라운드. 가까운 알림 최대 60개 예약 |
| 녹음·전사 | 원본 녹음 화면/저장소 + AVAudioEngine mono 16kHz PCM16 WAV. 일시정지·재개·복구·재생·자료 앵커, 로컬 Zipformer/SenseVoice와 재전사 | 실기기 2시간 복합 녹음·잠금·오디오 중단·발열·배터리·두 모델 추론 측정. 클라우드 전사는 기본 경로가 아님 |
| 메일 | 원본 메일 위젯·모델에 Gmail OAuth/REST·Keychain 연결 | Google iOS OAuth 설정이 아직 없어 실제 로그인·사서함 검증 전 |
| 캡처·도우미 | 원본 전체/영역 선택 UI로 현재 앱 화면을 캡처하고 같은 원본 AI 대화에 첨부 | 다른 앱 화면 캡처나 macOS 접근성 자동화가 아님. 보호 영상·실기기 검증 필요 |
| 외부 도구 | 원본 Market 카탈로그·검증된 아카이브 설치, HTTPS Streamable HTTP MCP 연결과 매 실행 승인 | 실제 원격 서버 시험 필요. 로컬 CLI·stdio MCP·실행 플러그인·Chromium 확장은 실행하지 않음 |

브라우저 추적 방지 규칙은 WK content rule list에 연결했다. DNT는 `navigator` 신호와 네이티브에서 시작한 최상위 요청 등에 적용하며, 모든 하위 리소스 요청 헤더에 적용된다고 표시하지 않는다. 외부 WK가 포커스를 가진 경우에도 원본 키맵·사용자 재지정·사이트 우선권을 확인해 앱 단축키만 전달한다. 일반 텍스트 입력과 표준 복사·붙여넣기·실행 취소 키를 가로채지 않는다.

## 원본 20개 설정 화면

AI, 도우미, 계정, 일반, 학교, 학습 팩, 캘린더, 브라우저, 화면, 탭, 위젯, 알림, 단축키, 사용량, 권한, 개인정보, 고급, 실험실, 과목, 정보의 **원본 20개 경로**를 유지한다. 실제 화면 진입 XCUITest를 통과했으며, 각 행의 연결과 제한은 [기능별 감사 표](../DesktopRuntime/docs/feature-parity-audit.md#설정-20개-경로)에 기록한다.

화면이 열린다는 사실을 해당 설정의 외부 효과까지 검증한 것으로 세지 않는다. iPad에서 실행할 수 없는 Chromium 확장·로컬 CLI·stdio·다른 앱 조작·Electron 업데이트는 설명 또는 실제 오류를 제공한다. 아직 등록되지 않은 플러그인 개발/실행 9개 채널도 [채널 감사](../DesktopRuntime/backend/channel-coverage.json)에 남아 있다. 설치 메타데이터나 설정 저장을 코드 실행 성공으로 취급하지 않는다.

## 저장·양방향 동기화

원본 데스크톱 테이블과 과목 파일이 편집의 기준이다. [동기화 투영](../DesktopRuntime/backend/sync/index.ts)이 자료·노트·필기·화이트보드·과제·녹음·학습 기록을 공통 계약으로 연결하고, [네이티브 동기화](../App/Desktop/DesktopSyncService.swift)가 `CommonSync` SQLite 전송 대기열과 불변 자산을 사용한다. 바뀌는 녹음 스트림은 공유하지 않고, 안정된 녹음 원본과 기록을 전송한다.

- 원본 노트·잉크 저장이 완료되고 변경 번호가 안정된 뒤 동기화한다. 충돌·저장 실패·계속되는 편집은 완료로 보고하지 않는다.
- 자산 해시와 크기를 확인하고 파일을 먼저 준비한 뒤 레코드를 반영한다. 가져오기 저널을 복구하기 전에 새 export 기준선을 덮어쓰지 않는다.
- 계정 변경·취소 후 늦게 도착한 작업이 다른 계정에 적용되지 않도록 검사한다. 로컬 저장소의 계정 바인딩을 유지한다.
- 서로 다른 새 획은 합치고, 동일 객체나 병합 불가능한 변경은 충돌 사본으로 보존한다. 원본 계정 화면에서 상태·충돌 사본 내보내기·선택을 제공한다.
- API 키·세션·브라우저 쿠키·기기별 배치는 콘텐츠 동기화 대상에서 제외한다.
- 공통 payload 4MiB, 현재 서버 Storage 자산 512MiB 한도가 있다. 일반 Files 가져오기에는 채팅 첨부의 64MB 한도를 적용하지 않으며 256KiB 조각으로 임시 파일을 만든다. 가져오기 성공 확인 전 원본/미완료 파일을 성공 처리하지 않는다.

자료 저장소의 파일·폴더 이동은 SQLite에 복구 의도를 먼저 FULL 동기화한 뒤 실행한다. 데스크톱 앱·동기화 변환기·기존 Python 도구가 같은 이동 잠금을 사용하고, 완료되지 않은 경로는 내보내거나 새 PDF에 연결하지 않는다. 같은 파일이면 재시작 후 새 경로로 SQL 필기·별칭을 함께 완료한다. 원래 경로에 새 파일이 생기거나 이동한 PDF가 교체되면 파일·필기·복구 의도를 보존하고 접근을 차단한다. 실제 프로세스 강제 종료, 폴더 안 노트 링크 재작성, PDF 교체, 같은 inode의 컨테이너 경로 변경을 포함한 공통 저장소 회귀 82개를 통과했다.

노트 이름·H1·자기 링크와 backlink 본문도 이제 이동 전 의도에 원본/수정본으로 남긴다. 파일 이름 변경과 원자적 Markdown 쓰기 뒤 앱이 종료되어도 이미 수정된 본문을 확인해 새 경로로 완료하며, 외부에서 달라진 본문은 덮지 않는다. 관련 7개 suite 141개 검사를 통과했고, iPad의 실제 JavaScriptCore·파일 저장소에서도 제목/자기 링크·재실행을 확인했다. 별도 learning JSON의 경로 갱신은 빌드 9에서 durable outbox와 공유 파일 잠금으로 연결했고, 위 회귀 검증을 통과했다. 이 후속 수정은 빌드 10에 포함해 연결된 iPad에 적용했다. 원본 PDF 해시 근거가 없던 오래된 자료는 최초 관찰 기준이라는 상태를 남기며, 과거 어느 시점에 이미 교체된 PDF인지 추측하지 않는다.

실제 Supabase 계정으로 데스크톱과 iPad가 동시에 편집하고, 오프라인 변경·대용량 파일·재로그인·앱 강제 종료를 거치는 종단 검증은 남아 있다. 기존 [데스크톱 연결 도구](../Tools/desktop-bridge/README.md)와 `.bandalpack` 코드는 별도 호환 경로이며, 이전 SwiftUI 패키지 가져오기 화면을 현재 기본 UI 기능으로 표시하지 않는다.

## 기존 iPad 데이터 이행 감사

[legacy 이행 코드](../DesktopRuntime/backend/legacy.ts)는 `Documents/Bandal`을 읽고 새 `Documents/BandalDesktop` 저장소에 복사한다. 파일 해시·PDF CropBox/회전·객체 형식을 확인하며, 원본 자료와 필기 payload를 복구 보관본 및 archive 테이블에 남긴다. 새 테이블 반영과 이행 영수증은 한 SQLite 트랜잭션으로 커밋한다. 원본 DB·자료를 삭제하지 않는다.

2026-10-14 실제 설치 전 백업은 읽기 전용으로 취급했고, 별도 임시 복사본에서 최신 backend 이행을 실행했다. 이 시점의 백업은 레코드 7개, PDF·노트 각 1개, 현재 필기 **7획**, 삭제된 객체 ID **11개**였다. 이전의 9획 확인 기록과 다른 시점이므로 9획이 현 백업에 있다고 가정하지 않는다.

확인한 내용은 다음과 같다.

- PDF SHA-256과 노트 내용, 필기 ID·좌표·압력·스타일 및 원본 네이티브 필기 캐시가 보존됐다.
- 삭제된 획을 부활시키지 않았고, 기하 정보 불일치 주입 시 부분 필기 행이나 완료 영수증을 남기지 않았다.
- 정상 재시도 이후 노트 수정·획 삭제를 한 상태로 새 runtime을 시작해도 이행이 중복되거나 편집이 덮이지 않았다.
- 백업 원본 5개 파일은 검사 전후 SHA-256이 동일했다. 사용자 제목·노트 내용·획 좌표는 로그에 출력하지 않았다.

[후속 화면 상태 이행](../DesktopRuntime/backend/legacy-view-state.ts)은 이전 `workspace:ipad`와 `reading-position` archive를 원본 `tabs_layout`·`pdf_view_state`·`lastActiveCourseId`에 연결한다. 별도 멱등 이행 영수증을 사용하며, 원본 UI에서 이미 저장한 배치·읽기 위치·선택 과목은 덮어쓰지 않는다. 탭 순서·좌우 분할·포커스를 복원하고, PDF는 파일 revision과 페이지 기하 정보를 확인해 페이지를 복원한다. 이전 PDFKit UserDefaults의 세부 스크롤 좌표와 배율은 이번 범위에 포함하지 않는다.

삭제되거나 비공개인 탭, 없는 자료, 문서 revision 불일치, 지원되지 않는 상태는 archive와 제외 이유를 보존한다. 녹음·학습 탭은 해당 과목의 개요로 연결하며 저장되지 않았던 세부 선택을 만들어 넣지 않는다. 원본 저장소 API·`validateLayout`·실제 WebKit Dockview fixture로 복원, 기존 값 보존, DB rollback, 설정 파일 실패 후 재개 및 반복 실행을 검증했다. 빌드 4의 기존 사용자 자료 열기 검사와 아래 fixture별 세부 복원 검증은 서로 구분해 기록한다.

## 최근 검증 기록

아래는 배치 또는 명명된 suite별 근거다. 반복 실행한 테스트를 합산한 전체 통과 수는 제시하지 않는다. 혼합 배치의 일부 실패를 전체 성공으로 표기하지 않는다. 결과 번들과 로그는 개발 환경 산출물이며 저장소에 포함하지 않는다.

| 배치·근거 | 확인한 결과 |
|---|---|
| 최종 canonical·플랫폼 검사 | 1,018개 원본 해시를 데스크톱 checkout과 대조, 전체 번들·410개 backend 모듈·패키지 자산 검사와 strict TypeScript, 원본 renderer의 키보드/파일/lifecycle/진단 회귀 통과. 설정 inventory는 20경로·6하위 화면·231컨트롤, 미해결 컴포넌트 0개 |
| 실기기 `FinalIntegration7n`의 통과 suite | **14개 native 통과:** 실제 JavaScriptCore/SQLite 저장소 7·동기화 복구 5·native PDF host 2. 브라우저 UI 1과 기존 native PDF UI 3도 통과. 신규 분할 검사의 접근성 이름 선택 실패는 아래 7o에서 수정 확인 |
| 실기기 `FinalLibrarySplit7o` | **2개 통과:** 기존 사용자 welcome.pdf의 한글·필기 레이어·지연 오류 배너 없음, 실제 원본 페이지 노트 생성→분할→노트 활성→PDF 본문 첫 접촉으로 active=0→1 전환. 사용자 자료는 초기화하지 않음 |
| 최종 backend·데스크톱 변환기 | 실제 SQLite/파일로 PDF 교체·잘못된 note 봉투 거부·안정적 ID·미완료 이동/lock 보호, v2 필기·동기화·legacy 이행·설정 소비/실패 회귀 통과. Electron ABI 변환기의 기존 outbox/cursor/receipt 보존과 note roundtrip/conflict도 별도 fixture에서 통과. 의도적으로 충돌을 남기는 PDF 보호 시험과 결합했을 때의 실패를 production 결함으로 처리하지 않음 |
| Python 호환 도구 | **17개 통과:** PDF 원본 교체 거부·v2/회전 왕복·이름 바꾼 안정적 ID, live/미완료 자료 이동 중 legacy import/export 거부와 원본 보존 |
| 실기기 `NativeShapeViewport7j` | **5개 통과:** 4배 확대된 PDF의 가시 영역 재렌더링·필기 합성·선택 위치, 원본 WK SVG와 네 방향 회전 도형 픽셀 비교. 7i에서 확인된 도형 선 끝/fixture 좌표 문제 수정 후 재검증 |
| 실기기 `DownloadRecovery7m` | **4개 통과:** 실제 HTTP 전송 중단→원본 탭 제거→저장 기록 복원→재시도 후 16KB 전체 파일 검증, 자동 저장과 재시도 경합 시 자료 1개 유지, 컨테이너 경로 변경·목록 제거 시 파일 보존, 중단 목록의 무단 재전송 없음. 7l의 서버 fixture 시간 초과를 재현 가능한 전송 실패 시나리오로 교체 후 확인 |
| 실기기 `DownloadPathLock7l`의 저장소 suite | **2개 통과:** 네이티브 stat/fstat의 정확한 파일 ID와 교체 구분, 다른 runtime과 이동 복구 잠금 경합·소유자 종료 후 해제. 이 배치의 다운로드 실패는 위 7m에서 재검증 |
| canonical 빌드·원본 검사 | 원본 1,013개 파일/20개 설정 경로, renderer·backend·폰트·worker·기사 추출·브라우저 도구 자산 무결성 검사. 타입검사는 원본과 플랫폼 변환 후 코드를 구분 |
| 실기기 `Device-Storage-Fixed` | **10개 통과:** `DesktopRuntimeTests` 6개와 `DesktopMaterialFileTests` 4개. iPadOS의 `/var`·`/private/var` 별칭, 존재하지 않는 파일의 실제 상위 경로, symlink 이탈·저장소 루트 삭제 거부, 실제 저장소 파일 작업 검증 |
| Core `FileDigestCache` | **3개 통과:** 변경 없는 파일의 해시 재사용, 같은 크기·수정 시각 복원/파일 교체 시 재계산, 캐시 hit에도 열린 파일 권한 확인 |
| `Desktop-Final-Recovery` | **8개 통과:** `DesktopBrowserMemoryTests` 1, `DesktopSyncTests` 4, `DesktopTemporaryFileTests` 3. 이전 스크롤 복원 및 임시 파일 회귀를 수정한 최종 재검증 |
| `Desktop-Recovery-Staging`의 개별 suite | `DesktopFileStagingTests` 6개와 `DesktopRecordingTests` 5개 통과. 녹음 시작/저장 실패 주입, PCM·전사 보존, 복구 실패 노출 포함. 이 배치 전체는 임시 파일 테스트 실패로 성공이 아니며, 해당 실패는 위 최종 배치에서 재검증 |
| `Desktop-0841-Native-3`의 개별 suite | UIKit 브라우저 단축키 3개, 다운로드 전송 2개, 카탈로그 4개 통과. 동시 실행한 메모리 회귀는 당시 실패했고 `Desktop-Final-Recovery`에서 수정 확인 |
| `Desktop-0841-UI-Memory`의 UI suite | 원본 설정 20경로 순회 1개와 workspace 1개 통과. 당시 메모리 unit 실패가 있어 배치 전체 통과로 세지 않음 |
| 시뮬레이터 `Desktop-PDF-Pinch-5` | XCUITest 두 손가락 PDF 확대 1개 통과. 원본 toolbar는 고정된 채 PDF 배율 100%→117% 및 페이지 폭 증가 확인. 물리 iPad 성공 근거가 아님 |
| 시뮬레이터 `Desktop-Memory-Pinch-1`의 명명된 UI 사례 | XCUITest 화이트보드 두 손가락 확대와 손가락 이동 통과, 불필요한 잉크 없음. 이 배치의 초기 PDF UI 실패는 위 시뮬레이터 PDF 전용 배치에서 수정 확인 |
| 실기기 `Device-Final-PDF-Gesture` | **1개 통과:** 초기 물리 핀치는 100%→108%에서 멈췄다. PDF DOM 교체 뒤 터치가 분리된 원래 요소에만 전달되는 원인을 로그로 확인하고, 안정적인 wheel 대상과 터치 종료까지 유지하는 listener를 적용했다. 수정 후 실제 두 손가락 입력으로 100%→266%와 페이지 폭 증가, toolbar 고정을 확인했다. WebKit 회귀는 detached move/end·다음 제스처·listener 정리를 별도로 검증 |
| PDF.js 로컬 자산 회귀 | 기존 한글 PDF의 `Adobe-Korea1-UCS2` CMap 누락을 재현했다. 원본 4개 PDF 소비자에 로컬 CMap·표준 글꼴·WASM 경로를 연결하고, 자산·라이선스 **193개**의 패키징/해시 검사를 추가했다. 동일 CSP의 WebKit에서 실제 PDF 한글 추출 0→74자와 글자 픽셀 표시를 확인했다. FontFace 비활성화나 CSP 완화 없이 해결 |
| 실기기 `Device-Build4-Korean-PDF` | **2개 통과:** `InstalledLibraryTests`는 사용자 자료를 초기화하지 않고 기존 `welcome.pdf`의 한글 제목·필기 레이어 존재·검사 시점의 오류 배너 없음을 확인했다. 당시 선택자가 기존 탭을 누를 수 있어 자료 목록에서 닫힌 PDF를 새로 여는 동작의 근거는 아니다. `PencilInputTests`는 한글 fixture와 실제 두 손가락 확대 100%→266%, toolbar 고정을 확인했다. 기존 획 표시는 캡처 화면에서 검토했으며, 7획 보존의 수량·내용 근거는 아래 DB 백업 대조다. 물리 Pencil 직접 입력 검증은 아님 |
| 빌드 5 진단·실기기 후속 검사 | 네이티브 진단 검사 통과. 오류 종류·로컬 번들 프레임만 기록하며 문서 내용·원문 오류 메시지·사용자 경로는 진단 로그에 넣지 않는다. PDF 도구·스타일·손가락 이동 검사는 선택자를 수정한 뒤 통과했다. 기존 사용자 PDF 검사도 통과했으나 닫기 버튼이 해당 실행에 없어 물리 기기의 닫기→자료 목록 재열기를 검증한 것으로 세지 않는다. 사용자 오류 해결은 미확인 |
| 오류 후속 백업의 격리 WebKit 재현 | 실제 DB·설정·PDF를 임시 복사본에서 실행하고 네트워크를 차단했다. 복원→탭 닫기→자료 목록 PDF 열기→22초 대기→필기 도구·스타일→미리보기→재열기에서는 전역 오류가 없었다. 실기기 오류를 재현하거나 배제한 결과는 아니며, 원본 백업은 변경하지 않았다 |
| 잘못된 키 이벤트 회귀 | 원본 keymap·PDF 도구에 키 이름이 없는 `keydown`을 주입하면 `t.trim`과 `key.toLowerCase` TypeError가 발생했다. iPad 캡처 단계에서 비문자열 키 이벤트만 격리하면 오류가 사라진다. 정상 trusted 키·펜 단축키·실행 취소/다시 실행·텍스트 입력·IME·브라우저 기본 동작과 무관한 오류 표시는 유지했다. 실제 백업의 격리 renderer에서도 같은 오류 주입→차단과 정상 `p` 도구 전환을 검증했다. 사용자 실기기가 같은 이벤트를 만들었다는 증거는 아직 아님 |
| 실기기 `Device-Build6-Keyboard-Compatibility` | **2개 통과:** 자료 파일 트리 안으로 선택자를 제한해 기존 `welcome.pdf` 자료 행을 눌러 한글·필기 레이어·지연된 배너 없음을 확인했다. 별도 PDF fixture에서 펜·색상·손가락 이동 후 배너 없음과 불필요한 획 없음도 확인했다. 이 실행의 탭 닫기 버튼은 없어 닫힌 자료의 재열기 검증으로 확대 해석하지 않는다 |
| 빌드 6 설치 후 백업 | `quick_check=ok`, 원본 PDF 18,872바이트·SHA-256 및 필기 7행의 모든 열이 오류 보고 직후 빌드 4 백업과 동일했다. 03:38 KST 일반 실행 이후 확인 시점까지 새 오류 프레임이나 잘못된 키 이벤트 기록은 없었다. 사용자 증상 해소 확인과 구분 |
| 실제 legacy 백업 복사본 | 위 7획/11삭제 ID, 파일·archive 보존, 실패 후 재시도와 반복 실행 안전성 통과. 실제 사용자 원본은 변경하지 않음 |
| 빌드 4 설치 후 백업 | SQLite `quick_check=ok`. `pdf_drawings` **7개 행의 모든 열**이 검증된 빌드 3 백업과 동일하며, `welcome.pdf` **18,872바이트**와 SHA-256 `7bc28e901ea2a82b84ba4bf84ef2169afbfbc952c489e28a7f5a9948120d6698`도 동일했다. 새 컨테이너 경로 보정, 위치 이행 영수증 6개, 배치 1개·PDF 읽기 위치 1개 확인 |
| 후속 legacy view-state fixture | 원본 저장소 API·WebKit Dockview로 탭·분할·포커스·PDF 페이지 복원, 기존 값 보존, 실패 후 재개·멱등성 검증. 사용자 백업은 이 테스트의 수정 대상이 아님 |
| 기타 원본/네이티브 fixture | 실제 SQLite/파일 기반 backend·AI/학습, WK 브라우저/기사/캡처/PiP/미리보기, Keychain, MCP·메일 HTTP 경계, 알림 등. 기능별 근거와 제약은 [감사 문서](../DesktopRuntime/docs/feature-parity-audit.md)에 기록 |

**빌드 2는 2026-10-14 02:20 KST에 실기기에 설치됐으나, 사용자가 시작 화면과 빨간 오류 배너를 보고했다.** 설치 후 백업에서 이전/새 SQLite의 `quick_check=ok`, 이행한 PDF 바이트 동일, 새 `pdf_drawings` 7개·archive 7개·이행 영수증 1개를 확인했다. 이는 설치와 자료 보존의 근거이며 정상 사용 완료를 뜻하지 않는다.

파일 경로 별칭과 업데이트 때 바뀌는 iPadOS 컨테이너 주소의 저장 경로를 보정하고, 후속 탭·읽기 위치 이행을 연결했다. 빌드 3 백업에서는 기존 **7획과 PDF 바이트 불변**을 확인했다. 이후 PDF가 열려도 한글이 빠지던 CMap 문제를 발견해 로컬 자산 연결을 추가했다.

**빌드 4는 2026-10-14 03:11 KST 일반 실행과 자동 검사를 통과했지만, 03:17 KST 사용자 사용에서는 빨간 오류 배너가 다시 보고됐다.** 사용자는 PDF가 열린다고 확인했으며 전달된 문구는 `undefined is not an object (evaluating 't.rim')`이다. `t.trim`의 전사인지와 발생 함수는 아직 확정하지 않았다. 초기 검사에서 오류가 보이지 않았다는 사실로 사용자 문제를 해결됐다고 판단하지 않는다. 설치 후 PDF 바이트·7개 필기 행이 보존됐다는 별도 백업 결과는 유지된다.

**진단용 빌드 5를 설치하고 03:29 KST에 일반 실행했다.** 오류 종류·로컬 번들 프레임 기록과 네이티브 검사를 추가했다. 원문 메시지, 문서 내용, 사용자 경로는 진단 로그에 저장하지 않는다.

**빌드 6을 설치하고 03:38 KST에 일반 실행했다.** 원본 단축키 코드에서 동일한 `t.trim` 오류를 만드는 잘못된 키 이벤트 경로를 재현하고 입력 어댑터를 추가했다. 비문자열 `key`만 격리하며 `preventDefault`로 기본 편집을 취소하지 않는다. 정상 키·조합·입력 이벤트는 그대로 전달한다. 해당 이벤트가 기기에서 실제로 발생하면 세션당 한 번 `renderer.input code=keyboard.missing-key`만 기록한다. 실기기 자동 검사와 자료 보존 검증은 통과했고, 사용자가 이후 “지금은 상자가 안 뜸”이라고 확인했다. 사용자 오류의 실제 프레임이 없어 입력 경로와의 인과관계는 확정하지 않았다. 물리 Pencil 품질·장시간 녹음·실제 계정 연동은 출시 조건으로 남아 있다.

## 출시 전 남은 조건

1. PDF 오류 배너는 빌드 6에서 사용자 미발생 확인을 받았다. 장시간 혼합 사용에서도 재발하지 않는지 확인하며, 재발 시 추가된 진단의 실제 오류 프레임을 기준으로 조사한다.
2. 실제 iPad에서 새 기본 UI의 Pencil 압력·팜 리젝션·빠른 획·확대 중 입력·종료 직전 저장을 확인한다. mini/Air/Pro와 세로·가로·좁은 창·키보드·VoiceOver·글자 크기를 검증한다.
3. PDF 필기·브라우저·노트·녹음의 혼합 사용, 20개 혼합 탭, iPadOS 메모리 종료·복귀를 검증한다. 안전하게 해제한 읽기 전용 웹 탭 20개의 fixture와 구분한다.
4. 2시간 실제 녹음에서 원음 누락·발열·배터리·잠금·오디오 경로 변경을 측정하고, Zipformer와 SenseVoice의 실제 기기 추론을 확인한다.
5. 테스트 계정으로 OAuth·Gmail·학교 SSO/LMS·AI 제공자·캘린더·MCP와 양방향 자동 동기화를 검증한다. Google iOS OAuth 설정과 인증된 `.ppt` 변환 서버는 준비·배포가 필요하다.
6. 아직 연결되지 않은 플러그인 개발/실행 경계와 대형 필기/자산 한도를 정리하고, 다양한 기존 자료·배치와 반복 업데이트의 이행 회귀를 검증한다. Chromium 확장·셸·로컬 CLI/stdio·다른 앱 자동화는 iPad v1 제외 범위와 구분한다.
7. 데이터 이행·내보내기·기존 설치 업데이트 검증 후 TestFlight, 접근성·개인정보·라이선스·App Store 절차를 진행한다.

빌드와 테스트 명령은 [README](../README.md), 서버 조건은 [backend 안내](../backend/README.md), 공개 API 연결의 범위는 [기능 감사](../DesktopRuntime/docs/feature-parity-audit.md)를 따른다.
