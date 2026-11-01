# sync-fixtures

반달 동기화 공통 스펙의 적합성 예제다. 스펙 본문은 [SPEC.md](SPEC.md)(v2.5)에 있다.

- 각 폴더의 `root/`는 클라우드 루트를 그대로 옮긴 것이다.
- `expected.json`은 `root/` 전체를 파싱·머지한 뒤의 상태다. 데스크톱과 iPad 파서는 같은 결과를 내야 한다.
- **원본**은 데스크톱 저장소다. iPad는 특정 커밋의 사본을 두고 그 커밋을 기록한다.
- 포맷을 바꿀 때는 두 저장소에 같은 날 반영한다.

## 예제 목록

| 폴더 | 확인하는 것 |
|---|---|
| `01-basic` | 과목 1, PDF 1, md 노트 1, 필기 4종(펜·형광펜·이미지·글상자). 이미지는 `sha256`+`ext`로 쓰고 바이너리는 `assets/`에 있다. 패턴 밖 이름 3개(AppleDouble 점 파일, iCloud 중복본 `… 2.json.gz`, `.tmp`)는 `ignored`에 나와야 한다 |
| `02-same-id-both-edited` | 같은 획을 양쪽에서 고친 경우. 필기는 개체 전체 기준으로 t가 큰 쪽이 이긴다(iPad의 이동 < 데스크톱의 색 변경). t가 같으면 device_id가 큰 쪽이 이긴다. 과목은 필드마다 승자를 따로 정한다(이름은 iPad, 색은 데스크톱) |
| `03-delete-then-edit` | 삭제 뒤에 더 큰 t의 수정이 오면 복구된다(문서 D1, 획 S1). 수정 뒤에 더 큰 t의 삭제가 오면 삭제가 남는다(문서 D3, 획 S2). S2의 묘비는 최소형 `{id, page, t, del}`이다 |
| `04-note-both-edited` | `md_base`로 노트 충돌을 판정한다. 차례로 고친 경우(N1)에는 충돌이 없다. 동시에 고친 경우(N2)에는 본문 하나와 결정적 충돌 사본 하나가 남는다 |
| `05-note-attachments` | 노트 첨부. 링크한 asset이 있는 노트는 반영하고, 없는 노트는 `waiting.docs`에 둔다. 기기 파일(`devices/cccc…0003.json`)이 없는 기기가 진 버전의 충돌 사본은 device_id 앞 8자로 이름을 짓는다. 진 버전의 노트 파일이 없는 사본은 `waiting.copies`에 둔다 |
| `06-path-collision` | 경로 충돌. `1주차.pdf`, `1주차.PDF`, NFD로 쓴 `1주차.pdf`는 한 이름이다. `Lecture/Notes.md`와 `lecture/notes.md`도 한 이름이다. 삭제된 문서는 id가 가장 작아도 빠진다. `renames`가 결과다. 충돌 사본도 넣는다: 살아 있는 문서와 이름이 겹친 사본은 id 앞 4자를 붙이고, 겹친 사본끼리는 id가 작은 쪽이 이름을 쓴다. 그리스 문자 `ΟΔΥΣΣΕΥΣ 1.pdf`, `οδυσσευσ 1.pdf`, 끝 시그마로 쓴 `οδυσσευς 1.pdf`는 코드 포인트마다 `lower(upper(c))`로 바꾸면 모두 `οδυσσευσ 1.pdf`라 한 이름이다(v2.3). 문자열 전체를 JS `toLowerCase()`로 바꾸면 앞의 둘이 갈린다 |
| `07-out-of-range-coordinates` | 페이지를 조금 벗어난 좌표(-0.0012, 1.0034, 페이지 밖으로 나간 상자)를 거부하지 않고 쓴 그대로 둔다. 클램프는 각 앱이 저장할 때 한다 |
| `08-format-not-2` | `bandal.json`의 format이 3이면 아무것도 읽지 않는다. 깨진 log가 있어도 `errors`는 비어 있다 |
| `09-invalid-input` | 잘못된 입력과 파서 경계. 읽을 수 없는 파일은 `errors`다: JSON·gzip 오류, 배열 아님, `1e999`, 해시 불일치, BOM, 잘못된 UTF-8, 짝 없는 서로게이트, 깊이 65, gzip 뒤 쓰레기 바이트. 값이 틀린 이벤트와 개체(경로 탈출, `/`가 든 이름, 대문자 id, 2100년 이후 t, page 0, 잘못된 asset 참조, `del: false`)는 그것만 버리고, 같은 파일의 올바른 이벤트는 반영한다. 깊이 64, 중복 키(마지막 값), gzip 멤버 여러 개, gzip 뒤 0 바이트는 받는다 |
| `10-same-stamp` | `(t, device_id)`까지 같은 경우. seq가 큰 파일이 이기고, 같은 파일이면 뒤에 있는 것이 이긴다. device_id 비교가 seq보다 먼저다 |
| `11-note-revert` | head 규칙. A가 H1을 H0으로 되돌리는 동안 B가 H1에서 H2를 만들고 더 늦으면, 본문은 H2이고 A의 되돌리기(H0)는 충돌 사본으로 남는다. 오프라인 C가 원래 H0에서 H3을 만들었고 A의 되돌리기보다 늦으면, H3 하나만 남고 사본은 없다 |
| `12-pdf-append` | `pdf_prev_sha256`(D6). 결과의 값은 늘 이긴 `pdf_sha256`과 같은 이벤트의 것이다. 문서 1은 한 번 덧붙였다(H0→H1, 만든 이벤트에는 v2.3 전 형식이라 키가 없다). 문서 2는 덧붙인 뒤 다른 기기가 키 없이 파일을 바꿨으므로 null이다. 문서 3은 두 번 덧붙여 마지막 덧붙이기의 직전 값(H1)이다. 문서 4는 `pdf_sha256` 없이 온 값이라 무시한다. 문서 5는 대문자 hex라 그 이벤트를 버린다 |
| `13-course-delete` | 삭제된 과목(v2.4). "삭제된 과목"을 지울 때 문서 1에는 tombstone을 쓰고, 문서 2(v2.4 전 형식)에는 쓰지 않았다. 문서 3은 다른 기기가 삭제 뒤에 오프라인으로 더했다. 셋 다 삭제이고, 같은 이름인 2와 3은 이름 바꾸기가 없다. 그 과목의 노트(문서 7)는 head가 둘이어도 충돌 사본이 없다. "되살린 과목"은 지운 뒤 되살렸다. 다시 쓴 문서 4는 살아 있고, tombstone만 남은 문서 5는 삭제이고, tombstone이 없는 문서 6은 다시 살아난다 |
| `14-append-chain` | 덧붙이기 연결(v2.4). `pdf_rebind_from`이 결과다. 세 번 이어 덧붙인 문서 1은 H0·H1·H2에서 다시 묶인다. 같은 H0에서 동시에 덧붙인 문서 2는 이긴 H1b에 H0만 이어진다(진 H1은 아니다). 덧붙인 뒤 교체(null)하고 다시 덧붙인 문서 3은 H5만이다. 문서 4는 거꾸로 가는 위조 연결이 순환을 만들어도 이긴 sha256을 넣지 않는다. 덧붙이기가 없는 문서 5는 빈 배열이다 |
| `render/v5-diameter.json` | inkVersion 5의 점별 지름 계수. 두 렌더러의 굵기가 같은지 본다. 계수는 데스크톱 `src/shared/inkV5.ts`로 계산했다. 허용오차는 1e-6이다 |

## 고정 값

- **기기**: `aaaaaaaa-…0001`은 "MacBook Air"(데스크톱), `bbbbbbbb-…0002`는 "iPad Pro"다. 사전순으로는 iPad가 더 크다. `cccccccc-…0003`은 기기 파일이 아직 없는 기기다(05).
- **파일 이름**: 대소문자만 다른 두 경로를 두지 않는다. APFS와 NTFS는 둘을 같은 파일로 본다.
- **시각**: `t`는 ms epoch이고, 기준은 `T0 = 1793318400000`(2026-10-30T00:00:00Z)이다.
- **충돌 사본 id**: `uuidv5(namespace = 9b1f6a2e-3c4d-4e5f-8a6b-7c8d9e0f1a2b, name = "<document_id>:<진 쪽 md_hash>")`
- **해시**: `pdf_sha256`, `md_hash`, `assets/<sha256>.<ext>`는 모두 바이트의 SHA-256(소문자 hex)이다.
- **숫자**: 필기의 좌표(`points[].x/y`, `box`)는 소수 5자리, 압력 `p`는 3자리로 반올림돼 있다.
- **PDF 샘플**: 1쪽이고 MediaBox는 `[0 0 595.28 841.89]`, CropBox는 `[20 20 575.28 821.89]`다.
  - 12의 PDF는 이 샘플 끝에 같은 크기의 빈 쪽을 하나(`4e105d19…`)와 둘(`d1ae220b…`) 덧붙인 것, 그리고 크기가 다른 1쪽 PDF(`08d6bc08…`)다.
  - 14는 여기에 세 쪽째(`338ef225…`), 가로 쪽을 덧붙인 것(`7cb80aa3…`), 1쪽 PDF에 한 쪽을 덧붙인 것(`ec69db0a…`)을 더 쓴다.

## expected.json 형식

```text
fixture           폴더 이름
spec              "2.4"   예제 내용이 마지막으로 바뀐 스펙. v2.5는 Drive 루트 찾기만 바꿔 예제가 그대로다
blocked           null | "missing-root" | "update-required" | "unsupported-format"   format 검사 결과. null이 아니면 나머지는 모두 비어 있다
courses           {id: {name, sort, color, archived, alive}}
docs              {id: {course_id, type, name, rel_path, pdf_sha256 + pdf_prev_sha256 + pdf_rebind_from | md_hash, alive}}
ink               {document_id: {page: {object_id: 이긴 버전의 개체 전체}}}
notes             {document_id: {md_hash, file}}  file은 그 내용을 담은 root 안 경로
conflict_copies   [{id, of, course_id, rel_path, name, md_hash, file}]  지금 만들 사본, id 순
renames           [{id, name}]  경로 충돌로 내야 할 이름 바꾸기, id 순
waiting           {docs: [id], ink: [id], copies: [id]}  참조 대상이 아직 없어 반영을 미룬 문서·필기·충돌 사본, 각각 사전순
ignored           [root 기준 경로]  패턴 밖이라 무시한 파일, 사전순
errors            [root 기준 경로]  파싱하지 못한 파일, 사전순
```

- 삭제된 과목·문서·필기도 머지된 값 그대로 남긴다(`alive: false`, `del: true`). 나중에 복구될 때 이 값을 쓴다.
- v2.2에서 `blocked`, `renames`, `waiting`을 더했다. 01–04의 `root/`는 그대로이고 `expected.json`에 빈 값으로 들어 있다.
- v2.3에서 pdf 문서에 `pdf_prev_sha256`을 더했다. `pdf_sha256`이 있는 문서에만 있고, 값은 그 `pdf_sha256`을 쓴 이벤트의 것(없으면 null)이다.
- v2.4에서 `pdf_rebind_from`을 더했다. 덧붙이기 연결을 따라 이긴 `pdf_sha256`에 닿는 sha256들이고, 이긴 것 자체는 빼며 사전순이다. `alive`는 문서와 그 과목이 모두 살아 있을 때만 true다.
- 필기 개체는 해시가 아니라 개체 전체를 담는다. 두 플랫폼 사이에 정규 JSON(숫자 표기) 규칙을 맞추지 않아도 되도록 JSON 값으로 비교한다.

## 보는 방법

```sh
gzip -dc 01-basic/root/ink/*/1/b*.json.gz | python3 -m json.tool | head
shasum -a 256 01-basic/root/pdf/*.pdf          # 파일 이름과 같아야 한다
```

`.json.gz`를 고칠 때는 다음 순서를 따른다.

1. `gzip -dc`로 푼다.
2. 내용을 고친다.
3. `gzip -9n`으로 다시 묶는다.

`md_hash`나 `pdf_sha256`이 바뀌었다면 log와 `expected.json`도 함께 고친다.

## iPad 팀 검증 절차

1. 데스크톱 커밋을 정해 `sync-fixtures/`를 통째로 복사하고, 그 커밋을 `SOURCE`에 적는다.
2. 각 `root/`를 iPad 파서로 가져와 위 형식으로 직렬화한다.
3. `expected.json`과 JSON 값으로 비교한다. 키 순서는 무시하고, 숫자는 정확히 같아야 한다.
4. 차이가 나면 둘 중 하나로 처리한다.
   - 해석 차이면 SPEC.md에 대한 변경 제안으로 올린다.
   - 예제가 틀렸으면 데스크톱 저장소를 고친 뒤 다시 복사한다.
5. `render/v5-diameter.json`을 `NativePDFInkGeometryV5`의 점별 지름 계수와 1e-6 안에서 비교한다.
