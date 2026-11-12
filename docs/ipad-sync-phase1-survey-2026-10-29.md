# 반달 iPad — 로그인·동기화·구독 1단계 현황 조사

- 작성일: 2026-10-29
- 기준: `main` 747808b와 현재 작업 트리. 미커밋 변경은 라이브러리·워크스페이스 UI 파일뿐이라 조사 대상 로직과는 관계없다. 다만 `NativeWorkspaceView.swift`의 줄 번호는 작업 트리 기준이다.
- 범위: 1단계 조사만 했다. 코드는 바꾸지 않았고 공통 스펙도 고치지 않았다. 스펙에 영향을 주는 발견은 §11 "변경 제안 후보"에 모았다.
- 표기: `파일:줄`은 이 저장소 기준이다. 데스크톱(Electron) 저장소는 `bandal:` 접두로 적었다.

---

## 0. 요약

1. **로컬 저장은 SwiftData나 Core Data가 아니다.** 데스크톱과 같은 SQLite 스키마에 실제 파일을 더한 구조다. DB는 `Documents/BandalDesktop/bandal.db`이고 데스크톱 마이그레이션 v1–37을 그대로 실행한다. PDF와 `.md`는 과목 폴더에 실제 파일로 있다.
2. **필기 엔진은 PencilKit이 아니라 자체 엔진이다.** UITouch로 입력을 받고 Metal로 그리며, 획 모양은 inkVersion 5 형상으로 계산한다. `pdf_drawings` 테이블에 획·도형 1개당 1행으로 저장하고, 행마다 UUID가 있다. 좌표는 "회전을 반영한 CropBox 기준 0–1 정규화" 값이다. **데스크톱도 같은 테이블, 같은 행 포맷, 같은 V5 형상을 이미 쓴다.** 두 앱의 "native" 포맷은 사실상 하나다(§11-1).
3. **UUID 현황.** 과목·획·하이라이트·화이트보드에는 UUID가 있다. **페이지는 엔티티 자체가 없고 1부터 시작하는 정수 인덱스뿐이다.** 문서 ID는 경로에서 나온다. 앱 밖에서 옮기거나 이름을 바꾸면 새 ID가 생긴다. PDF는 처음 열 때 고정된다. `device_id`와 `seq`는 없다.
4. **PDF 원본.** 필기와 하이라이트는 PDF에 굽지 않는다. **예외로, 페이지 추가·삭제·순서 변경은 과목 폴더의 PDF 파일을 다시 쓴다.** 변경 전후 바이트는 `PDFOriginals/<sha256>.pdf`에 남는다. 스펙의 page 모델에는 "원본 PDF의 몇 쪽인가"가 없어서 이 동작을 표현할 수 없다(§11-2).
5. **기존 동기화는 새 원칙과 정면으로 충돌한다.** 자료를 Supabase DB(`bandal_records`)와 Storage(`bandal-assets`)에 올리고, 로그인과 구독(`writeAllowed`)을 조건으로 건다. 1.1.0에서는 UI가 숨겨져 실제로 돌지 않는다. 타이머만 돈다.
6. **로그인이 로컬 자료를 잠그는 코드가 있다.** `NativeLoginGate`는 데이터 폴더를 처음 로그인한 계정에 묶는다. 1.1.0은 `isLocalOnly = true`라 꺼져 있지만, 플래그를 끄면 원칙 1 위반이 되살아난다. 계정 삭제 후와 Supabase URL 변경 후에는 영구 잠금 경로가 있다.
7. **구독(StoreKit 2)은 로그인이 필수이고 서버가 판정한다.** 상품 ID는 `app.bandal.ipad.sync.monthly/yearly`, 설정 패널 제목은 "동기화 구독"이다. 원칙 3과 "페이월에 동기화 언급 금지"에 모두 걸린다.
8. **iCloud 준비는 하나도 없다.** entitlements, App ID capability, `NSUbiquitousContainers` 모두 없다. App ID capability는 App Store 프로파일로 확인했다.
9. **페이지당 용량(1단계 추정).** 원본 샘플에 native를 함께 넣으면 빽빽한 페이지(600획)가 gzip 후 약 2.0–2.4 MB다. 합성 데이터 기준이고 자세한 내용은 §10.1에 있다. 이 중 native 블롭이 strokes의 3–4배를 차지한다.

---

## 1. 로컬 저장 구조

### 1.1 위치

| 경로 | 내용 | 근거 |
|---|---|---|
| `Documents/BandalDesktop/` | 데이터 루트. 프로필을 바꾸면 `Documents/BandalProfile-<uuid>/`가 되고, 어느 쪽인지는 `Documents/active-profile.json`이 정한다 | `App/Native/NativeWorkspaceStore.swift:117`, `App/Desktop/DesktopProfileService.swift:27-35` |
| `…/bandal.db` | SQLite(WAL). 자체 래퍼를 쓴다. 스키마는 "Frozen desktop migrations" v1–37에 저장소별 추가 테이블을 더한 것 | `App/Desktop/DesktopSQLite.swift`, `App/Native/Storage/NativeDatabaseMigrations.swift` |
| `…/Courses/<slug>/…` | 관리형 과목 폴더(실제 파일). 연결형 과목(`source='linked'`)은 사용자가 고른 외부 폴더를 보안 범위 북마크로 연다 | `App/Native/Storage/NativeLibraryRepository.swift:57-96` |
| `…/PDFOriginals/<sha256>.pdf` | PDF 원본 보존본(0600, 해시 검증) | `App/Native/Storage/NativePDFRepository.swift:169-186` |
| `…/CommonSync/` | 기존 Supabase 동기화 엔진의 큐(`bandal.sqlite`)와 `Assets/` | `App/Desktop/DesktopSyncService.swift:53-58` |
| `…/settings.json`, `account-binding.json`, `account-access.json` | 설정, 로그인 바인딩, 접근 영수증(§5) | `App/Desktop/DesktopAccountService.swift:66-77` |
| `…/SyncRecovery/`, `SyncConflictAssets/`, `MigrationRecovery/`, `Temporary/`, `Logs/` | 복구 기록과 로그 | `App/Native/Storage/NativeRepositoryContext.swift:251` |
| `Documents/Bandal/bandal.sqlite` | 1세대 iPad 포맷(BandalCore `RecordStore`). 첫 실행 때 1회 이관한다(`native-to-desktop-v1`) | `App/Native/Storage/NativeLegacyMigration.swift` |
| `Library/Application Support/NativeMarkdownDrafts/` | 마크다운 미저장 초안 | `App/Native/NativeMarkdownPersistence.swift:15-19` |

- Info.plist의 `UIFileSharingEnabled`와 `LSSupportsOpeningDocumentsInPlace`가 YES다. 그래서 **`Documents/` 전체가 파일 앱 "나의 iPad › 반달"에 보인다.** `bandal.db`도 포함이다.
- 프로필마다 데이터 루트가 따로다. 동기화도 프로필 단위로 다뤄야 한다.

### 1.2 엔티티별 저장과 식별자

| 엔티티 | 저장 | 식별자 | 안정성 |
|---|---|---|---|
| 과목 | `courses` (`NativeDatabaseMigrations.swift:89`). 그 밖에 `folder_path`, `slug`, `color`, `sort_order`, `archived`, `workspace_kind`, `group_id`(→`course_groups`, UUID, `:498`), soft delete | `id`: 소문자 UUID TEXT | 안정 |
| 문서(자료) | 과목 폴더의 파일. 인덱스는 `materials_index(id, course_id, rel_path, kind)` (`:103`) | `id`: UUID지만 **경로 스캔 때 부여한다**(`NativeLibraryRepository.swift:307`) | 부분 안정. 앱 안의 이름 변경·이동은 `repointDatabase`(`:693`)가 ID를 유지한다. **파일 앱이나 연결 폴더에서 옮기거나 이름을 바꾸면, 또는 인덱스를 잃으면 새 UUID가 생긴다.** PDF는 편집기로 처음 열 때 `pdf_document_bindings`/`pdf_document_aliases`가 `material_id`를 고정한다(`NativePDFRepository.swift:102-149`) |
| PDF 버전 | `pdf_document_bindings.bound_sha` | SHA-256 | 내용 기반 |
| 페이지 | **엔티티 없음.** `pdf_drawings.page`, `annotations.page`, `pdf_view_state.page`, `whiteboard_local_shapes.page`가 1부터 시작하는 정수다. 크기는 저장하지 않고 매번 PDF의 CropBox와 /Rotate에서 계산한다 | 없음 | 페이지를 재구성하면 번호가 다시 매겨진다(§4) |
| 필기(획·도형·글상자·이미지) | `pdf_drawings` (`:325`). 1행이 개체 1개다 | `id`: UUID | 안정. 지우개는 soft delete다. 올가미 이동·크기·색 변경은 **같은 id로 update**, 도형 스냅은 같은 id로 kind를 바꾼다. 지우기를 취소하면 **새 id로 다시 만든다**(`App/Native/NativePDFPersistence.swift:690-745`) |
| 텍스트 하이라이트 | `annotations` (`:116`). rects(정규화)와 anchor(quote/prefix/suffix), 색 4종 | UUID | 안정 |
| 손글씨 노트 | "노트" 버튼은 줄노트 PDF를 만든다(`pdfNotes:create`). 기본 폴더는 `노트/`, 크기는 A4 595.28×841.89pt, 종이는 blank/lines/grid/dots. 이후로는 PDF와 똑같이 다룬다 | 문서와 동일 | 문서와 동일. 근거는 `App/Native/NativeWorkspaceView.swift:726`("Notes are PDF notes, like the desktop"), `NativePDFRepository.swift:429-447` |
| 타이핑 노트 | `.md` 파일(§3) | 문서와 동일 | 문서와 동일 |
| 화이트보드(레거시) | `whiteboards` (`:408`)와 `whiteboard_local_shapes` (`:420`). 페이지는 정수다. UI에서 새로 만들지 않고(`canvas:create` 호출처 없음) 기존 보드만 열린다 | UUID | 안정. 단 스펙에 "PDF 없는 손글씨 문서"를 담을 타입이 없다(§11-9) |
| 페이지 노트 링크 | `material_links`(kind `pdf-page-note`, `:639`). source/target JSON이 **`courseId`+`relPath` 경로**다 | 링크 id만 UUID | 경로 의존 |

### 1.3 안정적인 UUID가 없는 것

1. `device_id`가 없다. 새로 만들어야 한다.
2. `page_id`가 없다. 페이지 엔티티 자체가 없다.
3. 기기별 `seq`가 없다.
4. 문서 ID가 경로에서 나오는 경우가 있다. 아직 열지 않은 PDF와 모든 `.md`·이미지가 그렇다. 앱 밖에서 옮기면 바뀐다.
5. 경로로 참조하는 데이터가 있다. `material_links`, `favorites.descriptor_json`, `pdf_view_state`, `media_progress`, `material_added_state`가 경로를 쓴다. `tabs_layout`은 과목 키를 쓴다. `pdf_drawings`와 `annotations`도 행 id는 UUID지만, 어느 문서 소속인지는 `(course_id, rel_path)`로 가리킨다.
6. 마크다운 안의 이미지는 상대 경로(`assets/첨부-<uuid>.<ext>`)로 참조한다.

참고: 기존 Supabase 동기화는 레코드 ID를 `material:<uuid>`, `drawing:<materialID>:<PDF sha>:<page>` 형태로 만들었다(`App/Native/Storage/NativeSyncDrawings.swift:64`). 페이지 ID 대신 "문서 + PDF 해시 + 페이지 번호"를 썼다는 뜻이다.

---

## 2. 필기 표현

### 2.1 엔진

- 자체 엔진이다.
  - 입력 캡처: `App/Desktop/PDF/NativePDFInkSurface.swift` (UITouch, coalesced·estimated 샘플)
  - 렌더: `NativePDFMetalInk.swift`, `NativePDFRetainedInkRenderer.swift` (Metal)
  - 획 모양 계산: `NativePDFInkGeometryV5.swift`
  - PDFKit은 PDF를 화면에 보여 주는 데만 쓴다.
- PencilKit은 **쓰이지 않는 코드에만** 남아 있다. `App/PDF/InkCanvas.swift`, `App/PDF/PDFWorkspaceView.swift`, `App/Whiteboard/WhiteboardWorkspaceView.swift`를 앱 어디에서도 생성하지 않는다. `App/PDF/PortableInk.swift`는 `InkCoordinateMapper` 때문에 아직 쓰인다.
- `PKDrawing.dataRepresentation()` 같은 엔진 블롭은 없다. 이 앱의 native 데이터는 `pdf_drawings` 행(JSON)이다.

### 2.2 저장 형식 (`pdf_drawings`, 검증 코드는 `App/Native/Storage/NativePDFRepositoryValidation.swift`)

```
id          UUID(소문자)
course_id   과목 UUID
rel_path    과목 폴더 기준 PDF 경로
page        1-based
kind        ink | highlighter | rect | ellipse | arrow | line | textbox | image          (:8)
data_json   {"inkVersion": 2..5,
             "points": [{"x","y","p","t"?,"tiltX"?,"tiltY"?}, …],
             "box"?, "text"?, "textRuns"?, "image"?}
style_json  {"color": ink|red|orange|yellow|green|blue|violet,                             (:9)
             "width": 0<w≤1, "opacity": 0..1, "fixedWidth"?: true, 글상자 서식…}
created_at, updated_at  ISO-8601, ms 단위
deleted_at              soft delete
```

- 값 범위: x·y·p는 0–1(`:72`), t는 0–86,400,000 ms, tiltX·tiltY는 −90–90°(`:73`).
- width는 표시 페이지 폭에 대한 비율이다. V5 형상은 "page-width metric"을 쓴다(`App/Desktop/PDF/NativePDFInkGeometryV4.swift:27`). 예를 들어 0.003이면 A4에서 약 1.8pt다.
- 색은 이름 7종이고 고정 RGB에 대응한다(`App/Desktop/PDF/NativePDFObjectRenderer.swift:255-267`).

  | 이름 | RGB |
  |---|---|
  | ink | #14171F |
  | red | #D6242E |
  | orange | #F06314 |
  | yellow | #F5B80A |
  | green | #1A944D |
  | blue | #1461E0 |
  | violet | #7D36D1 |

  화이트보드 어두운 배경 전용 `canvasLightInk`(#F0F0F0)도 있다. 불투명도는 `opacity` 필드로 따로 둔다.
- 볼펜은 `kind: ink`에 `style.fixedWidth = true`를 단 것이다. 압력·속도·테이퍼를 무시한다.

### 2.3 획 단위 접근: 가능

획 1개가 행 1개이고 UUID가 있다. 연산별 동작:

- `drawings:create`: 수신 영수증이 있어서 재시도해도 멱등이다.
- `drawings:update`: 올가미 이동·크기·색 변경. 같은 id다.
- `drawings:replace`: 도형 스냅. 같은 id로 kind를 바꾼다.
- `drawings:delete`: soft delete.

### 2.4 좌표계

- **PDF pt도, 뷰 좌표도 아니다.** 원점은 좌상단이고 y는 아래로 증가한다. **/Rotate를 반영한 표시 방향의 CropBox를 0–1로 정규화**한 값이다(`App/Desktop/PDF/NativePDFPageCoordinates.swift:1-40`). 같은 파일 주석에 따르면 데스크톱도 PDF.js `getViewport`로 같은 표시 좌표를 저장한다.
- 변환 경로: 터치(뷰 좌표) → `InkCoordinateMapper` → 표시 물리 좌표 → 정규화. `InkCoordinateMapper`는 오버레이를 배치할 때마다 아핀 변환을 샘플링한다(`App/Desktop/PDF/NativePDFHost.swift:1748-1754`).
- 회전은 0/90/180/270만 받는다. 그 밖의 값은 거부한다(`App/Native/Storage/NativePDFExport.swift:41`).
- MediaBox는 쓰지 않는다. CropBox만 쓴다.
- 회전 관련 기존 테스트:
  - `NativePDFInkTests.testDisplayCoordinatesPreserveDesktopRowsForCropBoxAndEveryRotation`
  - `NativeSyncDrawingsTests.testPortableRotationsPreserveMeasuredInkAndLegacyWidth`
  - `NativeSyncDrawingsTests.testRotatedPDFSnapshotImportsWithoutChangingReceiptOrMeasuredMetadata`
  - `NativePDFRepositoryTests.testExportPreservesSourceTextAndPlacesInkInRotatedCropBox`

### 2.5 입력 샘플 보존 (`NativePDFInkSurface.swift:700-960`)

- coalesced 샘플을 전부 저장한다. 다운샘플링은 없다. 완전히 같은 샘플만 건너뛴다(`:943`). 예측 터치는 저장하지 않는다. 늦게 들어오는 estimated 보정(force, azimuth, altitude, location)은 해당 샘플에만 반영한다.
- **압력 p는 원본값이 아니다.** `clamp(force / maximumPossibleForce × 2.5, 0.25, 1)`로 보정한 값이다(`:852-856`). 2026-10-18에 도입됐다. 그 전 행은 원값인데, 행에 둘을 구분하는 표시가 없다. 클램프 때문에 원값으로 되돌릴 수 없다.
- 기울기는 azimuth/altitude를 W3C 방식 tiltX/tiltY(도)로 바꿔 저장한다(`:861-866`). 기준 방향은 잉크 뷰 좌표, 즉 회전을 반영한 페이지 방향이다. altitude 하한은 0.001이다.
- 시간 t는 **획 시작 기준 상대 ms**다(`:864`). 획의 절대 시각은 `created_at`에 있다.
- 꾹 눌러 그리면 도형 스냅으로 직선·사각형·원·화살표가 된다. 이때 원 샘플은 도형 데이터로 바뀐다. 의도된 동작이다.

### 2.6 공통 스펙 strokes로 바꿀 때 잃는 정보

| 항목 | 내용 |
|---|---|
| 획이 아닌 개체 | rect, ellipse, arrow, line, textbox(서식 run 포함), image는 strokes에 담을 자리가 없다. native로만 옮겨지는데, 데스크톱은 native를 무시하므로 데스크톱에 보이지 않는다 |
| 렌더 형상 | `inkVersion`(2–5)과 `fixedWidth`(볼펜) 플래그를 잃는다. inkVersion이 없는 구 데스크톱 행은 별도 경로로 그린다(`App/Native/Storage/NativePDFLegacyInk.swift`) |
| 굵기의 의미 | width를 pt로 바꾸는 것은 가능하다. 하지만 iPad V5의 지름은 `width × (0.24 + 0.68·p^0.8) × (1 − 0.12·속도) × 시작·끝 테이퍼`다(`NativePDFInkGeometryV5.swift:149-161`). 스펙의 데스크톱 근사식은 `width × (0.5 + p)`다. 같은 숫자로 그려도 굵기가 다르다(§10.2) |
| 색 | 이름→hex는 정확하다. hex→이름은 7색 근사라서 역방향에서 손실이 생긴다. opacity는 alpha 8비트로 양자화된다 |
| 압력 | 저장된 p가 이미 보정값이다. 스펙의 "원본 샘플 그대로"와 의미가 다르다 |
| 기울기 | tiltX/tiltY(도)와 azimuth/altitude는 수학적으로 서로 바꿀 수 있다. 다만 스펙에 단위와 기준축 정의가 없다 |
| 시간 | t는 획 안의 상대 ms다. 스펙의 `t_ms`가 상대인지 절대인지 정해져 있지 않다 |
| 범위 | iPad는 x·y∈[0,1]을 강제한다. 페이지(CropBox) 밖 좌표가 있는 데스크톱 획은 클램프해야 들어온다 |
| tool | iPad에는 pencil 도구가 없다(pencil은 pen으로 근사). 볼펜은 pen이 되고 fixedWidth를 잃는다 |

---

## 3. 텍스트(타이핑) 노트

- **형식**: 과목 폴더 안의 UTF-8 Markdown `.md` 파일이다. 새로 만들면 내용이 `# 제목\n`이다(`NativeLibraryRepository.swift:479-489`).
- **편집 단위는 파일 전체다.** `notes:write`가 전체 텍스트를 `expectedMtime` 기반 낙관적 동시성으로 원자적으로 교체한다(`:499-513`). 연산 로그나 CRDT는 없다. 미저장 초안은 Application Support에 JSON으로 둔다.
- **편집기**: `NativeRichTextDocument`/`NativeRichTextEditor`는 Markdown 위에 얹은 투영이다. 건드리지 않은 문법은 바이트 그대로 남는다.
- **Markdown 확장**:
  - 이미지: `![](assets/첨부-<uuid>.<ext>)` 옆에 `<!-- bandal-image width=… align=… -->` 주석(`App/Native/NativeRichTextDocument.swift:9`)
  - 수식: `$…$`, `$$…$$`
  - PDF 페이지 노트: `<!-- bandal:pdf-page-note … -->`와 `<!-- bandal:page N -->`(`App/Native/Storage/NativePDFPageLinks.swift:55-76`). 연결 정보는 `material_links`에 둔다.
- 그 밖의 텍스트: PDF 위 `textbox` 개체가 있다. 이것은 필기 행의 일부다.

### 3.1 포맷 제안 (스펙 미정 항목, 확정은 2단계)

스펙에 이미 있는 규칙을 그대로 따른다. 파일은 만든 기기만 쓰고, 첨부는 불변이며, 승자는 t로 정하고, 자동 삭제는 하지 않는다.

```
root/note/<document_id>/<device_id>-<seq 8자리>.json.gz
  {"revs": [{"rev":"<uuid>", "base":"<직전 rev 또는 null>", "t":ms,
             "markdown":"…", "assets":[{"sha256":"…", "path":"assets/첨부-….png"}]}, …]}
root/asset/<sha256>.<ext>      노트 첨부. 불변이고 중복 업로드를 금지한다(pdf/와 같은 규칙)
```

- 저장할 때마다 문서 전체 스냅샷을 rev 하나로 만든다. 세션 동안은 자기 파일에 덧붙인다(append). 새 파일은 세션 시작 시나 1MB 초과 시 만든다.
- 다른 rev가 base로 가리키지 않는 rev가 문서의 head다.
  - head가 1개면 그대로 적용한다.
  - head가 2개 이상이면(오프라인 동시 편집) t가 큰 쪽을 본문으로 한다. 동률이면 device_id로 정한다. 나머지는 "(충돌 사본)" 노트로 보존한다. 텍스트를 자동으로 병합하지 않는다.
- doc.upsert는 `type:"note"`, `page_ids:[]`로 보낸다. 본문 Markdown은 손대지 않는다. `assets/…` 상대 경로와 sha256의 대응은 `assets` 배열에 둔다.
- 대안은 문단 단위 병합(블록 ID)이다. 충돌 사본이 자주 생겨 문제가 되면 v2에서 검토한다.

---

## 4. PDF

- **보관 위치**: 과목 폴더다. 관리형은 `Documents/BandalDesktop/Courses/<slug>/…`, 연결형은 외부 폴더다. 문서는 `(course_id, rel_path)`와 바인딩 `material_id`로 식별한다.
- **원본 보존**: 편집기로 처음 열 때 `PDFOriginals/<sha256>.pdf`로 복사한다(`NativePDFRepository.swift:102-186`).
- **필기와 하이라이트는 PDF에 굽지 않는다.** 내보내기(`nativePDF:exportBytes`)만 "… (주석).pdf"라는 새 파일을 만든다(`:457-473`).
- **예외: 페이지 재구성은 과목 폴더의 PDF를 다시 쓴다.**
  - 대상 작업: `pdf:restructure`(빈 페이지·양식 페이지 삽입, 삭제, 순서 변경). `NativePDFPageDocument.rewrite`로 파일을 교체한다(`App/Native/Storage/NativePDFPageRepository.swift:160-185`).
  - 변경 전후 바이트는 `PDFOriginals`에 남는다.
  - 바인딩의 sha를 갱신하고, 필기의 페이지 번호를 다시 매긴다.
  - `native_pdf_revision_lineage`에 페이지 대응을 기록한다. 실행 취소가 가능하다.
- **바인딩 보호**: PDF가 밖에서 바뀌어 sha가 다르면 필기를 붙이지 않고 "PDF 원본이 기존 필기와 다릅니다"를 띄운다(`NativePDFRepository.swift:86-88`). 동기화로 PDF를 받을 때 이 규칙을 함께 다뤄야 한다.
- 손글씨 노트 PDF는 앱이 만든 PDF다(§1.2).

---

## 5. 로그인

| 항목 | 현황 |
|---|---|
| 프로바이더 | Apple, Google, Kakao. 같은 계정에 다른 로그인 수단을 연결하는 linkIdentity도 있다 |
| Apple | **네이티브**다. `ASAuthorizationController`(`App/Desktop/DesktopAppleAuthorization.swift`)로 받은 토큰을 Supabase REST `POST /auth/v1/token?grant_type=id_token`에 `{provider:"apple", id_token, nonce}`로 보낸다. signInWithIdToken과 같은 동작이다(`App/Desktop/DesktopAccountService.swift:228-268`, 요청은 `:248`). authorizationCode는 탈퇴 시 토큰 철회용으로 Edge Function `account-delete`에 `registerAppleAuthorization`으로 등록한다(`:256`) |
| Google·Kakao | **웹 플로우**다. `ASWebAuthenticationSession`(`App/Services/OAuthSession.swift`)과 PKCE를 쓴다. `GET /auth/v1/authorize?provider=…&redirect_to=bandal://auth/callback&code_challenge=…`(`:184`)로 시작해 `POST /auth/v1/token?grant_type=pkce`(`:210`)로 끝난다. 네이티브 SDK는 없다 |
| Supabase 연동 | supabase-swift SDK 없이 URLSession으로 GoTrue REST를 직접 부른다 |
| auth 도메인 | **`https://ukacrkcwiqafwpppshxb.supabase.co`**. git이 무시하는 `App/Resources/Configuration.plist`의 `sync.url`/`sync.publishableKey`를 UserDefaults 기본값으로 등록한다(`App/Native/NativeWorkspaceStore.swift:136-141`). 숨은 "서버 설정"에서 덮어쓸 수 있다. **`auth.bandal.app`은 iPad 저장소와 데스크톱 저장소 어디에도 없다.** 데스크톱 `bandal:docs/oauth-setup.md`도 같은 supabase.co 주소를 쓴다 |
| 토큰 검증 | access token의 `iss`가 정확히 `<sync.url>/auth/v1`이어야 한다(`:462`). 커스텀 도메인으로 바꾸면 발급 토큰의 `iss`가 어느 주소가 되는지 실측해야 한다. 공식 문서로는 확정할 수 없었다 |
| 세션 저장 | 키체인 generic password. service는 `app.bandal.ipad.credentials`, account는 `sync.session`(프로필이면 `sync.session.<폴더명>`), 접근성은 `AfterFirstUnlockThisDeviceOnly`, access group은 지정하지 않았다(기본 그룹). 근거는 `App/Services/KeychainStore.swift`, `DesktopAccountService.swift:14-28`. 데이터 루트에는 `account-binding.json`(userID, projectURL)과 `account-access.json`(허용 영수증)도 둔다 |
| 로그인 없이 사용 | **1.1.0에서는 가능하다.** `isLocalOnly = true`라서 로그인 게이트와 계정 UI가 모두 꺼져 있다 |

### 5.1 로그인이 실제로 가로막는 기능 (플래그를 끈 코드 기준)

1. **앱 전체.** `localAccess.requiresLogin`이면 `NativeLoginGate`가 전체 화면을 덮는다(`App/Native/NativeWorkspaceView.swift:334, 347, 438`, `App/Native/NativeLoginGate.swift:11-15`). 데이터 루트가 처음 로그인한 계정에 묶이기 때문이다(`DesktopAccountService.swift:270-280, 473-485`). 잠기는 경우는 다음과 같다.
   - 로그아웃한 뒤. `signOut`이 허용 영수증을 false로 바꾼다(`:339-345`).
   - **계정을 삭제한 뒤. 이 경우는 영구 잠금이다.** 바인딩 파일에 삭제된 사용자 ID가 남아서, 다른 계정으로 로그인해도 "이 기기의 자료는 다른 계정에 연결되어 있습니다"로 거부한다(`:477`). 삭제 확인 문구는 "이 기기의 파일은 남습니다"인데 실제로는 앱에서 열 수 없다.
   - Supabase URL이 바뀐 뒤. 커스텀 도메인 전환도 여기에 해당한다. 영수증·바인딩의 `projectURL`이 맞지 않아 잠기고, 같은 계정으로 로그인해도 거부한다(`:75`, `:477`).
   - 영수증 파일이 손상된 경우.
2. 동기화. `syncIdentity`를 거친다(`App/Desktop/DesktopSyncService.swift:251`).
3. 구독 구매·복원. `serviceRequest`가 `syncIdentity`를 거친다.
4. 마켓플레이스와 클라우드 기능. `DesktopCloudService`가 계정 자격 증명을 요구한다.
5. 닉네임 같은 프로필 기능.

막지 않는 경우도 있다. 세션이 만료됐거나 오프라인이라 갱신에 실패한 것만으로는 잠그지 않는다. 이때 `restore()`는 `reauthentication-required`만 표시하고 로컬 접근은 유지한다(`:150-158`).

### 5.2 Kakao와 signInWithIdToken

- Supabase는 Kakao용 `signInWithIdToken(provider: "kakao")`를 지원한다. 전제 조건은 Kakao Developers에서 OpenID Connect를 켜는 것이다. 출처는 아래 "참고 자료"에 있다.
- iPad는 Kakao를 이미 웹 PKCE로 구현해 두었다. 그래서 **"웹 플로우로 통일"하는 데 드는 iPad 쪽 비용은 0이다.**
- 오히려 네이티브로 바꾸는 쪽이 새 비용이다.
  - KakaoSDK(SPM) 추가
  - 네이티브 앱 키와 URL scheme `kakao{앱키}`
  - `LSApplicationQueriesSchemes`
  - nonce 처리
  - id_token의 `aud`가 Supabase Kakao 프로바이더에 설정한 키와 맞는지 확인
- 서버는 Apple과 같은 `grant_type=id_token` 경로를 쓰고 `provider`만 바꾸면 된다. 추가 구현은 없다.

---

## 6. 구독

| 항목 | 현황 |
|---|---|
| 코드 | StoreKit 2. `App/Desktop/DesktopBillingService.swift` |
| 상품 ID | `app.bandal.ipad.sync.monthly`, `app.bandal.ipad.sync.yearly`(`:60`). 데스크톱 `bandal:docs/apple-billing-and-account-deletion.md`의 기본값과 같다 |
| 엔타이틀먼트 판정 | **서버가 한다.** 순서는 다음과 같다. ① 구매 전 Edge Function `/functions/v1/apple-billing`에 `prepare`를 보내면 서버가 appAccountToken과 productIds를 준다(`:111`). ② `purchase(options: [.appAccountToken(token)])`로 구매한다(`:21`). ③ 서명된 거래를 `verify`로 보낸다(`:154`). ④ 상태는 RPC `bandal_subscription_status`/`bandal_sync_status`로 조회한다(`:97-98`). `Transaction.currentEntitlements`/`unfinished`는 복원할 때 서버로 다시 보내는 데만 쓰고(`:33-36`), 로컬 판정에는 쓰지 않는다 |
| appAccountToken | 쓴다. **서버가 발급한 계정별 고정 토큰**이다. Supabase user id와 같다는 보장은 없다. 토큰이 없는 거래는 거부한다(`purchase_owned_by_another_account`, `:152`) |
| 로그인 의존 | 구매, 복원, 상태 조회 모두 로그인이 필요하다. `Transaction.updates` 리스너는 로그아웃 상태에서도 시작되지만, 서버 검증에 실패해 거래가 미완료로 남는다(`:70-80`) |
| 잠그는 기능(현재) | 동기화 쓰기뿐이다. 서버의 `writeAllowed`가 false면 `subscriptionRequired`, 용량을 넘으면 `storageLimitExceeded`가 된다(`DesktopSyncService.swift:272`). 그 밖에 구독으로 잠긴 기능은 없다 |
| 잠그는 기능(계획) | 코드와 문서에 없다. 원칙상 동기화가 무료가 되면 지금 유일한 잠금 대상이 사라진다. 제품 결정이 필요하다 |
| UI | 설정의 "동기화 구독" 패널에 구매, 복원, 구독 관리(`AppStore.showManageSubscriptions`, `:87`)가 있다. **EULA·개인정보 링크는 없다** |
| 원칙 충돌 | ① 로그인 필수 ② 서버 판정 ③ 상품 ID·패널 제목·문구에 "동기화" |

---

## 7. 1.1.0에서 숨긴 UI

모두 스위치 하나로 숨긴다: `App/Native/NativeReleaseFlags.swift:5` `isLocalOnly = true`. 코드 주석은 "code stays intact behind this switch"다.

| 위치 | 숨긴 것 |
|---|---|
| `App/Native/NativeSettingsCatalog.swift:24` | 설정의 "계정" 카테고리 전체 |
| `App/Native/NativeSettingsWorkspace.swift:273` | 계정 카테고리 본문. `accountPanel`(`:426`), `subscriptionPanel` "동기화 구독"(`:476`), `syncPanel` "자료 동기화"(`:517`), `profilePanel`(`:504`). 구독·동기화 패널은 이중으로 숨겨져 있다 |
| `App/Native/NativeWorkspaceView.swift:564-573` | 왼쪽 레일의 마켓플레이스 버튼과 `NativeAccountRailButton`(누르면 `NativeAccountView`) |
| `App/Native/NativeLoginGate.swift:13` | 로그인 게이트. 항상 false를 돌려준다 |
| 문구 분기 | `NativeLoginGate.swift:31`, `NativeSettingsWorkspace.swift:171, 603`, `NativeSettingsSections.swift:219`, `NativeSettingsSystemPanels.swift:134` |
| 테스트 | `Tests/BandalTests/NativeSettingsParityTests.swift:25`(카테고리 목록이 플래그를 따른다), 사이드바 UI 테스트(마켓플레이스 버튼이 없는지 확인) |

상태: 코드는 컴파일되고 살아 있다. 숨겨져 있어도 백그라운드에서 일부가 돈다.

- `DesktopSyncService.start()`가 15초 타이머와 포그라운드 옵저버를 등록한다(`App/Native/NativePlatformServices.swift:134`, `DesktopSyncService.swift:64`). 하지만 `syncEnabled != "true"`라서 바로 끝난다(`:115`).
- StoreKit `Transaction.updates` 리스너는 항상 돈다.
- 계정 복원은 자격 증명이 없어 바로 돌아온다.

---

## 8. 번들 ID · entitlements · Info.plist

| 항목 | 값 |
|---|---|
| 번들 ID | `app.bandal.ipad`(팀 VUZ7Z98BW3). 테스트는 `app.bandal.ipad.tests`, `app.bandal.ipad.uitests`. 공유 확장(BandalShare)은 빌드에서 빠져 있다(`project.yml` 주석) |
| 앱 entitlements | `App/Bandal.entitlements`에는 `com.apple.developer.applesignin = [Default]` **하나뿐이다** |
| App Store 프로파일 | 2026-10-26 생성, 이름 "app.bandal.ipad AppStore …". Sign in with Apple, App Groups `group.app.bandal.ipad`, keychain-access-groups `VUZ7Z98BW3.*`가 있다. **iCloud는 없다** |
| iCloud 컨테이너 | 없다. `icloud-container-identifiers`, `ubiquity-container-identifiers`, `icloud-services` 모두 없다 |
| 키체인 그룹 | 선언하지 않았다. 기본값 `VUZ7Z98BW3.app.bandal.ipad`가 쓰인다. `KeychainStore`도 access group을 지정하지 않는다 |
| `NSUbiquitousContainers` | 없다 |
| URL scheme | `bandal`(`CFBundleURLName` `app.bandal.auth`). `bandal://auth/callback`에 쓴다 |
| 그 밖의 키 | 다음 키가 켜져 있다.<br>• `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` YES<br>• 문서 유형: PDF, 텍스트, Markdown, 이미지<br>• UTType `app.bandal.workspace-tab`<br>• 멀티 씬 off<br><br>다음 키는 없다. 2단계의 BGAppRefresh와 Kakao 네이티브 로그인에 필요하다.<br>• `UIBackgroundModes`<br>• `BGTaskSchedulerPermittedIdentifiers`<br>• `LSApplicationQueriesSchemes` |
| ShareExtension | `ShareExtension/BandalShare.entitlements`에 App Group `group.app.bandal.ipad` |

---

## 9. 오프라인 동작

- **1.1.0(배포 상태)**: 로컬 자료 접근을 막는 경로가 없다. 필기, PDF, 노트는 네트워크 없이 동작한다. 동기화와 로그인은 꺼져 있다.
- **플래그를 끈 코드**: 세션 만료나 오프라인만으로는 막지 않는다. 다만 §5.1-1의 잠금 경로(로그아웃, 계정 삭제, URL 변경, 영수증 손상)는 오프라인 여부와 관계없이 로컬 자료를 막는다. 원칙 1에 따라 2단계 (f)에서 게이트와 바인딩을 없애야 한다.

---

## 10. 검토 항목 중 1단계에서 답할 수 있는 것

### 10.1 원본 샘플 + native 동봉 시 페이지당 용량 (gzip 후)

합성 데이터로 추정했다. 실제 사용자 데이터는 쓰지 않았다. 조건은 다음과 같다.

- A4 페이지, Apple Pencil 240 Hz coalesced 샘플
- 획 길이 80–300 ms(평균 약 46샘플)
- 숫자는 지금처럼 전체 배정밀도로 저장
- strokes는 pt 단위
- native는 `pdf_drawings` 행 JSON

| 페이지 | 샘플 수 | strokes만 (현재 정밀도) | strokes만 (소수 3자리) | + native: base64(JSON) | + native: base64(gzip(JSON)) |
|---|---|---|---|---|---|
| 200획(가벼운 필기) | 9.2k | 483 KB | 145 KB | 793 KB | 671 KB |
| 600획(빽빽한 강의 노트) | 27.7k | 1,453 KB | 437 KB | 2,385 KB | 2,019 KB |
| 1,500획(아주 빽빽함) | 68.3k | 3,584 KB | 1,079 KB | 5,879 KB | 4,977 KB |

샘플 하나의 gzip 후 크기는 strokes(소수 3자리)가 약 16 B, native(원래 정밀도)가 약 57 B다.

정리하면 다음과 같다.

1. 용량 대부분은 native다. 손실 0을 지키려면 native는 원래 정밀도를 유지해야 하므로 줄이기 어렵다.
2. strokes 숫자 정밀도를 정하지 않으면 크기가 3배까지 차이 난다.
3. "1MB 초과 시 새 파일" 규칙에 따르면 빽빽한 페이지는 기기당 여러 파일이 된다.
4. 자기 파일을 계속 덮어쓰는(append) 방식이면 1.5초 idle마다 최대 1MB를 다시 쓰고 업로드한다. 2단계에서 파일 상한을 더 작게 잡는 것을 검토해야 한다.

실제 iPad 데이터로 재는 것은 2단계에서 승인을 받은 뒤 한다.

### 10.2 데스크톱 strokes를 iPad 엔진으로 가져올 때 렌더 차이

- **굵기**: 같은 width를 넣었을 때 굵기가 다음과 같다.

  | p | iPad V5 지름 | 데스크톱 v1 근사 |
  |---|---|---|
  | 0.5 | 0.63×width | 1.0×width |
  | 0.9 | 0.87×width | 1.4×width |

  iPad 쪽 값은 시작·끝 테이퍼를 넣기 전이고, 속도가 빠르면 최대 12% 더 가늘어진다. 결국 **데스크톱 근사는 같은 획을 iPad보다 약 1.6배 굵게 그린다.** 반대로 데스크톱 획은 iPad에서 가늘게 보인다.
- **모양**: polyline과 V5 곡선은 다르다. V5는 곡선을 세분하고 끝을 가늘게 한다. 타임스탬프가 없으면 속도 항은 중립이 된다.
- **색**: 데스크톱이 임의의 hex를 쓰면 iPad에서 7색 중 가까운 색이 된다.
- **pencil 도구**: 질감이 없다.
- **페이지 밖 좌표**: 클램프된다.
- **핵심 사실**: 데스크톱은 이미 `bandal:src/shared/inkV5`로 iPad와 같은 V5 형상을 그린다(`bandal:src/renderer/src/features/ink/inkGeometry.ts:186`). 저장하는 행 포맷도 같다(`bandal:src/main/db/migrations.ts:185`). 데스크톱도 native를 읽으면 양쪽 렌더 차이는 0이 된다(§11-1).

### 10.3 회전된 PDF에서 좌표 변환이 양방향으로 맞는지

- 지금 저장 좌표는 회전을 반영한 표시 좌표(정규화)다. 스펙 좌표도 회전을 반영한 표시 좌표(pt, MediaBox 기준)다. **그래서 축 회전 변환은 필요 없다.** 변환은 두 가지뿐이다.
  - 스케일: 표시 폭과 높이를 곱한다.
  - CropBox 오프셋: CropBox가 MediaBox 안 어디에 있는지를 표시 방향으로 회전해 더한다.
- 왕복 오차는 배정밀도에서 몇 ulp 이하다. 소수 3자리로 반올림해도 0.0005 pt 이하로, 눈에 보이지 않는다.
- **위험**: CropBox와 MediaBox가 다른 PDF가 문제다. 데스크톱이 CropBox 밖에 찍은 점은 iPad가 [0,1] 검증에서 거부한다. 클램프하면 그만큼 손실이다(§11-4).
- **검증 계획**: 3단계 (b)에서 0/90/180/270 회전과 CropBox 오프셋이 있는 PDF로 두 방향 왕복 테스트를 만든다. 하나는 iPad→스펙→iPad, 다른 하나는 스펙(데스크톱 생성)→iPad→스펙이다. 기존 회전 테스트 4개(§2.4)가 이미 표시 좌표와 비회전 좌표 사이 변환을 검증하고 있어 재사용할 수 있다.

### 10.4 두 기기에서 오프라인으로 같은 페이지를 고친 뒤 머지했을 때 획 손실

- 새 스펙은 획 id의 합집합으로 머지한다. 획을 추가하거나 지우는 것끼리는 손실 0을 보장할 수 있다. iPad의 지우기 취소는 새 id로 다시 만들므로 "del은 최종" 규칙과도 맞는다.
- **하지만 같은 id를 고치는 경우가 있다.** 올가미 이동·크기·색 변경은 같은 id로 update하고, 도형 스냅은 같은 id로 kind를 바꾼다. 스펙에는 "같은 id, 다른 내용"일 때 무엇이 이기는지 규칙이 없다. 두 기기가 같은 획을 옮기면 기기마다 결과가 달라질 수 있다. 획을 잃지는 않지만 한 상태로 모이지 않는다(§11-3).
- 기존 Supabase 동기화는 페이지 단위 레코드라서 동시에 고치면 "충돌 사본"을 골라야 했다. 고르지 않은 쪽 획은 화면에서 빠진다(보관은 된다). 새 방식에서는 이 경로가 없어진다.
- 테스트는 3단계 (b) 적합성 테스트에서 만든다.

### 10.5 엔타이틀먼트 없는 Electron이 iCloud 컨테이너에 쓴 파일을 iPad가 받는지

지금은 컨테이너가 없어 검증할 수 없다. 전제와 위험만 정리했다.

1. 먼저 컨테이너를 만들어야 한다. App ID에 iCloud capability를 켜고, 컨테이너를 만들고, 프로파일을 다시 받고, entitlements를 넣어야 한다. Mac에 컨테이너 폴더가 생기는 것은 iPad 앱이 iCloud에 한 번 쓴 뒤다. 그래서 데스크톱은 폴더가 없으면 "iPad 앱을 먼저 실행하세요"를 안내해야 한다.
2. Mac 경로 `~/Library/Mobile Documents/iCloud~…/Documents`는 **번들 ID가 아니라 컨테이너 ID**에서 나온다. 스펙이 "번들ID"라고 쓴 것은 컨테이너 ID를 번들 ID와 같게 정한다는 전제다. 2단계에서 ID를 확정한다.
3. Mac에서 "저장 공간 최적화"를 켜면 다른 기기가 쓴 파일이 아직 내려받지 않은 상태로 있을 수 있다. 데스크톱이 읽을 때 다운로드를 기다리는 처리가 필요하다.
4. iPad는 `NSMetadataQuery`로 변화를 감지하고 `startDownloadingUbiquitousItem`으로 받는다. 읽을 때는 `NSFileCoordinator`를 쓴다.
5. "임시 파일 → rename" 규칙을 지킬 때 임시 파일까지 업로드되지 않게 하는 이름 규칙이 필요하다. 예를 들어 `.nosync`인데, 실제로 동작하는지 확인해야 한다.

수동 테스트는 3단계 체크리스트에 넣는다.

### 10.6 Kakao 네이티브 로그인이 Supabase에서 안 될 때 웹 플로우로 통일하는 비용

§5.2를 보라. Supabase는 Kakao id_token을 지원한다. iPad는 이미 웹 플로우라 통일 비용이 0이다.

---

## 11. 공통 스펙 변경 제안 후보

제안만 한다. 스펙은 고치지 않았다. 바꾼다면 데스크톱과 같은 PR로 동시에 반영해야 한다.

1. **native를 두 앱이 함께 읽는 행 포맷으로 하자.** 데스크톱도 같은 `pdf_drawings` 행과 V5 형상을 이미 갖고 있다. native를 "iPad 전용 base64 블롭"이 아니라 양쪽이 읽는 JSON으로 두자는 제안이다. 예: `{"engine":"bandal-ink","version":5,"rows":[…]}`. 그러면 다음을 얻는다.
   - 양방향 손실 0
   - 도형, 글상자, 이미지도 동기화
   - 렌더 차이 0
   - base64 오버헤드 제거

   strokes는 다른 엔진과 앞으로의 호환을 위해 남긴다.
2. **페이지와 원본 PDF 페이지의 대응을 넣자.** `page.upsert`에 두 필드를 더한다.
   - `pdf_page`: 원본 PDF의 1-based 쪽. 빈 페이지나 양식 페이지는 null
   - `paper`: blank, lines, grid, dots

   이 필드가 없으면 iPad에서 페이지를 넣거나 빼거나 순서를 바꿀 때마다 "새 sha256 PDF 업로드 + 모든 페이지 재매핑"이 일어난다.
3. **같은 획 id를 고칠 때의 규칙을 정하자.** 방법은 둘 중 하나다.
   - 획에 `u`(마지막 수정 ms)를 넣고 id별로 나중 것이 이기게 한다. 동률이면 device_id로 정한다.
   - "수정 = 새 id로 만들고 옛 id에 del"을 규칙으로 정한다.
4. **좌표 기준 상자를 정하자.** 두 앱 모두 CropBox를 보여 주고 CropBox로 저장한다. MediaBox를 기준으로 하려면 오프셋 변환 규칙과 경계 밖 점 처리 규칙이 있어야 한다. 기준을 CropBox로 바꾸거나 경계 밖 처리를 명시하자.
5. **샘플 필드를 정의하자.** 정할 것은 다음과 같다.
   - p: 원값인지 보정값인지. iPad는 보정값이다. `p_raw` 필드를 추가하는 방법도 있다.
   - 기울기: 단위(라디안/도)와 기준축.
   - `t_ms`: 획 시작 기준 상대 ms를 제안한다.
   - 숫자 정밀도: 예를 들어 좌표는 pt 소수 3자리.
6. **width의 의미를 정하자.** 예를 들어 "명목 굵기"로 정의한다. iPad V5에서 p=1일 때 지름은 0.92×width다. 그리고 데스크톱 v1 근사식을 V5에 맞추거나(데스크톱에 V5가 이미 있다) 변환 계수를 명시하자.
7. **색 팔레트를 고정하자.** 공용 7색의 hex를 스펙에 적는다(§2.2 표). 양쪽 팔레트가 같으면 왕복해도 손실이 없다.
8. **텍스트 노트 포맷**: §3.1을 보라.
9. **PDF 없는 손글씨 문서**: 레거시 화이트보드가 여기에 해당한다. 담을 doc type이 없다. 줄노트 PDF로 변환해 올리거나 type을 추가해야 한다.
10. **용량**: native 인코딩(JSON 그대로 vs base64)과 파일 크기 상한을 정하자. 근거는 §10.1 수치다.

---

## 12. 2단계 전에 사람이 정해야 할 것

1. App Store Connect에 `app.bandal.ipad.sync.*` 구독 상품을 이미 만들었는가? 만들었다면 ID는 바꿀 수 없고 표시 이름만 바꿀 수 있다. 아직이라면 "sync"가 빠진 새 ID를 권장한다.
2. 구독으로 잠글 기능은 무엇인가? 동기화가 무료가 되면 지금 잠금 대상이 없다.
3. 로그인 바인딩이 만들어진 기기가 실제로 있는가? 1.0과 1.1은 로컬 전용이라 배포 사용자에게는 없을 가능성이 크다. TestFlight와 개발 기기를 확인해야 한다.
4. iCloud 컨테이너 ID를 무엇으로 할 것인가? 후보는 둘이다.
   - `iCloud.app.bandal.ipad`: 스펙 문구 그대로다.
   - `iCloud.app.bandal`: 제품 단위라서 나중에 iPhone이나 Mac 네이티브 앱과 공유하기 쉽다.

   한 번 만들면 지우거나 이름을 바꿀 수 없다.
5. §11 변경 제안을 데스크톱 팀과 함께 검토할 것인가?

---

## 13. 사람이 콘솔에서 할 설정 (1단계 예비 목록)

정확한 값은 2단계에서 확정한다.

- **Apple Developer**
  - App ID `app.bandal.ipad`에 iCloud(iCloud Documents)를 켠다.
  - 컨테이너를 만든다.
  - 개발용과 App Store용 프로파일을 다시 받는다. 지금 프로파일에는 iCloud가 없다.
- **App Store Connect**
  - 구독을 유지하면 구독 그룹과 상품을 만들고 유료 앱 계약을 맺는다.
  - 로그인이나 구매를 다시 켜면 개인정보 라벨을 바꾼다. 지금은 "데이터 수집 안 함"이다. 개인정보 처리방침 페이지도 함께 고친다.
- **Supabase**
  - Redirect URLs에 `bandal://auth/callback`이 있는지 확인한다.
  - Kakao 프로바이더의 OIDC 설정을 확인한다.
  - 커스텀 도메인을 쓰면 발급 토큰의 `iss`를 실측한다(§5).
- **Kakao Developers**
  - OpenID Connect를 켠다(id_token 발급).
  - 네이티브로 바꾼다면 iOS 플랫폼에 번들 ID를 등록한다.
- **Google Cloud**
  - Drive API를 켠다.
  - OAuth 동의 화면에 `drive.file` 스코프를 넣는다.
  - iOS OAuth 클라이언트(번들 ID)와 URL scheme(reversed client ID)을 만든다.

---

## 참고 자료

- Supabase — Sign in with Kakao: https://supabase.com/docs/guides/auth/social-sign-in/auth-kakao
- Supabase JS — signInWithIdToken: https://supabase.com/docs/reference/javascript/auth-signinwithidtoken
- Supabase Dart — linkIdentityWithIdToken (지원 프로바이더에 Kakao 포함): https://supabase.com/docs/reference/dart/auth-linkidentitywithidtoken
- Supabase — JWT 클레임(`iss` 형식): https://supabase.com/docs/guides/auth/jwt-fields
- Supabase — Custom Domains: https://supabase.com/docs/guides/platform/custom-domains
