> **Historical / 과거 구현 기록** — 이전 빌드의 구현·검증 기록이며, 삭제된 웹 UI·JavaScriptCore 경로가 포함될 수 있습니다. 현재 Swift 앱의 구조·빌드·검증 범위는 [README](../README.md)를 우선합니다. 아래 결과는 현재 빌드의 검증 결과가 아닙니다.

# 필기 21 통합 검증 — 2026-10-15

사용자 확인 기준은 빌드 18의 **획 입력 지연은 많이 감소, 스크롤에서 필기가 뒤따라옴, 도구 버튼을 누른 순간부터 선택이 느림**이다. 자동 검사 통과를 Goodnotes/Notability 수준 또는 물리 Pencil 인수로 대체하지 않는다.

## 변경과 현재 결과

- 20의 이동 중 화면 유지·동일 좌표 변환에 21의 입력 수명/늦은 필압 보정, GPU 배경 업로드 실패 복구를 합쳤다. 실패한 형광펜 배경은 정확한 새 배경이 준비될 때까지 기다리며 일반 펜 입력은 계속 받는다.
- 삭제·편집 후 완료 화면 전체 재생을 제한된 비동기 작업으로 옮겼다. 새 타일 배경과 잉크 화면은 같은 표시 전환에서 넘기고 오래된 작업 결과는 폐기한다.
- 편집 화면에서도 변경되지 않은 불변 행·곡선·표시 토큰을 재사용한다. 지우개는 한 접촉 안에서 실제 원본 점/스타일이 같은 획의 중심선을 재사용한다. 삭제 결과는 기존 판정과 4,145개 조건에서 일치했다.
- 팔레트 도구 변경의 중복 펜 설정 저장을 2회에서 1회로 줄였다. 같은 도구 재선택과 펜/형광펜 스타일 복원은 유지한다.

최종 네이티브 Simulator 실행은 **410개 중 406 통과·4 제외·실패 0**이다. 200획 확대·스크롤, 연속 20획, 지우개 선택→삭제→실행 취소→재실행 UI도 각각 통과했다. 전환 순간과 모든 화면 프레임의 지연을 증명하는 검사는 아니다.

측정한 지우개 도구 변경 native snapshot은 7ms였지만 이후 편집 목록 수신은 반복해서 85–148ms였다. 불변 행 재사용 전에도 전체 원본을 다시 복사·정렬 JSON으로 비교하는 비용이 남아 있어 다음 수정 대상으로 확인했다. 이 값은 Simulator 함수 벽시계이고 실제 버튼→화면 지연이 아니다.

압축된 Simulator 녹화의 표본에서는 하단 페이지 경계와 마지막 필기 줄이 함께 이동했다. 가변 프레임 기록과 대부분 빈 PDF 배경이므로 짧은 추종 지연을 배제할 수 없다. 상단 웹 탭 행이 일부 구간 검게 보이는 별도 현상도 관찰했으며 앱/녹화 원인은 미확정이다.

## 실행 기록과 실패 보존

- `/private/tmp/bandal-ink21-native-run3.{log,xcresult}`: 최종 native 410개.
- `/private/tmp/bandal-ink21-ui-run1.{log,xcresult}`: 스크롤·20획 통과, 새 지우개 테스트는 WK `Switch`를 `Button`으로 잘못 조회해 삭제 전 실패.
- `/private/tmp/bandal-ink21-ui-eraser-run2.{log,xcresult}`: 조회만 `.any`로 수정한 지우개 UI 통과. 선택 상태·삭제·실행 취소·저장 단언은 유지했다.
- `/private/tmp/bandal-ink21-full-web-build2.log`, `bandal-ink21-palette-test2.log`: 최종 팔레트 수정 포함 전체 패키지/팔레트 검사 통과. native 입력·지우개 정확성·타입 검사도 별도 완료했다.
- `/private/tmp/bandal-ink21-final-bundle-manifest.json`: Simulator 및 서명된 기기용 21 앱의 웹 자원 443개 모두 소스 패키지와 일치.
- 최초 native 실행은 renderer만 재빌드하여 backend.js가 패키지에서 빠져 17개 실패했다. 기기에 설치하지 않았으며 전체 build.mjs로 복구했다. 두 번째 native 실행의 결합 회귀 1개는 비동기 요청 포착을 기다리지 않은 검사 경합으로 실패했고, 해당 요청 도착 조건을 추가한 세 번째 실행에서 통과했다. 앞선 로그/결과를 보존했다.

## 원본 통합과 자료 보호

원본의 기존 변경을 보존하며 19→20의 12개 소스와 20→21의 18개 소스 변경을 순차 반영했다. generated project는 새 UI 검사 변경이 있어 사본으로 덮어쓰지 않고 현재 원본 project.yml에서 재생성했다. 정확한 전후 SHA는 `/private/tmp/bandal-original-20-integration/MANIFEST.json`, `/private/tmp/bandal-original-21-integration/AFTER-MANIFEST.json`, `GENERATED-PROJECT.json`이다. 21 사본에 없는 새 브라우저/전체 UI 작업도 있으므로 그 사본의 웹 자원을 원본에 복사하지 않는다. 합친 원본은 다음 빌드로 다시 검증한다.

12:08 읽기 백업은 전체 필기 138행/활성 93개, 저장 대기 0, SQLite quick_check=ok다. 11:47 이후 사용자가 추가·삭제한 내용이 있으므로 이전 백업의 137행/활성 99개와 동일하다고 표현하지 않는다. 원본 PDF/Markdown은 두 백업 사이에 동일하다. 개인 백업은 로컬 임시 위치에만 있고 저장소에 포함하지 않는다.

21 실기기 검사 요청은 앱 설치까지 진행됐지만 잠금 때문에 테스트를 실행하지 못했다. 12:25에 중간 빌드의 대기를 직접 취소했다(exit 73, 결과의 failure 항목은 `Testing was canceled`, 실제 테스트 통과 0). 12:26 device info에서 설치 버전 21을 확인했으므로 설치 전 상태인 18이라고 계속 표시하지 않는다. 일반 실행이나 물리 Pencil 인수는 확인되지 않았다. 12:26 설치 후 읽기 백업과 12:08 직전 백업을 작업용 DB 복사본에서 비교한 결과, **61개 테이블의 모든 값·PDF/Markdown 14개·대기 journal 모두 차이 0**, quick_check=ok였다. `/private/tmp/bandal-ink21-install-preservation/comparison.json`과 `/private/tmp/bandal-ink21-device-run1-summary.json`에 기록했다. 과거 06:24–06:33 복구 불확실성은 이 검사로 해소되지 않는다.
