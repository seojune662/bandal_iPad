# 필기 품질 조사와 버전별 구현

## 2026-10-16 사용자 확인 — v5 필압·끝 모양과 필기·지우개 속도

사용자는 새 작은 글씨와 약한→강한 필압의 긴 선, 연속 필기·지우개 반응을 묻는 질문에 **“자연스러워졌고 필기·지우개도 빠름”**이라고 답했다. 해당 실사용에서 v5 필압·끝 모양의 개선과 필기·지우개 속도 유지를 확인한 결과로 기록한다.

질문에는 빌드32라고 적혀 있었고, 이 채팅의 마지막 설치는 같은 v5 필압·끝처리를 사용하는 빌드33이다. 응답만으로 사용자가 시험한 정확한 빌드나 시각을 확정하지 않는다. 스크롤·확대, 모든 문서·장시간 조건, 경쟁 앱과의 품질 동등성까지 확인한 것으로 확대하지 않는다. 아래의 v5 사용자 확인 대기 상태를 이 결과로 갱신한다. 이번 반영은 문서만 수정하며 제품 코드·설치물·사용자 자료와 봉인된 빌드33 아카이브는 변경하지 않는다.

## 2026-10-16 빌드 33 — v5 필압·끝 모양과 혼합 페이지 예산 복구

**현재 상태:** 빌드33의 관련 Simulator native 275개 중 274 pass·1 skip·0 fail(70.600초), 13인치 실제 앱 UI 2개 모두 pass(79.827초)다. 실제 iPad33 검사도 275/275 pass·skip0·fail0(78.065초)로 끝났으며, 자료 보존 비교 후 2026-10-16 01:12:29 KST에 테스트 인자 없이 일반 실행했다(PID12196, args=[]). 빌드31에서 사용자가 확인한 “즉시 지워지고 다시 나타나지 않음”은 기존 지우개 경로의 인수 결과이며, 새 v5 필압·끝 모양의 물리 Pencil 인수까지 대신하지 않는다.

### 새 획의 v5 계약

새 펜 획은 `inkVersion: 5`로 생성한다. 기존 v2/v3/v4 저장 획은 각 버전의 기하를 유지하며 자동 변환하거나 원본을 다시 쓰지 않는다. 원본 위치·필압·시간·기울기·순서 및 journal 계약은 유지한다. v5 형광펜은 필압·속도·taper를 적용하지 않고 **동일 입력의 v4 polygon과 정확히 같은 결과**를 사용한다.

- **필압:** 최신 원본 4점까지만 사용하는 인과적 필터다. 현재부터 역순으로 `exp(-age / 8ms)`를 가중하고 누적 age가 24ms를 넘으면 제외한다. 양수 유한 시간 차는 최대 32ms, 없거나 반복·역행하는 시간 차는 4ms로 계산하며 압력은 0…1로 제한한다. 렌더 폭 계산 때문에 원본 샘플을 삭제하거나 변경하지 않는다.
- **속도와 기본 폭:** 페이지 너비 단위의 물리 거리 `(x, y × aspect)`와 timestamp로 속도를 구한다. 유효한 `0 < dt ≤ 64ms`에서만 계산하고 그 밖은 중립 속도 0, 계산 결과는 0…3 page-width/s로 제한한다. 도구 폭 대비 지름 비율은 `(0.24 + 0.68 × pressure^0.8) × (1 − 0.12 × clamp(speed / 0.8, 0, 1))`이다. 빠른 입력의 폭 감소는 최대 12%이며, timestamp가 없는 입력을 빠른 필기로 간주하지 않는다.
- **시작과 끝:** 시작 gain은 이동 거리 `1.2 × 도구 폭` 동안 0.75에서 1로 smoothstep 보간한다. 한 점도 0이 아닌 점으로 표시한다. 끝 taper 길이는 `min(2.2 × 폭, 전체 이동 거리 × 0.28, 마지막 16개 이동 구간의 거리)`이며, 짧은 획에서는 `smoothstep(taperLength / (0.75 × 폭))`로 강도를 줄인다. 끝 gain은 최대 강도에서 0.32이고, 이동 거리가 0이면 끝 gain은 1이다. 끝은 현재 측정점마다 같은 규칙으로 계산하며 lift 후에만 다른 모양을 적용하는 분기는 없다.
- **희소 입력과 정지:** 두 점으로 된 긴 선 전체가 가늘어지는 것을 막기 위해 시작·끝 창에 각각 최대 8개 보조 knot를 넣는다. 위치는 v4가 이미 채택한 polyline의 현 위에서 보간하며 긴 본문 전체를 촘촘히 다시 나누지 않는다. 연속으로 x/y가 정확히 같은 펜 샘플은 렌더 전용 anchor 하나로 묶고 최신 원본의 필터링 압력과 첫 도착의 속도를 쓴다. 따라서 일정 압력의 정지 샘플 33개가 추가돼도 이동 tail을 소모하거나 끝이 다시 두꺼워지지 않는다. 실제 압력 변화는 계속 표시된다. **저장 샘플은 모두 보존하지만, 이 anchor 선택 때문에 중복점 주변의 펜 중심선이 v4 원본 배열과 언제나 동일하다는 주장은 하지 않는다.** 같은 render anchor에 대한 v4 제어점·기존 분할은 그대로 사용한다.
- **증분·예측·저장:** 일반 append는 마지막 16개 이동 구간과 중심선 의존 구간, 새 구간만 다시 만든다. 기존 raw-prefix 동일성 비교는 O(N)으로 남고, 오래된 pressure correction은 보수적으로 변경 지점 이후를 재생할 수 있다. 모든 입력 연산이 O(1)이라고 표현하지 않는다. 예측은 최대 8점의 별도 꼬리이며 마지막 실제 렌더 폭을 유지하고 측정 기하에 관여하지 않는다. 같은 측정점의 live·완료·웹·내보내기는 동일한 순수 기하 계약을 사용한다. 완료 GPU mesh는 기존 유지 경로를 쓰며 새 획 때문에 이미 저장된 전체 획을 다시 래스터화하지 않는다.

구현: [Swift v5](../App/Desktop/PDF/NativePDFInkGeometryV5.swift), [증분 캐시](../App/Desktop/PDF/NativePDFInkGeometryV5Cache.swift), [TypeScript v5](../DesktopRuntime/upstream/src/shared/inkV5.ts), [공통 fixture](fixtures/ink-v5-quality.json), [품질 검사](../Scripts/test-ink-v5-quality.mjs), [native 회귀](../Tests/BandalTests/NativePDFInkV5Tests.swift). 실제 Swift/TypeScript 35개 fixture·182,905개 수치 비교의 최대 차이는 2.22e-16이었다. 447개 live prefix, 긴 두 점 직선의 본문 폭, 반복 시간·정지 압력·긴 정지 꼬리·고정 형광펜·중간 보정·live/완료 동일성을 검사했다. 이 수치는 합성 기하 정합이며 경쟁 앱의 가독성·필기감과 동등하다는 증거가 아니다.

2,400점 획에 4점을 추가하는 회귀는 원본 폭 4개·taper factor/구간 21개와 231,930개 중 2,784개 정점을 다시 만들었다. 빌드32 실기기 표본은 증분 기하+mesh 0.819ms, 전체 기하 31.145ms였고, 빌드33 Simulator 표본은 0.635ms/22.958ms였다. 각각 한 합성 검사 안의 CPU 구간이며 입력 전달·GPU 실행·화면 표시를 포함한 Pencil 지연이나 프레임 전체 성능이 아니다.

### 빌드32에서 드러난 13인치 혼합 undo 문제와 빌드33 수정

빌드32의 넓은 UI 검사 8개 중 6개는 통과하고 2개는 실패했다. 첫 실패는 56px 상시 아이콘 rail의 설정 버튼을 280px 본문 패널과 혼동한 세로 회전 검사였다. 제품을 숨기지 않고 `내 공간 열기/닫기` 등 패널 자체의 접근성 상태를 검사하도록 테스트 계약을 고쳤다. 두 번째는 실제 제품 경계였다. mixed 페이지에서 undo로 행은 206개까지 복구됐지만 GPU 유지 상태가 꺼지고 accepted texture는 2개에 머물렀다. 과거 통과한 11인치 결과로 이 실패를 덮지 않는다.

13인치의 물리 밀도 약 4.258이 객체 요청 밀도 8로 올림된다. 합성 612×792 PDF의 큰 글상자는 최대 job cap에서 2,939×2,854px, 33,551,624byte다. 두 작업 슬롯 예약은 67,103,248byte여서 64MiB cache 전체에서도 5,616byte만 남는다. undo가 만든 새 ID의 객체를 준비하면서 생존한 이미지·구형 형광펜까지 보호하면 기존 예약이 실패한다. 이는 완료 ink mesh의 128MiB 한도나 drawable의 8.02Mpx 한도와 다른 경계다.

[객체 텍스처 cache](../App/Desktop/PDF/NativePDFRetainedObjectTextures.swift)는 요구 밀도를 보존한 채 **예산 안에서 실제 준비할 밀도만 다음 작은 2의 거듭제곱으로 낮춘다**. page-point당 1px 미만으로 임의 축소하지 않고, 기존 per-object cap은 유지한다. accepted 자원을 퇴출하거나 기존 고해상도 텍스처를 낮추지 않는다. 새 텍스처가 성공한 뒤에만 교체하며, 같은 입력으로 낮은 밀도를 반복 생성하지 않고 여유가 생기면 가능한 업그레이드를 시도한다. 같은 요청의 실패는 최대 3회다. source·accepted/current texture·작업 슬롯의 기존 계정과 상한을 유지하며 GPU driver/command-buffer까지 포함한 전체 RSS 상한이라고 주장하지 않는다.

실제 bbox 회귀에서 밀도4의 1,498×1,454px, 8,712,368byte 글상자로 4개 texture가 모두 준비됐고 계정은 28,878,401byte였다. 별도 MixedScene 회귀는 실제 CG raster/GPU upload로 삭제2개→새 ID undo, 생존 texture identity·순서·multiply 보존, 20회 동일 update의 추가 job/raster/upload 0을 검사했다. 최종13인치 UI도 혼합 삭제·undo·재실행을 통과했다. **자원 압박 아래 객체 texture 해상도가 요구 밀도보다 낮을 수 있다는 품질 절충은 남으며**, 완료 ink mesh의 해상도나 raw 입력을 낮추는 변경은 아니다.

### 최신 다른 작업 통합과 검증 범위

후보는 최신 원본 전체를 복사한 기준에서 만들어졌다. `/private/tmp/bandal-ink32-base-manifest.json`의 2,233파일과 원본을 비교해 기준 이후 원본 변경 0개를 확인했고, 대표 iPad UI/상호작용 68파일·브라우저 36파일은 원본/기준/candidate SHA가 같았다. 56px 상시 rail+280px 본문, 설정 뒤로 이동, sidebar swipe, touch tab drag와 native ACK 장벽, 브라우저 탐색·복구, 네이티브 창·저장 안정성 수정이 포함된다. `/private/tmp/bandal-ink32-integration-review.json`은 소스 포함 증거이며 최종 앱 설치나 모든 동작 인수를 대신하지 않는다. 웹 v5·export/backend 버전 허용도 같은 후보에 반영했다.

| 검사 | 총 실행 | pass / skip / fail | 시간 | 해석 |
|---|---:|---:|---:|---|
| 빌드32 전체 Simulator native | 598 | 594 / 4 / 0 | 353.989s | 빌드33 texture 후속 변경 전 기준 |
| 빌드32 실제 iPad native | 271 | 271 / 0 / 0 | 77.273s | 빌드33 실기기 결과로 대체 표기하지 않음 |
| 빌드32 넓은 UI | 8 | 6 / 0 / 2 | 414.275s | 회전 predicate·13인치 mixed undo 실패 보존 |
| 빌드33 관련 Simulator native | 275 | 274 / 1 / 0 | 70.600s | skip은 Simulator의 실제 drawable 표시 시각 미지원 |
| 빌드33 13인치 UI | 2 | 2 / 0 / 0 | 79.827s | 위 두 실패를 수정 후 같은 크기에서 재검사 |
| 빌드33 실제 iPad | 275 | 275 / 0 / 0 | 78.065s | 최종 texture 수정 및 실제 presentation 포함 |

실행별 검사는 중복되므로 합쳐 고유 검사 수로 표시하지 않는다. 주요 로그는 `/private/tmp/bandal-ink32-{sim-native,device-native,ui}.log`, `/private/tmp/bandal-ink33-sim-native.log`, `/private/tmp/bandal-ink33-sim-ui.log`이고, 실기기33 결과는 `/private/tmp/bandal-ink33-device-native.log`와 같은 이름의 `.xcresult`, 수치 parity 결과는 `/private/tmp/bandal-ink32-quality-native.json`이다.

- **자료 보존:** 최신 중지 상태의 검사 전 사본과 검사 후 사본은 61개 테이블 변경0, PDF/Markdown14개 변경0, pending journal0, 양쪽 SQLite quick_check=ok였다(`/private/tmp/bandal-ink33-postcheck/comparison.json`). 별도 설치 전 운영 중→중지 사본 비교에서는 `materials_index` 한 행의 `mtime`·`updated_at`만 달랐고 잉크·PDF·journal은 같았다. 이 두 비교를 합쳐 모든 시점의 DB가 동일했다고 표현하지 않는다.
- **최종 설치/일반 실행:** 빌드33 설치 확인 후 2026-10-16 01:12:29 KST, PID12196, args=[]로 일반 실행했다(`/private/tmp/bandal-ink33-normal-launch.json`, `.log`). 별도 패키지 검사에서 복사형 자원459개가 candidate·원본 통합본·Simulator 앱·device 앱 사이에 같았고 고정 웹 소스29개 SHA도 일치했다(`/private/tmp/bandal-ink33-packaged-resources.json`). 플랫폼별로 컴파일된 `Assets.car`는 바이트 동일성 대상이 아니며 실제 설치 기기의 모든 파일을 이 보고서만으로 비교했다고 주장하지 않는다.
- **사용자 품질 인수:** 2026-10-16 사용자가 “자연스러워졌고 필기·지우개도 빠름”으로 확인했다. 확인 범위와 질문32/마지막 설치33의 구분은 문서 맨 위에 기록했다. 확대·스크롤 및 Goodnotes·Notability 동등/최상 품질까지 완료 판정하지 않는다.

빌드33 UI의 전체 화면 캡처3장과 영상12개 실제 PTS 표본에서 명백한 새 clipping은 보이지 않았고 삭제→undo→재실행 복원을 관찰했다. 재실행 중 본문 로드 전 공백 프레임도 보존했다(`/private/tmp/bandal-ink33-ui-review/review.md`). 선택된 표본이며 전 프레임 연속성·물리 Pencil 지연·사용자 화면 품질 인수의 증거로 확대하지 않는다.

## 이전 기록: 필기 품질 조사와 v4 구현

기준일: **2026-10-15 KST**. Doxens의 구심형 Catmull–Rom 제어점 수식을 검증하고 v4 렌더링으로 이식했다. 빌드 13의 사용자 피드백은 **첫 획 이후 여러 획을 쓰면 지연이 누적된다**였다. 빌드 14 적용 후 사용자는 **줄었지만 여전히 남음**이라고 답했다. 빌드 15 일반 실행에서도 아홉 번째 접촉의 첫 제출까지 677ms가 관찰됐다. 빌드 16은 자동 검사를 통과했지만 **사용자 검증에 실패했다**. 표시 캐시를 초기화한 일반 실행에서도 PDF가 버벅이고 기존 필기가 뒤늦게 따라왔다. 실제 사용자 로그에서는 71개 객체의 전체 화면 재생이 약 1초씩 반복됐고, 두 번째 Pencil 접촉의 이벤트 전달 대기가 1,089ms였다. 빌드 17에서는 실제 PDFKit 좌표의 미세한 반올림 오차가 캐시를 버리는 경로를 수정했다. 실제 자료 71개 위에 12획을 쓰는 실기기 UI에서 전체 재생 0회와 입력 전달 5–12ms를 확인했고 확대·스크롤·재실행도 통과했다. 이후 물리 Pencil 사용자 인수는 실패했다. 실제 첫째·셋째·넷째 획의 저장 왕복 뒤 약 1.16초 전체 재생과 다음 입력 약 1초 지연을 확인했다. 숫자의 소수 표기 차이와 실제 binary Double 값의 변화가 모두 발생하는 Swift/JavaScript 전달 결함을 재현했다. 빌드 18은 입력의 측정 Double을 직접 전달하고 decimal token을 정확히 파싱하며, boolean과 유한한 Double을 구분해 정확히 비교한다. 실제 iPad의 WK→SQLite→WK→Surface 회귀와 연속 20획에서 저장 뒤 전체 재생 0회를 확인했다. 관련 단위 61개(비공개 자료 2개 skip)와 UI 2개가 실패 없이 끝났으며 07:18 KST 일반 실행했다. 11:12 사용자 확인은 획 그리기 지연이 많이 줄었으나 스크롤 추종과 지우개 등 도구 전환 지연이 남는다는 결과였다. 새 실제 로그에서 지우개 구간의 입력 전달 대기 3,076ms·1,395ms와 이후 전체 배경 재생 1,372ms를 확인했다. 정상 삭제도 mutableBoundary로 기록되며 settled 삭제의 전체 재생이 여전히 메인 스레드에서 실행되는 경로를 후속 수정한다. 이 한 번의 재생이 앞선 대기 전체를 설명하는 것은 아니며, 실제 도구 클릭/스크롤 지연은 해당 로그만으로 측정할 수 없다. 곡선 품질·입력 지연·경쟁 앱 인수를 서로 구분한다. 설치·자동 검사·사용자 확인 결과는 [구현 현황](implementation-status.md)에 기록한다.

## 빌드 16: 확인된 경로와 남은 검증

677ms와 당시 `prepare` 676ms는 접촉부터 성공한 제출 시도까지의 **벽시계 시간**이다. 이를 한 함수의 CPU 처리시간이나 필압 보정만의 비용으로 단정하지 않는다. 새 진단은 실제 배경·기하·Metal 제출 CPU 구간, 제출 시도 사이 대기, drawable 미획득을 분리한다.

- **완료 후 필압 보정:** UIKit의 estimated-property 보정은 펜을 뗀 후, 다음 획을 쓰는 중에도 도착한다. 이때 완료 객체의 모습이 바뀌며 기존 완료 화면 캐시가 전체 획을 다시 그릴 수 있는 경로를 코드와 재현 검사로 확인했다. 준비된 곡선 경로 캐시만으로는 이 픽셀 재생 비용이 사라지지 않는다. 실제 기기의 합성 200획×96점 검사에서 198번째 획 보정의 전체 200획 재생은 약 1,887ms, 4획 접미부 재생은 약 40.7ms였다. 이 비교는 특정 합성 장면의 CPU 비용이며, 677ms 관측의 원인별 분해나 실제 사용자 지연 개선률이 아니다.
- **미해결 입력에 맞춘 체크포인트:** 입력 소유자가 아직 보정될 수 있는 완료 획 중 가장 앞선 위치를 캐시에 전달한다. 최근 4획이라는 고정 개수보다 오래된 보정 대기도 유지한다. 확정된 앞부분은 불투명 이미지로 보존하고 보정 대상 접미부만 순서대로 재생한다. 모든 보정이 끝나면 이미 그린 전체 이미지를 새 체크포인트로 승격해 확정된 획을 다시 그리지 않는다. 원본 측정값·journal 순서·동일 획 내부 투명도는 유지한다. 구현: [완료 화면 캐시](../App/Desktop/PDF/NativePDFCommittedSceneCache.swift), [입력 수명과 경계 전달](../App/Desktop/PDF/NativePDFInkSurface.swift).
- **이동·확대 중 배경:** 불변 PDF·객체 표시 목록을 유지한 `CATiledLayer`로 새로 드러난 영역을 보여준다. 일반 펜은 고정된 타일 배경 위에 즉시 표시하고, 그 뒤 완료된 짧은 획도 순서를 유지해 남긴다. 정지 후 전체 crop은 백그라운드에서 준비하며 실행 중 하나와 최신 대기 요청 하나로 제한한다. viewport·변환·세대와 유지 가능한 앞부분을 검사한 결과만 완료 화면 캐시에 넘기고, 새 불투명 배경과 Metal 미리보기를 같은 프레임에서 교체한다. UIKit/PDFKit 객체는 백그라운드에서 읽지 않고 준비된 CGPath·기록 PDF만 사용한다. 구현: [불변 표시 목록](../App/Desktop/PDF/NativePDFNavigationSnapshot.swift), [타일·비동기 rasterizer](../App/Desktop/PDF/NativePDFNavigationView.swift).

**실제 기기 단위 검사 50개는 모두 통과**했다(`/private/tmp/bandal-ink16-device-unit.log`). 이후 손가락 확대 UI에서 native recognizer는 움직이지만 PDF배율이 바뀌지 않는 문제를 재현했다. 정상 native확대에는 개입하지 않고 서로 다른 배율 요청이 적용되지 않는 세션만 보완하는 수정 뒤, 실제200획 이동·확대·축소·재실행 UI와 연속20획 저장 UI도 통과했다. 최종pinch 검사에서는 경계에 걸리지 않은8회 보완의 중심 오차0.0000pt, viewport최대1.46ms였다(`/private/tmp/bandal-ink16-device-navigation-final.log`). Simulator는 보완적용0회로 통과했다. 이 자동 검사를 실제 Pencil 지연 해결 또는 Goodnotes·Notability 동등 품질로 표시하지 않는다.

현재 남은 형광펜 제약도 있다. 이동 직후에는 multiply 합성에 필요한 실제 불투명 배경이 아직 준비되지 않을 수 있다. 현재 navigation 미리보기는 완료 대기 목록 또는 현재 획에 형광펜이 하나라도 있으면 전체 배경 crop을 기다린다. 따라서 그 뒤 일반 펜도 함께 기다릴 수 있다. 아래 작은 배경 타일 실험은 이 제한을 줄이기 위한 **후속 설계이며 빌드 16 제품 코드에 구현되지 않았다.**

## 후속 실험: 형광펜의 작은 배경 영역

프로토타입은 `/private/tmp/bandal-highlighter-tile-prototype/`에 보존했다. `main.swift`는 현재 불변 snapshot 클래스와 실제 Swift v4 기하를 별도 복사해 macOS Core Graphics에서 실행하며, `results-final.jsonl`에 측정값이 있다. 공유 Surface·Host·Metal 코드는 변경하지 않았다. 다음은 준비된 200획×96점, 배율 2, 워밍업 후 7회 중앙값이다. 실제 iPad의 입력→화면 지연 측정이 아니다.

| CPU raster 범위 | 페이지에 분산한 짧은 획 | 넓게 겹친 조밀한 획 |
|---|---:|---:|
| 전체 crop 380×320 픽셀 | 42.2ms | 50.2ms |
| 접촉 주변 32×32 픽셀 | 0.26ms | 0.57ms |
| 64×64 픽셀 | 0.78ms | 1.06ms |
| 128×128 픽셀 | 2.94ms | 3.99ms |

현재 command의 경계 검사와 준비된 곡선 경로를 그대로 써서 작은 영역 밖의 객체를 건너뛸 수 있다. 다만 복잡한 원본 PDF 해석 비용은 남는다. 100,000개 사각형을 가진 별도 합성 PDF는 잉크가 없어도 전체 crop 약 59.4ms, 32픽셀 영역 약 56.6ms였다. 공유 `Paper.lock`에서 진행 중인 PDF 해석을 기다리는 경우도 있으므로 작은 타일만으로 모든 문서의 첫 점 시간을 제한할 수 없다.

불투명 배경색을 `B`, 형광펜색을 `C`, 한 번만 계산한 획 coverage·불투명도를 `a`라 할 때, 투명 Metal 출력 `RGB=B×C×a, alpha=a`를 같은 `B` 위에 source-over하면 올바른 multiply 결과가 된다. 먼저 완료된 일반 펜과 두 형광펜이 겹치는 픽셀 검사에서 올바른 순서는 Core Graphics 기준과 최대 1/255 반올림 차이였고, 두 번째 획에 오래된 배경을 재사용한 잘못된 순서는 최대 32/255 차이를 만들었다. 따라서 배경에는 **그 획보다 앞선 모든 완료 대기 획**이 포함돼야 하며 현재 획 자신이나 이후 획은 들어가면 안 된다.

최소 구현 후보는 첫 점 주변의 작은 배경부터 준비하고, 획이 진행되는 방향의 타일을 제한된 큐에서 미리 준비하는 방식이다. 타일 키에는 화면에 고정된 배경의 세대·pixel scale·변환·좌표를 포함하고, 이미지와 GPU texture를 합한 byte 한도와 개수 한도를 둬야 한다. 오래된 결과는 폐기하고 보정·삭제·재정렬로 바뀐 배경을 화면의 옛 타일과 섞지 않는다. 완료 획마다 정확한 앞부분 배경을 유지하는 대신, 하나의 고정 배경에서 순서대로 RGB와 누적 coverage를 합성한 뒤 `RGB=최종색−B×(1−coverage)`로 투명 결과를 복원하는 추가 Metal pass도 수학적으로 성립했다. 어느 방식도 아직 제품 구현이나 GPU 표시 검증을 마친 것은 아니다.

품질상 남은 문제는 독립된 작은 crop이 현재 보이는 타일과 **비트 단위로 같다는 보장이 없다는 것**이다. 같은 v4 경로라도 Core Graphics의 별도 clip에서 일부 안티앨리어싱 픽셀은 전체 crop과 최대 3/255(분산 장면), 10/255(조밀한 장면) 달랐으며, 16픽셀 여유 영역을 붙여도 조밀한 장면의 차이가 완전히 사라지지 않았다. 화면과 형광펜이 같은 타일 backing을 공유하는 방법 또는 실제 표시된 타일을 기준으로 한 허용 오차·경계 픽셀 검증이 필요하다. 가로·세로 이동, 확대, 교차, 여러 완료 대기 획, 뒤늦은 필압 보정, 비동기 crop 교체까지 확인한 뒤 적용 여부를 결정한다. `CALayer.compositingFilter`는 [Apple이 iOS 미지원으로 명시](https://developer.apple.com/documentation/quartzcore/calayer/compositingfilter)하므로 대안으로 사용하지 않는다.

## Doxens에서 실제로 실행되는 경로

입력은 [PencilDrawingGestureRecognizer](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Views/PDFKitView.swift:155) → `DrawingOverlayView.pencilBegan/Moved/Ended` → [DrawingToolManager.beginStroke/continueStroke/endStroke](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/DrawingToolManager.swift:249) 순서다. 미리보기는 [DrawingOverlayView.draw](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Views/PDFKitView.swift:631)가 `StrokeRenderer.renderPreview`를 호출한다. 완료하면 `DoxensInkAnnotation`을 PDFPage에 추가하고, [draw(with:in:)](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/DoxensInkAnnotation.swift:44)가 같은 `StrokeRenderer` 계열로 그린다. 문서상 기능 목록 대신 이 연결된 코드를 조사 기준으로 삼았다.

| 항목 | 가져올 내용 또는 피할 이유 | 확인한 소스 |
|---|---|---|
| 구심형 Catmull–Rom | 거리 기반 매개변수 `alpha=0.5`의 cubic 제어점 계산을 안정적인 Hermite 형태로 이식했다. 기존 v3의 직선 연결과 별도 버전으로 유지한다. | [Doxens 제어점](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/CatmullRomSpline.swift:102), [Bandal v3](/Users/iseojun/dev/bandal-iPad/App/Desktop/PDF/NativePDFInkGeometryV3.swift:27) |
| 미리보기와 완료 획 | 하나의 렌더링 계약을 공유한다는 원칙은 유지한다. Bandal의 공통 버전별 기하·원본 저장 구조 위에 적용한다. | [Doxens 공통 렌더러](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/StrokeData.swift:289) |
| 펜 스타일 | 일정 두께 fineliner와 표현형 brush를 구분하는 아이디어는 이후 후보다. 첫 곡선 버전에서 필압·속도·끝 가늘어짐까지 동시에 바꾸지 않는다. | [PenStyle/width 계산](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/StrokeData.swift:95) |
| 샘플 시간·간격 | Doxens는 `touch.timestamp` 대신 현재 시간을 기록하며, 1 PDF pt 미만 이동을 버린다. coalesced 속도와 작은 글씨를 손상시킬 수 있어 가져오지 않는다. | [시간](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/StrokeData.swift:25), [간격 제거](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/DrawingToolManager.swift:282) |
| RDP와 필압 재배분 | 위치만 단순화한 뒤 전체 점 개수 비율로 폭을 재배분한다. 압력이 가해진 위치와 두께가 어긋나므로 이 조합을 사용하지 않는다. 구간당 고정 4회 분할도 그대로 복사하지 않는다. | [단순화/분할](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/CatmullRomSpline.swift:160), [폭 보간](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/StrokeData.swift:260) |
| 확대와 획 종료 | 미리보기는 화면 좌표, 완료 획은 PDF 좌표에서 같은 고정 오차로 단순화해 확대별 모양이 달라질 수 있다. 종료 이벤트의 마지막 샘플을 추가하지 않으며 한 점 획도 버린다. | [미리보기](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/StrokeData.swift:316), [종료](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Views/PDFKitView.swift:526), [최소 점 수](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/DrawingToolManager.swift:515) |
| 복원·PDF 저장 | 공유 복원은 원래 timestamp·penStyle·명시적 pointWidths를 복구하지 않고 폭을 다시 계산한다. PDF 저장은 `PDFDocument.write`이며 Bandal의 원본 샘플·완료 journal을 대체할 근거가 없다. | [공유 복원](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/SharedAnnotation.swift:325), [저장](/Users/iseojun/Desktop/doxens/doxens_iPad/doxens_iPad/Core/DocumentStore.swift:213) |

## v4 기하 계약

새 획은 **inkVersion: 4**를 사용한다. 기존 v2/v3 획은 다시 쓰거나 자동 변환하지 않는다. 필압의 시간 필터와 응답 곡선은 v3를 유지하고 중심선만 변경했다.

1. **원본 보존:** 위치·정규화 압력·측정 timestamp·기울기·순서를 그대로 저장한다. 예측점은 별도 미리보기 꼬리로만 사용하며, 뒤늦은 UIKit 측정 보정만 해당 원본 샘플을 갱신한다. 전역 RDP·간격 기반 원본 삭제를 넣지 않는다.
2. **물리 좌표에서 구심형 보간:** 정규화 좌표를 `(x, y × pageAspect)`로 계산해 세로/가로 배율을 맞춘다. 연속 네 측정점의 구심형 cubic을 만들고 중복점·정지 압력·급한 방향 전환에는 명시적 퇴화 처리를 둔다. 작은 한글 모서리를 둥글게 지우거나 꺾인 획을 넘어가는 곡선을 허용하지 않는다.
3. **입력 대기 없는 증분 처리:** 미래 측정점을 기다리며 펜끝을 숨기지 않는다. 처음 한 점은 즉시 점으로, 두 점은 즉시 연결로 표시한다. 이후 확정된 측정 구간은 고정하고 마지막 제한된 구간만 새 측정점에 따라 보완한다. 예측점은 확정된 측정 구간의 제어점을 바꾸지 않는다. 펜을 떼도 같은 측정점이면 같은 끝점 규칙을 적용해 모양이 갑자기 바뀌지 않아야 한다.
4. **필압 위치 유지:** 현재의 인과적 시간 기반 필압 필터를 출발점으로 삼는다. 추가한 곡선점의 폭은 그 구간의 두 측정 샘플에 대응하는 값과 같은 매개변수로 보간한다. 단순화 전후의 전체 배열 인덱스로 폭을 나누지 않는다. 필압 응답·속도에 따른 폭·끝 가늘어짐은 별도 실험으로 분리한다.
5. **적응형 분할과 상한:** 곡률·현 오차·펜 폭을 기준으로 구간을 세분화한다. 버전별 오차 기준과 최대 깊이/출력점 수를 고정해 긴 획의 프레임 비용을 제한한다. 화면 확대율에 따라 저장된 모양이 바뀌지 않도록 공통 기하의 분할 기준은 페이지 물리 비율에 두며, 화면 안티앨리어싱은 별도로 적용한다. 마지막 구간 수정은 기하·Metal 정점 캐시의 해당 접미부만 무효화한다.
6. **동일한 표시와 내보내기:** Swift와 TypeScript의 순수 함수에 같은 입력 fixture·상수·퇴화 규칙을 적용한다. 네이티브 미리보기, 완료 획, 웹 SVG, 보드/PDF 내보내기, 선택·이동·복원 모두 새 버전 분기를 함께 지원한 뒤 새 획 생성을 켠다. 획 내부 중첩을 한 번 합성하는 현재의 투명도 규칙을 유지한다.

구현은 [Swift 기하](../App/Desktop/PDF/NativePDFInkGeometryV4.swift), [증분 캐시](../App/Desktop/PDF/NativePDFInkGeometryV4Cache.swift), [공통 TypeScript 기하](../DesktopRuntime/upstream/src/shared/inkV4.ts), [웹 미리보기](../DesktopRuntime/renderer/pencil/livePreview.ts)에서 공유한다. 60° 이상 꺾임에는 보수적으로 접선을 제한하며, Swift/JavaScript 수치 라이브러리의 반올림으로 경계 분기가 달라지지 않도록 코사인 기준에 1e-12 여유를 둔다. 적응 분할 오차는 페이지 너비 기준 `clamp(width×0.08, 1e-5, 1e-4)`, 최대 깊이는 5다. 예측점은 최대 8개이며 마지막 측정 **필터링 압력**으로 별도 연결한다.

[공통 입력](fixtures/ink-v4-quality.json)과 [실행 검사](../Scripts/test-ink-v4-quality.mjs)는 실제 Swift·TypeScript 구현의 제어점, 중심선, 필압, 모든 disk/bridge 정점, 예측 및 변경되지 않는 앞 구간을 대조한다. 21개 입력·95,037개 수치에서 최대 차이는 3.33e-16이었다. 60° 경계의 정점 개수 불일치를 실제로 발견했고 양쪽 수정 후 통과했다. 16·32점 원의 중심선 최대 오차는 v3 직선 연결 대비 전체 구간 약 39% 감소했다. 내부 구간만 보면 95.7%·93.2% 감소하지만, 미래 입력을 기다리지 않는 첫·끝 구간이 전체 오차를 지배하므로 내부 수치를 전체 성능으로 표시하지 않는다. 직각·방향 반전의 돌출은 해당 fixture에서 0이었다. 이 합성 기하 수치를 실제 글씨의 가독성이나 입력 지연 개선률로 해석하지 않는다.

수식과 구심형 매개변수의 성질은 [원 저자 연구](https://www.cemyuksel.com/research/catmullrom_param/)와 독립 Barry–Goldman 계산으로 검증했다. 비퇴화 단일 구간의 첨점·자기교차 성질은 모든 사용자 모서리나 전체 획의 교차를 보장하지 않으므로 별도 corner guard를 둔다.

자동 검사는 점/정지 압력, 불규칙 샘플 간격, 짧은 갈고리, 급회전, 한글·수식, 예측 교체, 중간 샘플 보정, 긴 획의 접미부 갱신, 확대·CropBox·네 방향 회전, 저장/재실행, 투명도, 구버전 혼합을 포함한다. 전체 재생과 증분 결과가 일치해야 하며, 같은 측정점의 미리보기와 완료·내보내기 차이는 별도로 픽셀 비교한다. 계산 비용만 빨라졌다는 결과를 입력→화면 지연 개선률로 보고하지 않는다.

## 실제 Pencil 비교 인수 방법

내부 `submit.first`/`present.first`는 `NativePDFInkSurface.beginInput`이 입력을 받아 준비한 시점부터 잰다. 이전 획의 동기 저장·파일/디렉터리 `fsync` 때문에 다음 UIKit 이벤트 자체가 늦게 전달된 시간은 이 값에 포함되지 않는다. `input.delivery`는 `UITouch.timestamp`부터 Surface 입력 함수 진입까지, `input.entryWork`는 함수 진입부터 기존 접촉 시계 시작까지를 별도로 기록한다. 미래·음수·0 또는 60초보다 오래된 timestamp는 합성 테스트/잘못된 시계로 분리하여 지연 0으로 집계하지 않는다. 실제 화면 지연은 외부 촬영으로 확인해야 한다.

`nativePDF.journalTiming`은 checkpoint/commit/ACK 전체와 fileSync/directorySync를, `nativePDF.hostTiming`은 저장 콜백 전체·pendingRow 준비·refreshOverlays를 구분한다. 각 단계의 마지막 시간·누적 최대·최근 최대 240개 표본의 p95·호출 수를 보존하고 로그는 최초/느린 표본/주기 표본으로 제한한다. 실패한 저장 시도도 계측하지만 데이터·경로·사용자 문장은 로그에 넣지 않는다. 계측은 기존 저장 순서와 durability barrier를 바꾸지 않는다.

2026-10-15의 13인치 시뮬레이터 전체 단위 테스트에서 `testRapidInkAndSynchronizedClearNeverWaitForDrawableTimeout`은 두 번 간헐적으로 실패했다. 약 1.25초 동안 400회 제출 시도 중 성공이 11회·6회여서 기존 `>25` 기준을 충족하지 못했지만, 메인 스레드의 한 번 호출 최대 비용은 두 경우 모두 2ms 미만이었다. 이후 테스트에 백그라운드 drawable 획득 시작·종료, 초기 ready 상태, 크기 불일치, 창 상태만 추가하고 같은 작업량·단언을 유지한 13인치 전체 324개 검사에서는 4개 skip·0개 실패였으며, 성공 76회·defer 324회, 메인 최대 1.60ms, 백그라운드 획득 최대 18.1ms였다. 앞선 실패의 원인은 아직 특정하지 못했다. 이 재실행만으로 호스트 부하나 자원 누수를 원인으로 단정하거나 제품 결함이 해결됐다고 판정하지 않는다.

이 스트레스 테스트에는 별도 검증 공백이 있다. 각 burst가 항상 일반 잉크부터 시작하므로 하나의 ready drawable을 첫 시도가 소비하면 뒤따르는 synchronized clear가 모두 defer될 수 있다. 실제 6회 성공 실패 실행에서는 clear 성공이 0회여서 이미지 교체 경로를 검사하지 못했다. 고정 100ms 대기 후 `Task.sleep`으로 구동하는 테스트와 실제 `UIUpdateLink`의 화면 갱신 일정도 구분해야 한다. 후속 검사는 메인 호출 비용과 비동기 프레임 진행을 각각 유지하고, 준비 완료 조건과 성공한 clear 교체를 명시적으로 보장해야 한다. 현재는 단언 기준을 낮추거나 추측에 따른 제품 변경을 하지 않았다.

다음은 **예정된 측정 절차**이며 경쟁 앱에 대한 성능 주장이나 통과 기록이 아니다.

| 조건·측정 | 절차와 기록 |
|---|---|
| 공정한 조건 | 같은 iPad·Pencil·펜촉·화면 보호필름·PDF·페이지 배율·방향·밝기·전원/발열 상태에서 앱 순서를 교차한다. OS·각 앱 버전·실제 주사율·펜 종류와 보정 설정을 기록한다. 툴바 숫자 대신 화면에 보이는 선 폭을 맞춘다. 60Hz와 120Hz 기기는 따로 집계한다. |
| 첫 점·빠른 획 | 앱별 최소 100개 점과 100개 짧은 획을 3회 이상 반복한다. 가능하면 240fps 이상 외부 카메라로 펜촉 접촉과 화면 잉크를 함께 촬영한다. 접촉→첫 픽셀 p50/p95/p99, 펜을 뗀 뒤에야 나타난 획의 비율, 누락·끊김 횟수를 기록한다. 카메라의 한 프레임 시간과 접촉 판독 오차를 함께 제시한다. |
| 움직이는 펜끝 | 직선·원·작은 반복 루프를 느리게/빠르게 그린다. 펜촉과 잉크 끝의 거리, 속도, 예측 꼬리의 과도한 뻗음과 되돌림을 같은 영상에서 비교한다. 곡선에서의 위치 오차와 정지 후 보정량을 지연 하나로 환산하지 않는다. |
| 모양·가독성 | 작은 한글, 영문, 분수·첨자·행렬, 점과 짧은 받침, 급회전·가벼운 압력·정지 압력을 반복한다. 미리보기→펜 떼기→확대→재열기에서 획 모양·폭·색·위치의 변화와 자기 중첩 어두워짐을 확인한다. 앱 이름을 가린 이미지 비교와 실제 작성자의 조작성 평가를 함께 남긴다. |
| 혼합 사용·복구 | 손바닥 접촉·손가락 이동/확대·분할·페이지 전환·도구 전환을 섞어 2시간 사용한다. 시작/중간/끝의 지연 분포·메모리·발열 상태를 기록한다. 저장 실패·background·강제 종료/재실행·ACK 재전송은 격리된 시험 자료로 검사하고 누락·중복·undo 순서·PDF 원본 해시를 대조한다. |
| 내부 계측의 역할 | Bandal의 수신→Metal 제출과 실제 drawable 표시 시각은 원인 분석에 쓴다. 첫 접촉 전 처리 비용을 빠뜨리지 않도록 수신 지점도 명시한다. GPU command 완료, 시뮬레이터, XCTest 손가락 입력은 외부 카메라로 본 물리 Pencil 지연을 대신하지 않는다. |

인수 전에 비교 조건·판독 방법·허용 오차를 정한다. 각 비교 앱과 같은 조건의 분포를 따로 제시하고, 측정 오차를 고려해도 첫 표시/추적 지연이 더 느리거나 작은 글씨·팜 리젝션·복구에서 재현되는 결함이 남으면 동등 수준으로 판정하지 않는다. 누락·중복 획은 시험 범위에서 0건이어야 한다. 수치 통과와 별개로 사용자가 보고한 “필기가 이상함”이 실제 작성에서 해소됐는지 확인한다.

PDF 품질은 필기감과 별도 축이다. 원본 벡터/텍스트 보존, 확대 선명도, CropBox·회전 정합성, 검색/선택, 획의 벡터 내보내기와 다른 PDF 뷰어 재열기를 검증한다. 필기 벤치마크 하나의 통과를 전체 PDF 품질이나 “세계 최고”의 근거로 확대하지 않는다.

## 빌드 23: 도구 전환과 편집 중 화면 연속성 (2026-10-15)

빌드 18 이후 사용자는 획 입력 지연은 많이 줄었지만 스크롤에서 필기가 늦게 따라오며, 지우개는 버튼 선택부터 느리다고 보고했다. 22 후보는 같은 객체 장면을 중복 전송하지 않는 큐와 정확히 같은 저장 행의 준비 결과 재사용을 적용했다. 큐는 장면 전송을 하나씩 처리하고 페이지별 최신 장면을 유지하며, 도구 ACK 세대가 바뀌면 이전 응답을 채택하지 않는다. 저장·삭제·undo 작업 자체를 버리는 큐가 아니다. 행 재사용은 문자열의 UTF-8 표기, Boolean과 숫자, 큰 정수와 부동소수점, signed zero까지 구별한다.

22는 단위·UI 기능 검사를 통과했지만 지우기 영상을 확인하면서 별도 결함을 발견해 설치하지 않았다. 비동기 `CATiledLayer`를 교체한 직후 기존 완성 이미지를 숨기면 아직 새 타일 픽셀이 없는 큰 직사각형 영역에서 필기가 사라졌다. Metal 제출 성공은 타일의 픽셀 준비 완료를 보장하지 않는다.

23은 마지막으로 설치된 불투명 crop을 새 타일 아래에 유지한다. 새 불투명 이미지와 Metal 교체가 실제로 성공하는 트랜잭션에서만 이 보조 이미지를 해제한다. 그동안 실제 Surface에서 새로 작성한 일반 펜의 mutation ID만 구별해 기존 crop에 합성한다. 압력 보정·삭제·재정렬은 원본 crop에서 다시 합성하며, undo가 과거 획을 새 ID로 복원했다고 해서 같은 획을 두 번 합성하지 않는다. 형광펜은 이 오래된 보조 이미지를 정확한 multiply 배경으로 사용하지 않는다. 화면 밖 영역이나 아직 반영되지 않은 삭제의 즉각적 표시까지 이 보조 이미지가 보장하는 것은 아니다.

검증 기록은 `/Users/iseojun/.codex/artifacts/bandal-ink23-20261015`에 보존했다. 사용자 PDF·원본 데이터베이스 백업은 이 공개 가능한 합성 검사 자료와 분리해 `/private/tmp`에 둔다.

- 독립 연속성 검사 4개와 기존 비동기·혼합 검사 8개가 통과했다. 실제 타일 draw를 멈춘 상태의 화면 픽셀을 비교하고, 보조 이미지를 제거하면 비교가 실패하는 대조 검사도 포함한다. 최종 전체 PDF+필기 재생 RGBA exact 검사를 유지했다.
- 시뮬레이터 전체 433개 최초 실행은 428 통과·4 skip·1 실패였다. 실패한 검사는 첫 하위 레이어를 타일로 가정해 새 보조 레이어를 검사했다. 실제 `CATiledLayer` 개수·identity·좌표 변환·제거를 확인하도록 관측 대상을 고친 뒤 해당 클래스 8개가 통과했다. 이 테스트 수정 전후 앱 실행 파일과 `Bandal.debug.dylib`의 SHA가 동일하다. 전체 실행의 최초 실패 기록은 보존한다.
- 시뮬레이터 실제 앱에서 200획 지우기/undo/재실행, 손가락 이동/확대, 연속 20획 검사가 각각 통과했다. 지우개 클릭→선택 DOM을 관측한 다음 RAF까지 19ms였으며, native ACK나 물리 화면 표시 시간은 아니다.
- 같은 고정 viewport의 삭제 경로 밖 파란 획 ROI를 영상에서 비교했다. 22는 서로 다른 13개 표본 중 6개에 큰 공백이 있었고, 4개에서는 양쪽 획 픽셀 수가 모두 0이었다. 23의 20개 표본에서는 기준 대비 최저 왼쪽 98.60%·오른쪽 98.93%였으며 큰 공백은 관측하지 못했다. 압축·낮은 녹화 fps·선택 표본의 한계를 갖는 관측이고 전 프레임 보장은 아니다.
- iPad에 23을 설치하고 네이티브 검사 44개가 skip·실패 없이 통과했다. 합성 입력을 계속 누른 동안 실제 drawable이 표시됐고 첫 표시 26.34ms가 기록됐다. 물리 Pencil 촬영 결과와 구분한다. 같은 장치의 200×96점 행 재사용은 반복 84.43–85.78ms여서 전체 payload 비교 비용은 여전히 남아 있다.
- 실기기 UI 검사는 두 번 모두 앱 동작 검사 전에 `Timed out while enabling automation mode`로 초기화에 실패했다. 잠금 상태는 해제돼 있었다. 실제 UI 테스트 메서드는 실행되지 않았으므로 물리 장치에서 지우개·스크롤 UI 검사를 통과했다고 기록하지 않는다. 이후 테스트 인자 없이 23을 일반 실행했다.
- 설치 직전 최신 백업과 실기기 검사 후 백업은 61개 테이블, 14개 PDF/Markdown, 미저장 journal 모두 정확히 동일했고 SQLite 검사도 정상이다. 이 기준 백업은 전체 필기 행 143개·활성 85개·receipt 116개·pending 0개다. 이전 백업 이후 사용 중 생긴 변경을 옛 상태로 되돌리지 않았다. 이 비교는 과거 06:24–06:33 복구 범위의 불확실성을 해소하지 않는다.

남은 확인은 실제 Pencil 연속 사용에서의 사용자 체감, 실기기 UI 자동화 연결 문제, 스크롤 중 검은 상단 탭 영역이다. 검은 영역은 22·23 시뮬레이터 영상에서 모두 관측되며 실제 iPad 표시와 녹화 문제를 아직 구분하지 못했다. 실기기 단위 검사 중 WK off-main layout 경고도 보존했으며 원인은 미확정이다. Goodnotes·Notability와 동등하거나 우월하다는 판정은 아직 하지 않는다.

## 전체 행 비교 최적화 실험: 미채택 (2026-10-15)

빌드 23을 유지한 채 실제 `WKScriptMessage.body`로 받은 같은 200행×96점 자료의 반복 비교를 격리한 시뮬레이터에서 측정했다. Swift에서 만든 값에만 발생하는 현상이 아니며, 기존 비교 경로도 평균 약 63ms를 사용했다. 이 값은 `Store.apply`만의 Debug CPU 측정으로, 스크롤 한 프레임이나 도구 버튼의 전체 응답 시간은 아니다.

고정된 쪽의 타입·숫자·키를 미리 준비하는 후보와 기존 비교기를 같은 실행에서 순서를 바꿔 비교했다. 기존 회귀와 새 숫자·Unicode·가변 컨테이너·예산·행 수명 검사 등 35개는 모두 통과했다. 그러나 반복 평균은 63.08→56.28ms로 6.80ms만 줄었고, 초기 200행 준비는 92.11→146.22ms로 54.11ms 늘었다. 이 자료의 비교 메타데이터 계상량도 7,257,290바이트 추가됐다. 전체 입력 점을 여전히 다시 읽는 비용에 비해 이득이 작아 **원본 제품 코드와 iPad에 적용하지 않았다**.

후보·컴파일 수정·정확한 입력 해시·실측값은 `/Users/iseojun/.codex/artifacts/bandal-ink24-comparison-20261015`에 보존했다. 후속 검토는 편집 화면에서 변경된 행만 전달하는 방식이며, 저장·삭제·undo 및 미확인 Pencil 완료 자료의 계약은 별도로 유지해야 한다.

추가로 23의 화면 연속성 합성이 새 병목이 될 수 있는 조건을 재현했다. crop 교체를 강제로 보류하면 일반 펜 추가분을 원본 crop 위에 매번 합성한다. 고정된 23 제품 소스로 96점 획 100개를 누적했을 때 768×1024 픽셀 crop의 합성은 평균 313.20ms, 실제 Surface의 해당 성공 submit 구간은 355.31ms였다. 약 8M 픽셀 crop에 추가 20획을 합성하는 독립 호출도 평균 344.72ms였다. 변경 없는 호출은 약 0.08–0.16ms였다. 세 검사의 픽셀·원본 샘플·저장 순서 검증은 통과했으나, 정확성과 메인 스레드 지연은 별개였다. 이는 강제로 지연한 조건의 시뮬레이터 Debug 결과이며 사용자의 실제 발생 빈도를 뜻하지 않는다.

기록은 `/Users/iseojun/.codex/artifacts/bandal-ink24-continuity-cost-20261015`에 보존했다. 이 병목을 먼저 수정한다. 단순히 합성만 백그라운드로 옮기면 다음 타일과 합성 이미지가 준비되기 전에 완료 획이 사라질 수 있으므로, 완료 획의 즉각적인 표시와 불투명 타일 아래에서의 중복 없는 전환을 함께 검증해야 한다.

## 빌드 24: 연속성 화면의 증분 벡터 합성

crop 교체를 기다리는 동안 완료된 일반 펜을 매번 전체 bitmap에 합성하던 경로를, 원본 crop 하나와 증분 `CAShapeLayer`로 바꿨다. 새 획만 레이어를 만들고 필압 보정·삭제·재정렬은 기존 레이어를 갱신한다. 성공한 Metal 제출과 함께 화면을 교체하는 경계, 원본 측정값·journal·저장 순서는 유지한다. 제품에서 변환 경로 사본을 따로 만들지는 않지만 `CAShapeLayer.path`는 대입 시 복사된다. 명시적 UIImage 한 개를 Core Animation 전체 메모리 상한으로 해석하지 않는다.

분수 배율 crop에서는 원본 bitmap의 픽셀 올림과 `.resize`를 벡터에도 반영하도록 `sourceRect.size / original.size` 비율을 적용했다. **crop 3개×이동·회전·비균등 변환 4개**의 실제 레이어 경로 좌표가 독립 계산과 **1e-8 이내**로 일치했다. 이는 좌표 검증이며 전체 픽셀 동일성은 아니다. 교차 렌더러 RGBA exact 진단은 여전히 실패한다. 작은 불투명 획의 최대 차이는 1/255, 약 8M 픽셀의 20획은 opacity 0.45/0.5/1에서 각각 15/17/35였다. v1·v2 실패 로그와 이미지를 보존했다.

실제 UIWindow 캡처의 별도 넓은 획 검사 **9조건**(opacity 0.45/0.5/1×1·2·3획)은 통과했다. 독립 원본 경로의 coverage 경계와 상하좌우 1픽셀 여유 영역을 구분했으며, 흰색·회색 배경, 여러 획 교차와 한 획의 자기 교차에서 **완전히 덮인 내부의 채널 차이는 최대 1/255, 경계 여유 영역 밖은 exact**였다. 의도적으로 같은 획을 두 번 합성한 음성 대조군은 교차 내부에서 최대 40/255 차이를 검출했다. 다만 실제 캡처의 AA 경계에는 최대 163/255 차이도 남았다. 이 통과는 임시 연속성 화면의 위치·내부 색·중복 합성을 확인한 것이며, 모든 AA 픽셀이 같거나 시각적 차이가 없다는 뜻이 아니다. **최종 crop 교체 뒤 전체 PDF+객체 재생 RGBA exact 검증은 별도로 유지했다.**

실제 Surface의 crop 교체를 강제로 보류한 **100획×96샘플** 검사는 저장 원본·순서·최종 exact를 유지하며 24.028초에 통과했다. 100획 지점의 submit CPU 구간은 이전 355.31ms에서 6.78ms로 줄었지만, 후보의 **전체 render는 269.39ms, endInput은 31.11ms**였다. fixture가 완료마다 모든 visual token을 다시 만들고 준비된 잉크를 제공하지 않아 실제 Host의 변경 행만 교체하는 경로보다 많은 일을 시키는 차이를 확인했다. 그러나 269.39ms의 원인별 기여도는 미확정이며, 이 값을 버리거나 전체 필기 지연이 6.78ms라고 주장하지 않는다.

최초 cadence 중단은 테스트 보고서의 최대값 필드에 Double 대신 함수가 들어간 JSON 직렬화 오류로 좁혔고, 명시적 Double로 수정한 **Cadence2의 기존/벡터 검사 2개는 통과**했다. 같은 바이너리·60Hz Simulator 윈도에서 기존→벡터 순서로 실행한 21–100획 구간의 최대 메인 heartbeat 간격은 **309.01→7.59ms**, 최대 display-link 콜백 간격은 **308.99→16.86ms**였다. 경로 준비와 캡처는 측정 구간 밖에 둔 연속성 합성 실험이다. 메인 스레드 작업과 콜백 전달 개선의 근거이며, 프레임별 실제 픽셀 표시 시점이나 물리 Pencil 지연·120Hz 성능을 증명하지 않는다. 최초 실패 자료도 그대로 남겼다.

빌드 24 통합 네이티브 검사는 **435개 중 431 통과·4 skip·0 실패**였다. 위 전체 RGBA 진단 실패는 별도 연구 검사이며 이 숫자에 포함해 통과로 바꾸지 않았다. 전체 앱의 지우기·undo·재실행, 200획 손가락 이동/확대, 연속 20획 UI 검사 3개도 실패 없이 통과했다. 지우개 클릭→다음 RAF의 선택 DOM 관측은 18ms, 연속 20획의 저장 완료는 20개·pending 0개였다. iPad의 집중 네이티브 검사 46개도 65.843초에 skip·실패 없이 통과했다. 실제 Pencil 체감에 대한 사용자 인수는 대기 중이다. 경쟁 앱과 동등한 필기 품질이나 사용자 지연 해결을 완료로 표시하지 않는다. 합성 실험의 재현 소스와 실패·통과 근거는 `/Users/iseojun/.codex/artifacts/bandal-ink24-vector-20261015`에 보존했다. 주요 기록은 `Runs/Vector2/RESULTS.json`, `WIDE-QUALITY-RESULTS.json`, `SURFACE-COST-RESULTS.json`, `CADENCE-RESULTS.json`과 `/private/tmp/bandal-ink24-candidate/native-tests1.log`에 보존한다.

24 설치 직전과 실기기 검사 직후의 별도 백업을 비교했다. 61개 테이블 중 60개, 14개 PDF/Markdown, pending journal은 동일하고 SQLite quick_check도 양쪽 정상이다. `materials_index` 한 행의 `mtime`·`updated_at`만 바뀌어 데이터베이스 전체 exact로 기록하지 않는다. 필기 143행·활성 85행·receipt 116개와 원본 파일은 변하지 않았다. 14:19:37 KST에 테스트 인자 없이 일반 실행(PID 11305)했고 사용자 피드백을 요청했다. 이 비교는 과거 06:24–06:33 복구 범위의 불확실성을 해소하지 않는다.

24 지우개 영상의 같은 ROI에서 선택한 36개 실제 프레임의 파란 잉크 최저량은 기준 대비 왼쪽 98.636%·오른쪽 98.978%로 23과 비슷했다. 큰 직사각형 공백은 관측하지 못했다. 다만 확대·이동 영상의 기존 검정 상단 띠는 실제 PTS 21.9983–26.7000초에 다시 관측되고 26.8000초에 정상으로 돌아온다. 본문과 팔레트는 남아 있으며 물리 iPad에서도 같은지 아직 확인되지 않았다. 부분 영상 검사를 전 프레임 보장이나 이 문제의 해결로 표현하지 않는다.

## 빌드 24 후속 원인 분리: 제품 변경 없이 검증 (2026-10-15)

기존 269ms Surface fixture는 최초 200행×37점과 추가 100획×96점을 사용하며, publish마다 모든 visual token을 새로 만들고 `_nativeInk`를 제공하지 않았다. 같은 앱 바이너리에서 이 경로와 실제 Host처럼 `NativePDFDrawingSnapshotStore.Row`·token·준비된 경로를 유지하는 adapter를 순차 비교했다. 새 검사 1개는 30.994초에 통과했다. 기존 199행의 Row/token/path identity 검사 19,900회, 각 Row 준비 1회, journal 원본 bits, 선택한 중간 연속성 화면 RGBA와 최종 전체 재생 RGBA 검사가 통과했다.

100번째 획에서 raw-remint/Row 유지의 endInput CPU는 28.246/3.668ms, 마지막으로 관측한 render 호출은 284.261/0.767ms, end 시작부터 settled 조건까지의 wall time은 313.872/15.838ms였다. 고정 순서의 Simulator Debug·강제 crop 지연 조건이며 실제 Host dispatch/WK ACK나 물리 Pencil 지연 검사가 아니다. `renderLast`는 비동기 작업 전체를 포함하지 않고, 누적 `renderMax`에는 초기 장면 준비가 포함된다. 전체 렌더링이 0.767ms라거나 새 제품 최적화를 적용했다고 해석하지 않는다. 기존 획을 매번 새로 준비하는 시험 조건의 비용을 실제 앱 정상 경로와 분리한 결과다. 근거와 수정한 테스트는 `/Users/iseojun/.codex/artifacts/bandal-ink24-row-surface-20261015`에 보존했다.

검정 상단 띠는 첫 pinch 직후의 XCUIScreen PNG와 WKWebView 단독 snapshot에도 나타났고, 네이티브 PDF를 숨긴 동안에도 유지됐다. PDF model/presentation frame·mask와 WK zoom/offset은 안정적이었다. 부모 헤더의 `translateZ(0)` 실험은 효과가 없어 채택하지 않았다. bounded DOM 검사 200개와 공개 UIView 56개/CALayer 92개 관측에서도 상단을 덮는 불투명 검정 배경이나 별도 WK highlight view는 발견하지 못했다. DOM 표본에는 빠진 작은 자식이 있고 layer contents의 실제 픽셀은 검사하지 않았으므로 모든 overlay나 WebKit 내부 원인을 확정·배제하지 않는다. 첫 pen 모드 baseline 콜백은 발생하지 않아 정상/검정 layer 전후 비교는 확보하지 못했다.

같은 진단 바이너리의 iPadOS 26.3.1 Simulator에서도 띠가 재현됐다. OS 18.3.1만의 현상으로 보지는 않지만, 실제 iPad 표시와 공통 Simulator/캡처 문제는 여전히 구분하지 못했다. Run1 원래 navigation 검사는 `pinchFallbacks > 0`인데 `pinchAnchorChecks == 0`여서 실패했으며, 측정된 anchor 오차 실패나 clamp 원인 확정으로 기록하지 않는다. Run3는 정확한 메서드 필터로 0개가 실행돼 통과로 계산하지 않았다. 같은 바이너리의 클래스 필터 실행은 1개를 실제 실행했다. 실패·0개 실행·ROI/방향 보정과 모든 실험 자료는 `/Users/iseojun/.codex/artifacts/bandal-ink24-header-20261015`에 남겼다. 이 조사 동안 실제 iPad에 새 빌드를 설치하거나 사용자 자료를 변경하지 않았다.


## 빌드 25: 이동 화면 캐시의 식별자 수명 보장 (2026-10-15)

이동 중 추가된 획의 polygon 캐시는 `ObjectIdentifier`만 key로 보유했으며, 저장 ACK가 snapshot을 새 token으로 rekey한 뒤 이전 token의 마지막 owner가 사라질 수 있었다. 실제 allocator 주소 재사용을 재현한 것은 아니다. 25는 token과 immutable CGPath를 entry가 함께 소유하고, token/path identity와 페이지 size가 정확히 같을 때만 결과를 재사용한다. 현재 suffix만 남기고 페이지 교체·offscreen에서 정리한다. 기존 경로 추출과 저장 원본은 바꾸지 않았다. 새 지연 최적화로 표현하지 않는다.

독립 읽기 리뷰 뒤 Simulator 집중 native 57개가 69.759초, 실제 iPad 58개가 102.795초에 실패·skip 없이 통과했다. 새 수명·path/size·nil token·ACK/필압 보정/순서 회귀 4개를 포함한다. 물리 기기의 실제 Metal drawable 표시도 별도 검사했으며, 물리 Pencil 또는 실제 UI 자동화 통과로 대체하지 않는다.

최신 자료를 설치 직전에 백업하고 25 설치/검사 후 다시 비교했다. 61개 SQLite 테이블, PDF 10개·Markdown 4개, pending journal이 모두 exact이고 quick_check도 양쪽 정상이다. 필기 143행·활성 85행·receipt 116개·pending 0개도 같았다. 이후 테스트 인자 없이 일반 실행(PID 11343)했다. 예전 복구 시간대의 불확실성은 별개이며 체감 품질 인수는 아직 남았다.

25 검사에서는 기존 23에서도 보였던 WKContentView/UIView의 off-main layout 경고 3건이 나타났다. 24 검사에는 없었고 관련 Shell/capture/snapshot/test 소스는 24와 동일하다. 호출 스택이 없어 원인을 단정하거나 무해하다고 판정하지 않는다. Simulator의 검정 상단 띠 역시 미해결이며 물리 기기 발생 여부는 미확인이다. 소스·독립 리뷰·통과/빌드 실패 로그·설치 영수증·익명화된 자료 비교는 `/Users/iseojun/.codex/artifacts/bandal-ink25-20261015`에 보존했다.

## 빌드 26: 편집 화면의 변경 행 전송과 실제 도구 ACK (2026-10-15)

일반 실행 중인 25의 익명화된 성능 기록에서 `objectScene` 20개 표본이 46–96ms였다. 이것은 `EditorScene` 생성과 `refreshOverlays`를 포함한 Host CPU 경계다. 입력 전달은 counter가 13→1로 재시작된 두 구간이며, 앞 구간 최대 95ms·뒤 구간 최대 11ms였다. Surface 식별자가 없어 같은 collector의 재시작인지 별도 화면인지 구분할 수 없고, 95ms는 objectScene burst보다 앞이므로 인과를 단정하지 않는다.

기존 편집 화면은 선택 표시·미리보기만 바뀌어도 모든 획의 모든 점을 네이티브에서 다시 비교했다. 경로 자체는 이미 재사용되고 있었다. 26은 직전 **수락된 불변 editor Entry**를 기준으로 변경 행만 보내며, 변경 없는 Entry/Row/token/path는 그대로 유지한다. canonical 저장 자료와 editor 장면은 별개다. pending Pencil checkpoint 병합·원본 pressure/time·journal·삭제/undo 영속 처리는 유지한다. 모든 upsert는 기존 전체 JSON 검증을 거치고 `_nativeInk` 같은 전달 표식은 재사용 권한이 되지 않는다.

snapshot publisher의 공유 Promise를 호출자 epoch의 ACK로 해석하던 경로도 바꿨다. 실제 전송된 snapshot의 epoch/tool과 native 응답이 정확히 일치할 때만 편집 큐를 연다. 페이지별 수락 revision, session 전체 단조 revision, 정확한 UTF8 ID, 원자적 patch 검증, 유실/불일치 응답 뒤 더 높은 전체 reset, idless/중복 ID의 full fallback을 검증했다. nonink 도구의 새 epoch는 delta 권한만 폐기하며 표시 중인 editor scene은 교체 전까지 유지한다. pen/highlighter의 기존 clear 정책은 유지한다.

같은 바이너리의 실제 WKScriptMessage→Host 검사에서 Simulator 85행×96점의 선택 갱신 Host 평균은 26.875→0.231ms, 200행은 62.976→0.519ms였다. 실기기는 각각 **43.152→0.423ms**, **100.172→0.848ms**였다. JavaScript는 가변 입력을 놓치지 않도록 전체 JSON 비교를 계속 수행한다. 최초 전체 reset과 실제 바뀐 행의 준비 비용은 남는다.

이 검사에서 실기기 JavaScript 왕복 평균은 85행 89.45→6.2ms, 200행 268.8→88.7ms였다. **200행 patch의 두 번째 왕복은 1,454ms, 세 번째는 113ms**였고, 나머지 18개는 약 11–13ms였다. 두 느린 표본의 Host span은 각각 약 0.816/0.863ms였다. 이 멈춤은 측정한 Host 구간 밖에 있으며 JS/IPC/스케줄링 등 어느 부분인지 아직 분리하지 못했다. 왕복에는 테스트의 전송 바이트 계산·identity 관측도 포함한다. 전체 평균·최대값을 제외하거나 이 결과를 물리 Pencil→픽셀 지연으로 표현하지 않는다.

Simulator 전체 native 447개 중 443 통과·4 skip·실패 0, 별도로 실행한 baseline/differential/실제 WK 진단 3개도 통과했다. 실제 앱의 지우개 선택·삭제·undo·재실행, 손가락 확대, 연속 20획 UI 검사 3개가 통과했다. UI의 지우개 클릭→다음 RAF 선택 DOM 관측은 19ms이며 physical display 측정은 아니다. 실기기 집중 native **73개가 198.695초에 skip·실패 없이 통과**했다. 실제 raw bits·행 순서·경로 수명·선택 상태·RGBA 및 canonical ACK/pending 보존을 포함한다. JS 큐 34그룹 및 관련 웹 검사 7개도 통과했다.

설치 직전/검사 직후 백업은 61개 SQLite 테이블·PDF 10개/Markdown 4개·pending journal 모두 exact, 양쪽 quick_check 정상이다. 최신 자료는 필기 161행·활성 63행·receipt 134개·pending 0개이며 이전 25 설치 시점 백업으로 덮어쓰지 않았다. 테스트 인자 없는 일반 실행(PID 11507)으로 26을 설치했고 지우개 버튼의 실제 반응에 대한 사용자 인수를 요청했다. 생성된 WK 진단 소스는 별도 증거에 보존하고 원본 프로젝트에는 중복 JS 사본으로 넣지 않았다. 증거는 `/Users/iseojun/.codex/artifacts/bandal-ink26-20261015`에 있다.

## 상단 검정 띠 후속 분리: 실제 창과 최종 배율 복원 (제품 26 미반영)

Mac 잠금 해제 후 Run7에서는 macOS Simulator 실제 창에도 상단 검정 띠가 있음을 확인했다. Run8에서 native viewport 16개를 WK 전달 직전에 보류하고 최신 1개만 해제하자 전후 시스템 캡처 6개의 같은 ROI가 모두 검정 0%였다. Run9에서는 모든 viewport 전달과 scroll-anchor 처리를 유지하면서 `zoomRef/setZoom` 두 쓰기만 생략해 시스템 캡처 5개 모두 0%였다. Run7의 pinch 후 같은 ROI는 99.827%였다.

Run10은 native `pinching` 상태가 true인 동안만 두 zoom 쓰기를 보류하고 false에서 정상 적용했다. 15회 보류·종료 후 정상 적용 1회, native/ref/React zoom exact 1.5761227413902767과 실제/예상 DOM 폭 exact 1831px을 확인했고 시스템 캡처 5개의 검정 ROI도 0%였다. UI 1개가 60.510초에 통과했다. 단일 Simulator 진단이며, mask/layout의 간접 호출 빈도까지 통제하지 않았으므로 원인 함수를 확정하지 않는다. 제품 적용 전 ended/cancelled/failed, 동일 좌표 final event, suspend/resume, 기존 2 RAF receiving 해제 뒤의 오래된 DOM zoom 역전송을 검증해야 한다. 실제 iPad 검정 띠 여부도 아직 미확인이다. Run6–10과 최소 제품 정책 제안은 `/Users/iseojun/.codex/artifacts/bandal-ink24-header-20261015`에 보존했다.

## 빌드 26 사용자 확인과 지우개 재등장 재현 (2026-10-15)

사용자는 지우개 버튼 선택이 빨라졌다고 확인했지만, 지운 획이 다시 나타났다 사라진다고 보고했다. 실제 iPad 확대에서 검정 상단 가림은 없다고 답했다. 27 핀치 후보는 기능 검사를 통과했어도 영상에서 검정 영역이 남아 설치하지 않았다.

26 제품 기반 합성 지우개 UI 녹화에서도 undo 전에 삭제→재등장→삭제를 확인했다. 독립 ROI A의 파란 픽셀은 962→0→964→0→961→0, B는 956→0→953→0이었으며 삭제하지 않은 획은 유지됐다. 기능 UI 검사는 통과했으므로 중간 영상 검사가 필요하다. 별도 실제 CATiledLayer 재현에서도 첫 삭제 뒤 A=0이던 영역이 다음 타일 draw를 보류하자 A=1556으로 돌아왔다. 이전 불투명 crop이 삭제 전 필기를 포함하고, 완성된 첫 타일을 새 빈 타일로 교체할 때 아래의 오래된 필기가 노출되는 경로다. 저장 행을 다시 넣지 않아도 발생한다.

후속 수정은 완성된 삭제 이미지를 순서대로 설치하는 방식이며 아직 실기기 인수 전이다. 이미 지운 획의 재등장 방지, 살아 있는 획 보존, 연속 삭제 중 진행, pen/highlighter 전환·undo·저장 실패·viewport 전환을 함께 검증한다. 증거: `/Users/iseojun/.codex/artifacts/bandal-ink28-20261015/ErasureBaseline`.

## 빌드 28: 삭제한 획의 재등장 방지 (2026-10-15)

같은 viewport의 완성 화면에서 시작하는 지우개 삭제는 새 빈 타일로 교체하지 않고 완성된 불투명 crop을 순차 설치한다. 표시 중인 장면→완료된 crop→최신 장면이 같은 모습의 순서 보존 삭제인지 검증하며, 성공한 Metal 제출과 함께 표시 provenance만 전진한다. 중간 결과를 최신 authoritative cache로 취급하지 않는다. undo·style·추가·다른 viewport와 오래된 callback은 별도로 거절하고, worker는 기존 1 running+1 latest 제한을 유지한다. journal·ACK·원본 필압 자료는 변경하지 않았다.

Simulator 새13+기존async6=19개가 실패·skip 없이 통과했다. 실제 Surface에서 A816→0이 된 뒤 최신 crop을 보류한 10회 화면 검사에서 A최대0/생존 획최소1084를 유지했다. exact crop 채택 직후 encoder 실패→다음 삭제도 통과했다. 추가 pen2접촉/늦은 force bit/저장 순서/H→pen/undo/style/viewport/최종 독립 RGBA exact도 검사했다. 실제 앱 UI3개(지우기·undo·재실행, 손가락 확대, 연속20획)가 통과했다. 같은 ROI의 실제 지우개 영상 표본에서 수정 전의 삭제→재등장은 관측되지 않았고 생존 획은 유지됐다. VFR 녹화의 제한된 표본이므로 모든 화면·물리 입력 지연의 보장으로 확대하지 않는다.

실제 iPad native86개가 227.913초에 실패·skip 없이 통과했다. 새 실제 Surface 픽셀 검사와 실제 Metal 표시 검사를 포함한다. 설치 전후61개 테이블·14개 PDF/Markdown·pending journal은 exact이고 quick_check 정상이다. 최신 기준은 전체필기164행/활성32행/receipt137개/pending0이다. 빌드28을 테스트 인자 없이 일반 실행(PID11624)했고 재등장에 대한 사용자 확인을 요청했다. 과거 복구 시간대의 미확정 범위와 경쟁 앱 품질 인수는 별개로 남는다.

제한: unresolved 완료/추정 queue, 이동 후 타일만 표시 중인 경로는 기존 정책이다. 형광펜과 미반영 형광펜 뒤 펜은 정확한 배경을 기다릴 수 있다. 즉시 지우기나 전체 필기 지연 개선을 이 수정의 결과로 주장하지 않는다. 원본에는 Swift2개·테스트3개·버전만 통합했고 다른 채팅의 최신UI/웹리소스는 보존했다. 실기기 검증은 frozen26기반28에 대한 것으로 후속 UI합본과 구분한다. 증거는 `/Users/iseojun/.codex/artifacts/bandal-ink28-20261015`에 보존했다.

28 사용자 인수는 완료되지 않았다. 설치 후 사용자는 “줄었지만 가끔 다시 나타남”, “화면을 가만히 두고 기존 획을 지울 때도”라고 답했다. canonical/editor 표시 식별자 차이와 같은 UIImage를 재사용할 때 retained provenance의 갱신 누락 조건을 새 재현으로 조사한다. 실제사용 피드백이 합성 통과보다 우선하며 완전해결로 기록하지 않는다.


## 빌드 29: 같은 화면의 식별정보 전환과 남은 지우개 지연 (2026-10-15)

28에서 남은 재등장은 canonical 화면과 editor 화면이 같은 저장 획에 서로 다른 receipt 연결 정보를 전달하는 조건으로 재현했다. canonical 행에는 세션의 `clientMutationId`가 붙고 editor 행에는 저장 `id`만 남을 수 있다. SceneCache는 같은 그림이라 기존 UIImage를 재사용하지만 retained provenance는 이전 연결 정보를 유지해 다음 삭제의 순서 보존 증명이 실패했다. 새 빈 타일로 돌아가는 경로에서 이미 없어진 A가 다시 나타났다. 실제 Surface의 수정 전 검사에서 동일 이미지/reuse를 확인한 후 A=0→1,084픽셀, 생존 획 최소2,168픽셀이었고 역방향 식별정보 전환도 실패했다.

29는 이번 cache render가 reuse이고, cache 결과·실제 보이는 UIImage·retained 이미지가 동일하며 viewport/mapper와 성공 갱신한 immutable snapshot도 같을 때만 retained 식별정보를 현재 행으로 갱신한다. 새 이미지를 만들거나 deletion comparator를 느슨하게 하지 않는다. 아직 Metal clear에 성공하지 않은 crop로 실제 화면을 재명명하는 경로는 거절한다. 원본 샘플·journal·ACK·완료 큐는 변경하지 않았다.

Simulator 집중21개와 별도 안전검사2개가 모두 통과했다. 같은 회귀의 A 최대값은0, 생존 획 최소2,168을 유지했다. 실제 앱에서 최근 펜2획을 추가하고 기존 획을 지우는 검사는 47.915초에 통과했으며 202→197→undo202→재실행202를 확인했다. 공개 합성 녹화789/789 encoded frames를 같은 ROI/threshold로 조사했을 때 undo 전 재등장은 없었다. 다만 A가 없어진 뒤 undo 전 영상은2개, B–E가 없어진 뒤는1개 encoded frame뿐이라 녹화되지 않은 화면까지 보장하지 않는다. 지우개 sweep 시작→첫 소실 시간을 개별 hit 지연으로 해석하지 않는다.

실제 iPad 첫75개 실행은55 PASS/20 FAIL이었다. 첫 lifecycle timeout 전에17:41:18.361 실행 앱의 `running background` 전환이 XCTest 진단에 기록됐으며 전환 원인은 미확정이다. 이후 같은 소스의 recovery22개가52.619초에 모두 통과하고 별도 vector1개도 통과했다. 세 실행을 합쳐 선택한75개 고유 method 모두 PASS 기록을 얻었지만 최초 실패를 없애거나 한 번의 clean75 실행으로 표기하지 않는다. 설치 전후61개 테이블·14개 PDF/Markdown·pending journal은 exact, SQLite quick_check 정상이다. 기준 자료는 전체필기175행/활성11행/receipt148개/pending0이고 테스트 인자 없이 일반 실행한 PID는11682다.

설치 후 사용자는 **“다시 나타나진 않는데 지연 문제는 있어. 지우개에서.”**라고 답했다. 재등장 감소는 사용자 확인을 받았으나 지우개 지연은 해결되지 않았으므로 작업과 전체 품질 인수는 계속한다. 물리 Pencil 지연·모든 문서의 재등장 배제·Goodnotes/Notability 동등성을 이 결과로 주장하지 않는다. build29 서명 앱은 frozen26 기반28/29 수정이며 원본 workspace의 다른 채팅 UI 변경은 보존했다. 증거·실패 이력·서명 빌드/소스 해시는 `/Users/iseojun/.codex/artifacts/bandal-ink29-20261015`에 보존했고 사용자 원본 백업은 복사하지 않았다.

## 빌드 30: 완료 획의 GPU 유지와 네이티브 지우개 (2026-10-15)

29의 지우개 지연에 대해 표시 상태를 더 조정하는 대신 입력·완료 잉크·저장 경로를 변경했다. 지원되는 inkVersion 2/3/4 장면에서는 완료 획도 immutable Metal mesh로 유지하고 현재 획과 같은 순서의 GPU 경로에서 그린다. 획 내부 polygon은 stencil 합집합으로 한 번만 색을 적용하고, 획 간 source-over와 형광펜 multiply 순서를 보존한다. 삭제·색·순서·viewport 변경에 변하지 않은 mesh를 다시 올리지 않는다. PDF 종이와 annotation 배경은 잉크와 분리한다. 확대용 종이 crop을 기다리거나 GPU 업로드가 실패해도 준비된 기본 texture를 유지한다.

지우개는 네이티브에서 실제 기하와 coalesced 이동 구간을 hit-test하고 접촉 중 해당 획을 즉시 표시 목록에서 제외한다. lift 후에는 operation ID와 세대 내 순서 번호로 기존 웹 writer의 삭제·undo 경로에 전달한다. pen→erase→pen 순서를 보존하고, 결과 ACK가 유실되면 삭제/history를 반복하지 않고 결과만 다시 전달한다. 성공 ACK만으로 제외를 풀지 않고 canonical/editor의 후속 부재까지 확인한다. 불확실한 삭제는 숨김과 오류를 유지하며 flush/undo/close를 막지만 뒤의 새 필기 저장은 계속할 수 있다.

필기 journal 접근과 fsync는 serial worker로 옮겼다. 입력 callback은 제한된 메모리 큐가 원본을 인수한 뒤 반환하며, 디스크 쓰기와 전송 payload 준비가 끝난 티켓만 이벤트로 발행한다. 접수 실패는 sequence를 소비하지 않고 실패한 작업을 보존한다. flush/recovery는 main callback 순서에 기대지 않고 worker 완료 티켓을 직접 reconcile한다. 문서 교체 중 기존 ACK·마지막 입력을 보존하며, 교체 실패 시 최신 layout 가시성을 복원한다. ACK 파일 unlink 뒤 directory fsync 실패에도 재시도 barrier를 남긴다.

Doxens에서 참고한 것은 네이티브가 현재·완료 획을 소유하고 문서 좌표에서 hit 판정과 표시 갱신을 끝내는 흐름이다. 실제 구현은 `DoxensInkAnnotation`/`StrokeRenderer`, `DrawingToolManager.eraseAnnotation`을 비교했다. Bandal의 원본 샘플·버전별 기하·웹 저장 계약에 맞춰 구현했으며 Doxens의 Metal 엔진을 복사한 것이 아니다. Catmull–Rom alpha=0.5 이식은 앞선 v4 범위다. 작은 이동 샘플 제거·시각 재기록·PDF 전체 저장 방식은 가져오지 않았고 PencilKit으로 저장 형식을 바꾸지도 않았다.

최종 검증은 다음과 같다. 검사 총시간을 입력 한 번의 지연으로 해석하지 않는다.

| 실행 | 결과 | 범위 |
|---|---|---|
| Simulator 넓은 native 회귀 | 332개 중 329 PASS·3 skip·0 FAIL, 273.295초 | skip은 비공개 fixture opt-in 2개와 실제 drawable 표시 1개다. |
| 최종 Host 가시성 보완 후 증분 | 51개 중 50 PASS·1 private-fixture skip·0 FAIL, 94.296초 | 새 가시성 2개를 포함한다. 앞 묶음과 중복이 있다. |
| 최종 실제 앱 UI | 2 PASS·0 FAIL, 90.596초 | 202→삭제197→undo202→재실행202; 200획 pan/pinch에서 mesh build 200 유지·ink navigation crop 0. XCTest 손가락 대체 입력이며 물리 Pencil은 아니다. |
| 동일 최종 소스의 iPad native | 150 PASS·0 skip·0 FAIL, 58.170초 | 실제 drawable 표시, GPU 픽셀·순서, 연속 입력, native erase, journal/ACK, viewport·복구를 포함한다. |
| iPad 200행×96점 삭제 10회 | 행 전달→GPU 제출 7.775–10.039ms, mesh upload 200 유지, ink crop 요청 0 | 실제 Surface 경계다. JS·Pencil 접촉 전달·GPU 실제 표시까지의 전체 지연은 아니다. |

최종 이전 실패도 증거에 남긴다. 첫 UI 실행은 renderer-only 빌드가 packaged backend를 지워 PDF 진입 전 실패했다. 검증된 backend를 복원한 뒤 최종 UI가 통과했다. 종이 fallback 새 직접 검사 2개는 초기 테스트 이미지의 texture upload가 실패해 optional-selection 코드에 도달하지 못했다. fixture를 명시적인 sRGB 8-bit BGRA로 만들고 최초 upload 성공을 단언한 뒤 동일 행동 검사가 통과했다. 이 실패를 제품에서 관측한 지우개 실패로 해석하지 않는다.

실기기 설치 직전 현재 Documents를 앱 정지 상태로 새로 백업했다. 검사 뒤 비교에서 61개 테이블·14개 PDF/Markdown·pending journal이 동일했고 SQLite quick_check 정상, 원본 백업 변경 없음이다. 기준은 전체필기195행·활성1행·receipt168개·pending0이다. 30을 테스트 인자 없이 일반 실행(`arguments=[]`, PID11799)했고 설치 앱의 bundleVersion 30을 확인했다. 사용자 원본 백업은 검증 아카이브에 포함하지 않는다.

원본 저장소에는 SHA를 확인한 source/test/project.yml 40개를 반영했고 당시 다른 채팅의 원본 전용 30개 파일은 그대로 보존했다. 기존 UI/browser를 포함한 renderer→backend→worker→package를 재생성하고 합본 Simulator 빌드도 통과했다. **iPad 설치물은 frozen29 UI에 최종30 필기 변경을 적용해 검증한 바이너리**이며, 원본의 후속 UI 합본을 설치했다고 표현하지 않는다. 최종 소스·서명 앱 해시·실행 증거는 `/Users/iseojun/.codex/artifacts/bandal-ink30-20261015`에 보존한다.

남는 범위:

- text/image/shape·지원하지 않는 잉크·예산 초과가 섞이면 해당 페이지 전체가 기존 CG/웹 지우개 경로로 돌아간다. 혼합 객체까지 모두 GPU로 전환한 결과가 아니다. 새 경로는 획 단위 지우개다.
- 큐 접수 성공과 worker fsync 사이에 비정상 종료되면 메모리에만 있는 입력은 복구가 보장되지 않는다. 명시 lifecycle barrier는 별도로 기다린다. 삭제 operation ledger는 메모리 상태이며 backend 삭제 전 종료에 대한 영속 재시도/정확히 한 번 보장은 없다.
- 입력 검증·pending 기하 준비·overlay 갱신·원본 비교 일부와 명시 동기 recovery barrier는 MainActor에 남는다. 최초 형광펜의 필요한 종이 준비·큰 변경 행·혼합 객체는 추가 비용이 있다.
- 필압 범위·속도·끝 taper를 새 버전으로 바꾸지 않았다. 경쟁 앱과 물리 Pencil의 체감 동등성은 아직 인수되지 않았다. 사용자에게 30의 연속 필기 후 지우개 반응을 요청했으며 전체 목표는 진행 중이다.


## 2026-10-15 — 빌드 31: 혼합 페이지의 GPU 표시와 네이티브 지우개

빌드 30의 완료 잉크 mesh 유지 경로를 글상자·이미지·도형·구형 잉크가 섞인 페이지까지 확장했다. 현대 잉크(v2/3/4)는 기존 mesh를 그대로 사용하고, 다른 객체는 변경된 객체만 투명 텍스처로 준비한다. 하나의 Metal pass에서 원래 순서로 합성하므로 펜→이미지→형광펜의 순서, 투명도, multiply가 유지된다. 펜 추가·지우기·pan은 이미 준비된 객체나 완료 획을 다시 래스터하지 않는다.

객체 기록은 immutable PDF 명령으로 캡처하고 실제 래스터는 하나의 worker에서 수행한다. 네이티브 row token·이미지 identity·페이지 크기가 같으면 raw JSON 재복사 없이 재사용한다. 준비 중에는 이전 완성 장면과 네이티브에서 막 완료한 획을 유지하며 구조 삭제는 즉시 제외한다. ACK 전후 식별자, 늦은 필압 보정, 페이지 교체, 실행 취소, 오래된 worker 완료를 별도로 검사했다. 기존 배경 업로드 실패로 scheduler가 멈춰도 새 객체 자원이 준비되면 의존성을 재검토하고 같은 접촉을 다시 표시한다.

지원되는 혼합 페이지의 지우개는 실제/coalesced 입력으로 네이티브에서 대상 ID를 결정한다. JS pointer 왕복 없이 화면에서 제외한 후 기존 ordered operation/undo 저장 경로로 통지한다. 현대 잉크는 실제 필압 경로+margin, 구형 잉크·도형은 기존 JS의 kind별 기하를 사용한다. 점 사이 sweep은 연속 적용하며 예측 입력은 삭제에 사용하지 않는다. 잘못된 locationless 객체를 전역 삭제하는 구형 동작은 포팅하지 않았다.

예산은 객체 캐시의 기록·텍스처·작업 슬롯을 계상하고, 같은 Source의 해상도 교체 중 이전 accepted Resource도 포함한다. accepted+현재 candidate의 기록을 제한하되, 동기 캡처 중 이전 pending 후보 한 세트가 일시 공존할 수 있다. GPU in-flight/드라이버/PDF 해석기 비용을 포함한 프로세스 전체 메모리 상한을 의미하지 않는다. 완료 잉크 scene의 기존 128 MiB 제한도 개별 scene 제한이다. 지원하지 않는 객체나 자원 예산 초과 시에는 호환 표시 경로를 사용하므로 모든 문서가 항상 GPU 경로라고 주장하지 않는다.

검증 기록:

- 초기 통합(build3) 기존 PDF 회귀 360개: 357 통과, 조건부 3 skip, 실패 0. 이는 최종 build5의 단일 전체 실행과 구분한다.
- 최종 build5 변경 영역 63개 통과. 실제 GPU 픽셀·텍스처 순서·200획 혼합 페이지·native erase 단일 소유·undo 원본 샘플 보존·정지 중 자원 복구·예산/오래된 작업 재admission 포함.
- 실제 UI 3개 통과: 일반 잉크 삭제/undo/relaunch, 혼합 204개+새 2획의 삭제/undo/relaunch, 손가락 pan/pinch. 혼합 상태 206→199→206, nonInkObjects 3→2→3, retainedObjects 4→2→4. nativeEraseOperations 증가 확인. 최초 UI 명령의 잘못된 navigation selector는 0개 실행으로 별도 기록하고 올바른 selector를 별도로 실행했다.
- 실제 iPad 최종 실행: 195개 통과, skip/실패 0, 62.491초. Synthetic 입력·GPU 검사이며 물리 Pencil→광자 지연 수치나 사용자 체감 인수를 대신하지 않는다.
- 첫 픽셀 검사의 색상 조합은 두 합성 순서가 수학적으로 같아 순서 차이를 검출하지 못했다. 비가환 색상으로 수정했다. 초기 window 부착 시 낮은 밀도 작업이 먼저 끝나 3개 객체에 4회 업로드가 생기는 경우는 정상 해상도 승격으로 구분하고, 안정된 후 pan/추가 필기 시 재업로드가 없는 것을 검증했다. 실패 이력도 보존한다.
- 설치 전후 종료 상태 백업 비교: SQLite 61개 테이블 전체 동일, 원본 PDF 10개·Markdown 4개 동일, journal 0개, quick_check=ok. 실행 중 백업과 종료 후 백업 사이 materials_index의 mtime/updated_at 한 행 변경은 별도 preflight 기록이며 설치 후 비교 결과와 혼동하지 않는다. 사용자 백업 파일은 검증 아카이브에 넣지 않는다.
- 최종 build5 결과를 중복 제거하면 native/UI 198개 검사 모두 통과다. 플랫폼 간 반복을 포함한 실행 횟수는 261회이며 이를 서로 다른 261개 검사로 세지 않는다.
- Simulator 녹화에서 실제 시각이 다른 21개 표본을 검토했다. 혼합 객체 삭제·주변 획 유지·undo 복원을 확인했으나 삭제 후 1.952초 녹화 공백이 있어 그 구간의 재등장 부재는 검증할 수 없다. 확대 중 기존 검정 상단 탭 줄도 여전히 관찰됐고 본문 잉크는 유지됐다. 물리 iPad의 발생 여부나 원인은 이 녹화로 판단하지 않는다.
- 다른 채팅의 최신 UI를 보존한 원본 합본도 Simulator Debug 빌드에 성공했다. 이는 컴파일 검증이며 고정 후보 build5의 실기기·UI 실행 결과를 합본의 실행 결과로 전용하지 않는다.

고정 소스 `/private/tmp/bandal-ink31-build5`, 실기기 결과 `/private/tmp/bandal-ink31-device-native-final.xcresult`, UI 결과 `/private/tmp/bandal-ink31-ui1.xcresult` 및 `/private/tmp/bandal-ink31-ui-navigation.xcresult`, 데이터 비교 `/private/tmp/bandal-ink31-postcheck`. 20:13:47 KST에 빌드 31을 일반 인자([]), PID 11873으로 실행했다. 원본에는 변경 17개를 반영하고 별도 UI/기타 소스 26개의 해시를 보존했다. 원본 합본의 최신 UI/리소스는 기존 고정 후보와 다르며, 현재 iPad 설치는 고정 후보 build5이다.

실제 사용자의 연속 지우기·스크롤 체감 확인은 아직 남아 있다. v4 필압 곡선/속도 기반 두께/taper 개선과 네이티브 삭제의 crash-durable 저널은 이번 변경에 포함하지 않았다. Goodnotes/Notability 대비 동등 품질이나 전체 목표 완료로 표시하지 않는다.

고정 소스·실패 이력을 포함한 검사 결과·설치 증거·녹화 검토·통합 감사는 `/Users/iseojun/.codex/artifacts/bandal-ink31-20261015`에 보존한다. 사용자 원본 백업·SQLite 사본은 포함하지 않는다.

## 2026-10-16 — 빌드 31 지우개 실사용 확인

기존 PDF에 여러 획을 쓴 뒤 지우개로 연속해서 지울 때 닿는 순간 지워지고 유지되는지 묻는 확인 요청에 사용자가 **“즉시 지워지고 다시 나타나지 않음”**이라고 답했다. 이 실사용 확인 범위에서 지우개 반응 지연·삭제 획 재등장은 해결된 것으로 기록하고, 위 설치 당시의 지우개 확인 대기를 해소한다.

이 답변은 실제 지우개 사용 결과이며 입력 지연의 계측 수치나 모든 문서·호환 경로의 무결함 보장은 아니다. 스크롤·확대, 연속 필기, 필압·속도·끝 taper, 삭제의 crash durability와 Goodnotes/Notability 대비 전체 품질 인수는 별도 범위로 남는다. 이번에는 문서만 갱신했다. 제품 코드·기기 설치·사용자 데이터·기존 봉인 아카이브는 변경하지 않았다.
