# sync-fixtures

반달 동기화 공통 스펙의 적합성 예제다. 스펙 본문은 [SPEC.md](SPEC.md)(v2.1)에 있다.

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
| `render/v5-diameter.json` | inkVersion 5의 점별 지름 계수. 두 렌더러의 굵기가 같은지 본다. 계수는 데스크톱 `src/shared/inkV5.ts`로 계산했다. 허용오차는 1e-6이다 |

## 고정 값

- **기기**: `aaaaaaaa-…0001`은 "MacBook Air"(데스크톱), `bbbbbbbb-…0002`는 "iPad Pro"다. 사전순으로는 iPad가 더 크다.
- **시각**: `t`는 ms epoch이고, 기준은 `T0 = 1793318400000`(2026-10-30T00:00:00Z)이다.
- **충돌 사본 id**: `uuidv5(namespace = 9b1f6a2e-3c4d-4e5f-8a6b-7c8d9e0f1a2b, name = "<document_id>:<진 쪽 md_hash>")`
- **해시**: `pdf_sha256`, `md_hash`, `assets/<sha256>.<ext>`는 모두 바이트의 SHA-256(소문자 hex)이다.
- **숫자**: 필기의 좌표(`points[].x/y`, `box`)는 소수 5자리, 압력 `p`는 3자리로 반올림돼 있다.
- **PDF 샘플**: 1쪽이고 MediaBox는 `[0 0 595.28 841.89]`, CropBox는 `[20 20 575.28 821.89]`다.

## expected.json 형식

```text
fixture           폴더 이름
spec              "2.1"
courses           {id: {name, sort, color, archived, alive}}
docs              {id: {course_id, type, name, rel_path, pdf_sha256 | md_hash, alive}}
ink               {document_id: {page: {object_id: 이긴 버전의 개체 전체}}}
notes             {document_id: {md_hash, file}}  file은 그 내용을 담은 root 안 경로
conflict_copies   [{id, of, course_id, rel_path, name, md_hash, file}]  id 순
ignored           [root 기준 경로]  패턴 밖이라 무시한 파일, 사전순
errors            [root 기준 경로]  파싱하지 못한 파일, 사전순
```

- 삭제된 과목·문서·필기도 머지된 값 그대로 남긴다(`alive: false`, `del: true`). 나중에 복구될 때 이 값을 쓴다.
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
